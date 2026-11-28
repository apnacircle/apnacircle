import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/language_service.dart';
import '../l10n/strings.dart';
import '../services/auth_service.dart';
import '../services/email_otp_service.dart';
import '../services/onboarding_service.dart';

/// Sign in / sign up (v0.3, 22 Nov 2026; email-code login v0.6).
///
/// THREE channels, per Mujahid's standing decision — OTP on BOTH
/// the SIM number AND Gmail:
/// * **Phone (SIM):** Firebase sends a 6-digit SMS OTP to the SIM
///   number. Type the number -> "Send OTP" -> type the code.
/// * **Gmail:** Email + password. After sign-up a verification
///   LINK is sent to the Gmail inbox.
/// * **Email code (v0.6):** a real 6-digit code in the Gmail inbox
///   — no password needed. Cloud Function + SMTP sender (see
///   EmailOtpService): "Send code to Gmail" -> type the code ->
///   the function mints a custom token and the app signs in.
///   Same limits as the server: 10-minute code, 5 wrong tries,
///   5 codes/hour per email.
///
/// Shown only when Firebase is configured and nobody is signed in
/// (see AppRoot). "Continue in demo mode" skips sign-in — the app
/// then works exactly like v0.2 (local only, no cross-phone sync).
/// The user can sign in later from Settings -> Account & Circles.
class AuthScreen extends StatefulWidget {
  /// Which tab opens first: 0 = Phone (SMS OTP), 1 = Gmail
  /// (password), 2 = Email code. Onboarding (v0.6.30) opens the
  /// Gmail code tab — phone OTP is billing-blocked, so the Gmail
  /// code is the working route.
  final int initialMode;

  /// v0.6.31: first-run only (AppRoot passes true) — a back arrow
  /// that forgets the role and returns to the role screen, so a
  /// wrong Parent/Child tap is undoable even at the login step.
  /// When the screen is pushed from Settings (sign in later),
  /// this stays false and the normal Navigator back applies.
  final bool showRoleBack;

