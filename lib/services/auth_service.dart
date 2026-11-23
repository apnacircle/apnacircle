import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_bootstrap.dart';

/// Firebase Auth — account-based identity (v0.3, 22 Nov 2026).
///
/// A circle belongs to an ACCOUNT, not a phone: a parent who loses
/// their phone signs in on a new phone (same email / same SIM
/// number) and gets the same circles + parent PIN back. That is the
/// approved parent-phone-loss recovery (see README).
///
/// TWO sign-in channels, per Mujahid's standing decision
/// (22 Nov 2026): OTP must come on BOTH the SIM number AND Gmail.
/// * Phone (SIM): Firebase Phone Auth sends a 6-digit SMS OTP to
///   the SIM number — [startPhoneSignIn] then [confirmPhoneCode].
/// * Gmail: Email/Password sign-in + sign-up. Firebase Auth has NO
///   built-in 6-digit email OTP — the Gmail channel is the email
///   verification link + password-reset email sent to the Gmail
///   inbox ([sendEmailVerification] after sign-up). A 6-digit code
///   in Gmail is built separately (v0.6): the Cloud Function +
///   SMTP sender behind [EmailOtpService] — NOT faked here, and
///   NOT part of this class.
///
/// Every method is a no-op returning an error string when Firebase
/// is not configured (demo mode) — the UI shows the message and
/// offers "Continue in demo mode" instead of crashing.
class AuthService extends ChangeNotifier {
  AuthService() {
    if (FirebaseBootstrap.available) {
      _sub = FirebaseAuth.instance.authStateChanges().listen((user) {
        // Signed in now -> the demo skip no longer applies.
        if (user != null && _demoSkipped) unawaited(clearDemoSkip());
        notifyListeners();
      });
    }
  }

  StreamSubscription<User?>? _sub;

  /// "Continue in demo mode" was chosen (persisted). The user can
  /// still sign in later from Settings -> Account & Circles.
  static const _demoSkipKey = 'demo_skip_auth';
  bool _demoSkipped = false;
  bool get demoSkipped => _demoSkipped;

  Future<void> loadDemoSkip() async {
    final prefs = await SharedPreferences.getInstance();
    _demoSkipped = prefs.getBool(_demoSkipKey) ?? false;
    notifyListeners();
  }

  Future<void> skipDemo() async {
    final prefs = await SharedPreferences.getInstance();
    _demoSkipped = true;
    await prefs.setBool(_demoSkipKey, true);
    notifyListeners();
  }

  /// Clear the demo skip (used after a successful sign-in).
  Future<void> clearDemoSkip() async {
    final prefs = await SharedPreferences.getInstance();
    _demoSkipped = false;
    await prefs.remove(_demoSkipKey);
    notifyListeners();
  }

  /// Firebase is configured AND a user is signed in.
  bool get signedIn =>
      FirebaseBootstrap.available &&
      FirebaseAuth.instance.currentUser != null;

  User? get user =>
      FirebaseBootstrap.available ? FirebaseAuth.instance.currentUser : null;

  String? get uid => user?.uid;
  String? get email => user?.email;
  String? get phoneNumber => user?.phoneNumber;
  String? get displayName => user?.displayName;
  bool get emailVerified => user?.emailVerified ?? false;

