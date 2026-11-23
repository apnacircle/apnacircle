import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'firebase_bootstrap.dart';

/// 6-digit EMAIL OTP login (v0.6) — the Gmail channel with a real code.
///
/// Firebase Auth has NO built-in 6-digit email code (only a
/// verification link). The code flow lives in the Cloud Functions
/// (`functions/index.js` — requestEmailCode / verifyEmailCode):
/// the function sends the code by SMTP, stores ONLY its SHA-256
/// hash, and on a correct code mints a custom token. This service
/// only calls those two functions and signs in with the token —
/// the code itself is never stored or logged in the app either.
///
/// Errors are returned as stable SLUGS (not user text): the screen
/// maps each slug to a plain-language EN/UR message via
/// [EmailOtpLogic.messageKeyFor]. Known slugs:
/// `email-invalid`, `code-wrong`, `code-expired`, `code-not-found`,
/// `too-many-attempts`, `too-many-requests`, `email-not-configured`,
/// `email-send-failed`, `network-error`, `not-configured`.
class EmailOtpLogic {
  /// A code is exactly 6 digits.
  static const codeLength = 6;

  /// A code lives 10 minutes (server-side too — keep in sync with
  /// functions/email_otp.js CODE_TTL_MS).
  static const codeTtlSeconds = 600;

  /// Wrong tries per code before it locks (server-side too).
  static const maxAttempts = 5;

  /// Codes per email per hour (server-side too).
  static const maxCodesPerHour = 5;

  static bool isValidCode(String code) =>
      RegExp(r'^\d{6}$').hasMatch(code.trim());

  static bool isValidEmail(String email) => RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$')
      .hasMatch(email.trim().toLowerCase());

  /// SHA-256 hex — same as the server's hash (used only for tests /
  /// debugging helpers, never to check a code client-side).
  static String sha256Hex(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static bool isExpired(int expiresAtMs, int nowMs) => nowMs >= expiresAtMs;

  static int attemptsLeft(int attempts) =>
      (maxAttempts - attempts).clamp(0, maxAttempts);

  static bool canAttempt(int attempts) => attempts < maxAttempts;

  /// Server error slug -> l10n key for the plain-language message.
  static String messageKeyFor(String slug) {
    switch (slug) {
      case 'email-invalid':
        return 'emailCodeInvalidEmail';
      case 'code-wrong':
        return 'emailCodeWrong';
      case 'code-expired':
        return 'emailCodeExpired';
      case 'code-not-found':
        return 'emailCodeNotFound';
      case 'too-many-attempts':
        return 'emailCodeTooMany';
      case 'too-many-requests':
        return 'emailCodeRateLimited';
      case 'email-not-configured':
        return 'emailCodeNotConfigured';
      case 'email-send-failed':
        return 'emailCodeSendFailed';
      case 'network-error':
        return 'emailCodeNetwork';
      case 'not-configured':
        return 'emailCodeNotConfigured';
      default:
        return 'emailCodeSendFailed';
    }
  }
}

class EmailOtpService extends ChangeNotifier {
  EmailOtpService({FirebaseFunctions? functions})
      : _functionsOverride = functions;

  final FirebaseFunctions? _functionsOverride;

  FirebaseFunctions get _functions =>
      _functionsOverride ?? FirebaseFunctions.instance;

  /// True after [requestCode] sent a code and the UI should show
  /// the code field.
  bool _codeSent = false;
  bool get codeSent => _codeSent;

  /// The email the current code was sent to.
  String? _email;
  String? get email => _email;

  static const _knownSlugs = {
    'email-invalid',
    'code-wrong',
    'code-expired',
    'code-not-found',
    'too-many-attempts',
    'too-many-requests',
    'email-not-configured',
    'email-send-failed',
  };

  /// Map a functions error to a stable slug. A slug the server
  /// sent is trusted; anything else (network, timeout) becomes
  /// `network-error` or the caller's fallback.
  String _mapError(FirebaseFunctionsException e, String fallback) {
    final m = e.message;
    if (m != null && _knownSlugs.contains(m)) return m;
    if (e.code == 'unavailable' || e.code == 'deadline-exceeded') {
      return 'network-error';
    }
    return fallback;
  }

  /// Step 1: send a 6-digit code to [email]'s Gmail inbox.
  /// Returns null on success, else an error slug.
  Future<String?> requestCode(String email) async {
    if (!FirebaseBootstrap.available) return 'not-configured';
    final e = email.trim().toLowerCase();
    if (!EmailOtpLogic.isValidEmail(e)) return 'email-invalid';
    try {
      await _functions
          .httpsCallable('requestEmailCode')
          .call({'email': e});
      _email = e;
      _codeSent = true;
      notifyListeners();
      return null;
    } on FirebaseFunctionsException catch (ex) {
      return _mapError(ex, 'email-send-failed');
    } catch (_) {
      return 'email-send-failed';
    }
  }

  /// Step 2: verify the 6-digit code and sign in with the custom
  /// token the function mints. Returns null on success, else an
  /// error slug.
  Future<String?> verifyCode(String email, String code) async {
    if (!FirebaseBootstrap.available) return 'not-configured';
    final e = email.trim().toLowerCase();
    if (!EmailOtpLogic.isValidEmail(e)) return 'email-invalid';
    if (!EmailOtpLogic.isValidCode(code)) return 'code-wrong';
    try {
      final result = await _functions
          .httpsCallable('verifyEmailCode')
          .call({'email': e, 'code': code.trim()});
      final data = result.data;
      final token =
          data is Map ? data['token'] as String? : null;
      if (token == null || token.isEmpty) return 'code-wrong';
      await FirebaseAuth.instance.signInWithCustomToken(token);
      _codeSent = false;
      notifyListeners();
      return null;
    } on FirebaseFunctionsException catch (ex) {
      return _mapError(ex, 'code-wrong');
    } on FirebaseAuthException catch (ex) {
      // A minted token is rejected only if it is stale/invalid.
      if (ex.code == 'invalid-custom-token') return 'code-expired';
      return 'code-wrong';
    } catch (_) {
      return 'code-wrong';
    }
  }

  /// Forget the in-progress code flow (e.g. user switched tabs).
  void reset() {
    _codeSent = false;
    _email = null;
    notifyListeners();
  }
}
