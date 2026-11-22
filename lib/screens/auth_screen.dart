import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';

/// Sign in / sign up (v0.3, 22 Nov 2026).
///
/// Two channels, per Mujahid's standing decision — OTP on BOTH the
/// SIM number AND Gmail:
/// * **Phone (SIM):** Firebase sends a 6-digit SMS OTP to the SIM
///   number. Type the number -> "Send OTP" -> type the code.
/// * **Gmail:** Email + password. After sign-up a verification
///   LINK is sent to the Gmail inbox (Firebase Auth has no
///   built-in 6-digit email OTP — the link IS the Gmail channel;
///   see AuthService).
///
/// Shown only when Firebase is configured and nobody is signed in
/// (see AppRoot). "Continue in demo mode" skips sign-in — the app
/// then works exactly like v0.2 (local only, no cross-phone sync).
/// The user can sign in later from Settings -> Account & Circles.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isPhone = true;
  bool _isSignUp = false;
  bool _busy = false;
  String? _error;
  String? _info;

  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    _email.dispose();
    _password.dispose();
    _name.dispose();
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
    final phone = _phone.text.trim();
    if (phone.isEmpty) {
      setState(() => _error = 'Type your mobile number first (+92…).');
      return;
    }
    await _run(() async {
      final err =
          await context.read<AuthService>().startPhoneSignIn(phone);
      if (err == null && mounted) {
        setState(() => _info = 'OTP sent by SMS — type the 6-digit code.');
      }
      return err;
    });
  }

  Future<void> _verifyOtp() async {
    if (_code.text.trim().length < 6) {
      setState(() => _error = 'Type the 6-digit code from the SMS.');
      return;
    }
    await _run(
      () => context.read<AuthService>().confirmPhoneCode(_code.text),
    );
  }

  Future<void> _emailGo() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Email and password are both needed.');
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
          setState(() => _info =
              'Account created. A verification link was sent to your Gmail — open it to verify.');
        }
        return err;
      }
      return auth.signInWithEmail(email, password);
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in — ApnaCircle')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Sign in to sync your family across phones: the parent on '
            'one phone, the child on another. One account works on a '
            'new phone too — your circles come back.',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Phone (SMS OTP)')),
              ButtonSegment(value: false, label: Text('Gmail')),
            ],
            selected: {_isPhone},
            onSelectionChanged: (v) =>
                setState(() => _isPhone = v.first),
          ),
          const SizedBox(height: 20),
          if (_isPhone) ...[
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Mobile number',
                hintText: '+923001234567',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _sendOtp,
              child: const Text('Send OTP by SMS'),
            ),
            if (auth.phoneCodeSent) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: '6-digit OTP code',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _verifyOtp,
                child: const Text('Verify OTP & Sign in'),
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              'The OTP comes by SMS to your SIM number. No SMS yet? '
              'Check the number, then ask for a new code.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ] else ...[
            if (_isSignUp)
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Your name',
                  border: OutlineInputBorder(),
                ),
              ),
            if (_isSignUp) const SizedBox(height: 12),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Gmail address',
                hintText: 'you@gmail.com',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password (6+ characters)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _emailGo,
              child: Text(_isSignUp ? 'Create account' : 'Sign in'),
            ),
            TextButton(
              onPressed: () => setState(() => _isSignUp = !_isSignUp),
              child: Text(
                _isSignUp
                    ? 'Already have an account? Sign in'
                    : 'No account yet? Create one',
              ),
            ),
            const Text(
              'After sign-up a verification link is sent to your '
              'Gmail inbox — open it to verify. (Firebase has no '
              '6-digit Gmail OTP; the link is the Gmail channel.)',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
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
            child: const Text('Continue without account (demo mode)'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Demo mode works like before — everything stays on this '
            'phone only, no sync to another phone. You can sign in '
            'later from Settings → Account & Circles.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