  /// Friendly text for FirebaseAuthException codes.
  static String _friendly(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'That email address does not look right.';
      case 'user-not-found':
        return 'No account with that email. Create one first.';
      case 'wrong-password':
      case 'invalid-credential':
        return 'Wrong email or password.';
      case 'email-already-in-use':
        return 'That email already has an account — sign in instead.';
      case 'weak-password':
        return 'Password must be at least 6 characters.';
      case 'invalid-phone-number':
        return 'That phone number does not look right. Use +92… format.';
      case 'too-many-requests':
        return 'Too many tries — wait a while, then try again.';
      case 'invalid-verification-code':
        return 'Wrong OTP code — check the SMS and try again.';
      case 'session-expired':
        return 'The SMS code expired — ask for a new one.';
      case 'network-request-failed':
        return 'No internet — check the connection and try again.';
      default:
        return e.message ?? 'Sign-in failed (${e.code}).';
    }
  }

  /// Email + password sign-in. Returns null on success, else an
  /// error message to show.
  Future<String?> signInWithEmail(String email, String password) async {
    if (!FirebaseBootstrap.available) {
      return 'Firebase is not set up yet — use demo mode for now.';
    }
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      notifyListeners();
      return null;
    } on FirebaseAuthException catch (e) {
      return _friendly(e);
    } catch (e) {
      return 'Sign-in failed: $e';
    }
  }

  /// Email + password sign-up. Sends the Gmail verification link
  /// (the Gmail channel — see class doc). Returns null on success.
  Future<String?> signUpWithEmail(
    String email,
    String password,
    String name,
  ) async {
    if (!FirebaseBootstrap.available) {
      return 'Firebase is not set up yet — use demo mode for now.';
    }
    try {
      final cred =
          await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      if (name.trim().isNotEmpty) {
        await cred.user?.updateDisplayName(name.trim());
      }
      // Gmail verification link (inbox: Gmail). The account works
      // before verifying, but unverified accounts cannot join a
      // circle as a parent — see SyncService.
      await cred.user?.sendEmailVerification();
      notifyListeners();
      return null;
    } on FirebaseAuthException catch (e) {
      return _friendly(e);
    } catch (e) {
      return 'Sign-up failed: $e';
    }
  }

  /// Re-send the Gmail verification link.
  Future<String?> sendEmailVerification() async {
    if (!signedIn) return 'Sign in first.';
    try {
      await user!.sendEmailVerification();
      return null;
    } on FirebaseAuthException catch (e) {
      return _friendly(e);
    }
  }

  // --- Phone (SIM) OTP ---

  String? _verificationId;
  bool _codeSent = false;

  /// True after [startPhoneSignIn] sent the SMS and the UI should
  /// show the OTP-code field.
  bool get phoneCodeSent => _codeSent;

  /// Step 1: send the 6-digit SMS OTP to [phoneNumber]
  /// (E.164, e.g. +923001234567). Returns null when the SMS was
  /// sent (or auto-verified), else an error message.
  Future<String?> startPhoneSignIn(String phoneNumber) async {
    if (!FirebaseBootstrap.available) {
      return 'Firebase is not set up yet — use demo mode for now.';
    }
    _codeSent = false;
    _verificationId = null;
    final completer = Completer<String?>();
    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: phoneNumber.trim(),
        verificationCompleted: (PhoneAuthCredential credential) async {
          // Android auto-verified the SIM (instant verification).
          try {
            await FirebaseAuth.instance.signInWithCredential(credential);
            notifyListeners();
            if (!completer.isCompleted) completer.complete(null);
          } on FirebaseAuthException catch (e) {
            if (!completer.isCompleted) completer.complete(_friendly(e));
          }
        },
        verificationFailed: (FirebaseAuthException e) {
          if (!completer.isCompleted) completer.complete(_friendly(e));
        },
        codeSent: (String verificationId, int? resendToken) {
          _verificationId = verificationId;
          _codeSent = true;
          notifyListeners();
          if (!completer.isCompleted) completer.complete(null);
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          _verificationId = verificationId;
        },
      );
    } on FirebaseAuthException catch (e) {
      return _friendly(e);
    } catch (e) {
      return 'Could not send the OTP: $e';
    }
    return completer.future;
  }

  /// Step 2: verify the 6-digit SMS code. Returns null on success.
  Future<String?> confirmPhoneCode(String smsCode) async {
    if (_verificationId == null) {
      return 'Ask for a new OTP code first.';
    }
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: _verificationId!,
        smsCode: smsCode.trim(),
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
      _codeSent = false;
      notifyListeners();
      return null;
    } on FirebaseAuthException catch (e) {
      return _friendly(e);
    } catch (e) {
      return 'Could not verify the code: $e';
    }
  }

  /// Sign out (keeps the local demo data on the phone).
  Future<void> signOut() async {
    if (!FirebaseBootstrap.available) return;
    await FirebaseAuth.instance.signOut();
    await clearDemoSkip();
    notifyListeners();
  }

  /// Delete the Firebase account (Play Store requirement).
  /// Needs a recent sign-in; returns an error message on failure.
  Future<String?> deleteAccount() async {
    if (!signedIn) return 'No account is signed in.';
    try {
      await user!.delete();
      notifyListeners();
      return null;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'requires-recent-login') {
        return 'Sign in again first, then delete the account.';
      }
      return _friendly(e);
    } catch (e) {
      return 'Could not delete the account: $e';
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