  const AuthScreen({
    super.key,
    this.initialMode = 0,
    this.showRoleBack = false,
  });
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  /// 0 = Phone (SMS OTP), 1 = Gmail (password), 2 = Email code.
  late int _mode;
  bool _isSignUp = false;
  bool _busy = false;
  String? _error;
  String? _info;

  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  final _emailCode = TextEditingController();

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
  }

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    _email.dispose();
    _password.dispose();
    _name.dispose();
    _emailCode.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    final err = await action();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  Future<void> _sendOtp() async {
    final isUrdu = context.read<LanguageService>().isUrdu;
    final phone = _phone.text.trim();
    if (phone.isEmpty) {
      setState(() => _error = tr(isUrdu, 'onb_authErrPhoneEmpty'));
      return;
    }
    await _run(() async {
      final err =
          await context.read<AuthService>().startPhoneSignIn(phone);
      if (err == null && mounted) {
        setState(() => _info = tr(isUrdu, 'onb_authOtpSent'));
      }
      return err;
    });
  }

  Future<void> _verifyOtp() async {
    final isUrdu = context.read<LanguageService>().isUrdu;
    if (_code.text.trim().length < 6) {
      setState(() => _error = tr(isUrdu, 'onb_authErrCodeShort'));
      return;
    }
    await _run(
      () => context.read<AuthService>().confirmPhoneCode(_code.text),
    );
  }

  Future<void> _emailGo() async {
    final isUrdu = context.read<LanguageService>().isUrdu;
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = tr(isUrdu, 'onb_authErrEmailPass'));
      return;
    }
    final auth = context.read<AuthService>();
    await _run(() async {
      if (_isSignUp) {
        final err = await auth.signUpWithEmail(
          email,
          password,
          _name.text,
        );
        if (err == null && mounted) {
          setState(() => _info = tr(isUrdu, 'onb_authAccountCreated'));
        }
        return err;
      }
      return auth.signInWithEmail(email, password);
    });
  }

  /// Email-code login (v0.6): step 1 — send the 6-digit code.
  /// Errors come back as slugs; they are shown in the user's
  /// language via the l10n keys (see EmailOtpLogic.messageKeyFor).
  Future<void> _sendEmailCode() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _error = tr(
          context.read<LanguageService>().isUrdu,
          'emailCodeInvalidEmail'));
      return;
    }
    final lang = context.read<LanguageService>();
    await _run(() async {
      final slug = await context
          .read<EmailOtpService>()
          .requestCode(email);
      if (slug == null && mounted) {
        setState(() => _info = tr(lang.isUrdu, 'emailCodeSent'));
        return null;
      }
      return slug == null ? null : tr(lang.isUrdu,
          EmailOtpLogic.messageKeyFor(slug));
    });
  }

  /// Email-code login (v0.6): step 2 — verify the code, sign in.
  Future<void> _verifyEmailCode() async {
    if (_emailCode.text.trim().length < 6) {
      setState(() => _error = tr(
          context.read<LanguageService>().isUrdu, 'emailCodeHint'));
      return;
    }
    final lang = context.read<LanguageService>();
    await _run(() async {
      final slug = await context.read<EmailOtpService>().verifyCode(
            _email.text,
            _emailCode.text,
          );
      return slug == null
          ? null
          : tr(lang.isUrdu, EmailOtpLogic.messageKeyFor(slug));
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final emailOtp = context.watch<EmailOtpService>();
    final lang = context.watch<LanguageService>();
    String t(String key) => tr(lang.isUrdu, key);
    return Scaffold(
      appBar: AppBar(
        title: Text(t('onb_authTitle')),
        leading: widget.showRoleBack
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: t('onb_backChangeRole'),
                onPressed: () =>
                    context.read<OnboardingService>().clearRole(),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            t('onb_authIntro'),
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 16),
          SegmentedButton<int>(
            segments: [
              ButtonSegment(value: 0, label: Text(t('onb_authPhoneTab'))),
              ButtonSegment(value: 1, label: Text(t('onb_authGmailTab'))),
              ButtonSegment(
                  value: 2, label: Text(t('emailCodeTitle'))),
            ],
            selected: {_mode},
            onSelectionChanged: (v) => setState(() => _mode = v.first),
          ),
          const SizedBox(height: 20),
          if (_mode == 0) ...[
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: t('onb_authMobileLabel'),
                hintText: '+923001234567',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _sendOtp,
              child: Text(t('onb_authSendOtp')),
            ),
            if (auth.phoneCodeSent) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(
                  labelText: t('onb_authOtpCode'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _verifyOtp,
                child: Text(t('onb_authVerifyOtp')),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              t('onb_authOtpNote'),
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ] else if (_mode == 1) ...[
            if (_isSignUp)
              TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: t('onb_yourName'),
                  border: const OutlineInputBorder(),
                ),
              ),
            if (_isSignUp) const SizedBox(height: 12),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: t('onb_authGmailLabel'),
                hintText: 'you@gmail.com',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: InputDecoration(
                labelText: t('onb_authPasswordLabel'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _emailGo,
              child: Text(_isSignUp ? t('onb_authCreateAccount') : t('onb_authSignIn')),
            ),
            TextButton(
              onPressed: () => setState(() => _isSignUp = !_isSignUp),
              child: Text(
                _isSignUp ? t('onb_authHaveAccount') : t('onb_authNoAccount'),
              ),
            ),
            Text(
              t('onb_authVerifyNote'),
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ] else ...[
            // Email-code login (v0.6): no password needed.
            Text(
              t('emailCodeInfo'),
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: t('onb_authGmailLabel'),
                hintText: 'you@gmail.com',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _sendEmailCode,
              child: Text(t('emailCodeSend')),
            ),
            if (emailOtp.codeSent) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _emailCode,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(
                  labelText: t('emailCodeHint'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _verifyEmailCode,
                child: Text(t('emailCodeVerify')),
              ),
              TextButton(
                onPressed: _busy ? null : _sendEmailCode,
                child: Text(t('emailCodeResend')),
              ),
              Text(
                t('onb_authCodeExpiry'),
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ],
          ],
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          if (_info != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_info!, style: const TextStyle(color: Colors.green)),
            ),
          const Divider(height: 32),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => context.read<AuthService>().skipDemo(),
            child: Text(t('onb_authDemoContinue')),
          ),
          const SizedBox(height: 8),
          Text(
            t('onb_authDemoNote'),
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
