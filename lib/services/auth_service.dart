import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/strings.dart';
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
  /// Reuses existing l10n keys where the wording matches exactly.
  static String _friendly(FirebaseAuthException e, {bool isUrdu = false}) {
    switch (e.code) {
      case 'invalid-email':
        return tr(isUrdu, 'emailCodeInvalidEmail');
      case 'user-not-found':
        return tr(isUrdu, 'svc_authNoAccount');
      case 'wrong-password':
      case 'invalid-credential':
        return tr(isUrdu, 'svc_authWrongEmailPassword');
      case 'email-already-in-use':
        return tr(isUrdu, 'svc_authEmailInUse');
      case 'weak-password':
        return tr(isUrdu, 'svc_authWeakPassword');
      case 'invalid-phone-number':
        return tr(isUrdu, 'svc_authBadPhone');
      case 'too-many-requests':
        return tr(isUrdu, 'svc_authTooManyTries');
      case 'invalid-verification-code':
        return tr(isUrdu, 'svc_authWrongOtp');
      case 'session-expired':
        return tr(isUrdu, 'svc_authOtpExpired');
      case 'network-request-failed':
        return tr(isUrdu, 'emailCodeNetwork');
      default:
        return e.message ??
            trf(isUrdu, 'svc_authSignInFailedCode', {'code': e.code});
    }
  }

  /// Email + password sign-in. Returns null on success, else an
  /// error message to show.
  Future<String?> signInWithEmail(
    String email,
    String password, {
    bool isUrdu = false,
  }) async {
    if (!FirebaseBootstrap.available) {
      return tr(isUrdu, 'svc_authFirebaseNotSetup');
    }
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      notifyListeners();
      return null;
    } on FirebaseAuthException catch (e) {
      return _friendly(e, isUrdu: isUrdu);
    } catch (e) {
      return trf(isUrdu, 'svc_authSignInFailed', {'e': e.toString()});
    }
  }

  /// Email + password sign-up. Sends the Gmail verification link
  /// (the Gmail channel — see class doc). Returns null on success.
  Future<String?> signUpWithEmail(
    String email,
    String password,
    String name, {
    bool isUrdu = false,
  }) async {
    if (!FirebaseBootstrap.available) {
      return tr(isUrdu, 'svc_authFirebaseNotSetup');
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
      return _friendly(e, isUrdu: isUrdu);
    } catch (e) {
      return trf(isUrdu, 'svc_authSignUpFailed', {'e': e.toString()});
    }
  }

  /// Re-send the Gmail verification link.
  Future<String?> sendEmailVerification({bool isUrdu = false}) async {
    if (!signedIn) return tr(isUrdu, 'svc_authSignInFirst');
    try {
      await user!.sendEmailVerification();
      return null;
    } on FirebaseAuthException catch (e) {
      return _friendly(e, isUrdu: isUrdu);
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
  Future<String?> startPhoneSignIn(
    String phoneNumber, {
    bool isUrdu = false,
  }) async {
    if (!FirebaseBootstrap.available) {
      return tr(isUrdu, 'svc_authFirebaseNotSetup');
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
            if (!completer.isCompleted) {
              completer.complete(_friendly(e, isUrdu: isUrdu));
            }
          }
        },
        verificationFailed: (FirebaseAuthException e) {
          if (!completer.isCompleted) {
            completer.complete(_friendly(e, isUrdu: isUrdu));
          }
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
      return _friendly(e, isUrdu: isUrdu);
    } catch (e) {
      return trf(isUrdu, 'svc_authOtpSendFailed', {'e': e.toString()});
    }
    return completer.future;
  }

  /// Step 2: verify the 6-digit SMS code. Returns null on success.
  Future<String?> confirmPhoneCode(
    String smsCode, {
    bool isUrdu = false,
  }) async {
    if (_verificationId == null) {
      return tr(isUrdu, 'svc_authNeedOtpFirst');
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
      return _friendly(e, isUrdu: isUrdu);
    } catch (e) {
      return trf(isUrdu, 'svc_authVerifyCodeFailed', {'e': e.toString()});
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
  Future<String?> deleteAccount({bool isUrdu = false}) async {
    if (!signedIn) return tr(isUrdu, 'svc_authNoAccountSignedIn');
    try {
      await user!.delete();
      notifyListeners();
      return null;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'requires-recent-login') {
        return tr(isUrdu, 'signInAgainFirst');
      }
      return _friendly(e, isUrdu: isUrdu);
    } catch (e) {
      return trf(isUrdu, 'svc_authDeleteFailed', {'e': e.toString()});
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
