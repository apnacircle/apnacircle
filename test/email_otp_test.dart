import 'package:apnacircle/core/language_service.dart';
import 'package:apnacircle/l10n/strings.dart';
import 'package:apnacircle/screens/auth_screen.dart';
import 'package:apnacircle/services/auth_service.dart';
import 'package:apnacircle/services/email_otp_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// v0.6 tests: 6-digit email OTP login — pure logic + the new
/// "Email code" option on the login screen. Existing Email/Password
/// + link login is NOT touched here (see AuthService tests in
/// test/apnacircle_test.dart); trial behaviour is NOT touched
/// (see test/trial_test.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // --- Code format: exactly 6 digits ---

  test('code format: only 6 digits pass', () {
    expect(EmailOtpLogic.isValidCode('123456'), true);
    expect(EmailOtpLogic.isValidCode('000000'), true);
    expect(EmailOtpLogic.isValidCode(' 123456 '), true); // trimmed
    expect(EmailOtpLogic.isValidCode('12345'), false);
    expect(EmailOtpLogic.isValidCode('1234567'), false);
    expect(EmailOtpLogic.isValidCode('12345a'), false);
    expect(EmailOtpLogic.isValidCode(''), false);
    expect(EmailOtpLogic.codeLength, 6);
  });

  test('email validation: plain sanity check', () {
    expect(EmailOtpLogic.isValidEmail('a@gmail.com'), true);
    expect(EmailOtpLogic.isValidEmail('A@Gmail.COM'), true);
    expect(EmailOtpLogic.isValidEmail('not-an-email'), false);
    expect(EmailOtpLogic.isValidEmail('a@b'), false);
    expect(EmailOtpLogic.isValidEmail(''), false);
  });

  // --- Hash: never the raw code, stable, 64 hex chars ---

  test('hash never equals the raw code', () {
    const code = '482913';
    final h1 = EmailOtpLogic.sha256Hex(code);
    final h2 = EmailOtpLogic.sha256Hex(code);
    expect(h1, h2);
    expect(h1.length, 64); // SHA-256 hex
    expect(h1.contains(code), false);
    expect(EmailOtpLogic.sha256Hex('482914'), isNot(h1));
  });

  // --- Expiry math: 10 minutes, then dead ---

  test('expiry math: 10 minutes, then dead', () {
    expect(EmailOtpLogic.codeTtlSeconds, 600);
    const now = 1700000000000;
    const expiresAt = now + EmailOtpLogic.codeTtlSeconds * 1000;
    expect(EmailOtpLogic.isExpired(expiresAt, now), false);
    expect(EmailOtpLogic.isExpired(expiresAt, expiresAt - 1), false);
    expect(EmailOtpLogic.isExpired(expiresAt, expiresAt), true);
    expect(EmailOtpLogic.isExpired(expiresAt, expiresAt + 1), true);
  });

  // --- Attempt limit: 5 wrong tries, then locked ---

  test('attempt limit: 5 wrong tries, then locked', () {
    expect(EmailOtpLogic.maxAttempts, 5);
    expect(EmailOtpLogic.canAttempt(0), true);
    expect(EmailOtpLogic.canAttempt(4), true);
    expect(EmailOtpLogic.canAttempt(5), false);
    expect(EmailOtpLogic.canAttempt(9), false);
    expect(EmailOtpLogic.attemptsLeft(0), 5);
    expect(EmailOtpLogic.attemptsLeft(3), 2);
    expect(EmailOtpLogic.attemptsLeft(5), 0);
    expect(EmailOtpLogic.attemptsLeft(9), 0);
  });

  // --- Error slugs map to real EN + UR messages ---

  test('every error slug has an EN and a UR message', () {
    const slugs = [
      'email-invalid',
      'code-wrong',
      'code-expired',
      'code-not-found',
      'too-many-attempts',
      'too-many-requests',
      'email-not-configured',
      'email-send-failed',
      'network-error',
      'not-configured',
      'something-else-entirely', // unknown slug -> fallback message
    ];
    for (final slug in slugs) {
      final key = EmailOtpLogic.messageKeyFor(slug);
      // The key must exist in BOTH languages (tr falls back to the
      // key itself when a translation is missing — that must not
      // happen for any slug the app can show).
      expect(tr(false, key), isNot(key), reason: 'EN missing: $slug->$key');
      expect(tr(true, key), isNot(key), reason: 'UR missing: $slug->$key');
      expect(tr(true, key), isNot(tr(false, key)),
          reason: 'UR must differ from EN: $key');
    }
  });

  // --- Login screen: the "Email code" option exists ---

  testWidgets('AuthScreen shows an Email code option', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => LanguageService()),
          ChangeNotifierProvider(create: (_) => AuthService()),
          ChangeNotifierProvider(create: (_) => EmailOtpService()),
        ],
        child: const MaterialApp(home: AuthScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // All three sign-in options are offered; Email/Password + SMS
    // login are still there (untouched by v0.6).
    expect(find.text('Phone (SMS OTP)'), findsOneWidget);
    expect(find.text('Gmail'), findsOneWidget);
    expect(find.text('Email code'), findsOneWidget);

    // Tapping "Email code" shows the send-code flow (no password
    // field — this flow needs no password at all).
    await tester.tap(find.text('Email code'));
    await tester.pumpAndSettle();
    expect(find.text('Send code to Gmail'), findsOneWidget);
    expect(find.text('Password (6+ characters)'), findsNothing);
  });

  testWidgets('Email code screen speaks Urdu when Urdu is chosen',
      (tester) async {
    final lang = LanguageService()..choose(const Locale('ur'));
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: lang),
          ChangeNotifierProvider(create: (_) => AuthService()),
          ChangeNotifierProvider(create: (_) => EmailOtpService()),
        ],
        child: const MaterialApp(home: AuthScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('ای میل کوڈ'));
    await tester.pumpAndSettle();
    expect(find.text('جی میل پر کوڈ بھیجیں'), findsOneWidget);
  });
}
