import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/join_request.dart';
import '../core/language_service.dart';
import '../l10n/strings.dart';
import '../services/join_request_service.dart';
import '../services/onboarding_service.dart';
import '../services/pin_service.dart';
import '../services/sync_service.dart';

/// Child join (v0.6.30): Gmail login is done — now the child asks
/// the parent to let them in.
///
/// The child types their name + the 6-digit invite code + their
/// mobile + the PARENT's PIN. Nothing joins yet: a `pending`
/// request goes to the parent, who sees it instantly and taps
/// Allow or Deny. The child waits on this screen — the moment the
/// parent allows, the phone joins by itself and moves on to the
/// one-time setup. Denied (or a wrong parent code) means "try
/// again" — the request can be re-sent as often as needed.
///
/// A child NEVER sees the trial / payment screens — this screen
/// is the whole join flow. In demo mode (no Firebase / not signed
/// in) joining is impossible, so the screen says so plainly and
/// offers to continue in demo mode instead.
enum _JoinStage { form, waiting, denied }

class JoinRequestScreen extends StatefulWidget {
  const JoinRequestScreen({super.key});
  @override
  State<JoinRequestScreen> createState() => _JoinRequestScreenState();
}

class _JoinRequestScreenState extends State<JoinRequestScreen> {
  final _name = TextEditingController();
  final _inviteCode = TextEditingController();
  final _phone = TextEditingController();
  final _parentPin = TextEditingController();

  _JoinStage _stage = _JoinStage.form;
  bool _busy = false;
  String? _error;
  String? _info;
  bool _joiningAfterApproval = false;

  @override
  void initState() {
    super.initState();
    // Resume a request that was still open when the app closed.
    WidgetsBinding.instance.addPostFrameCallback((_) => _resumePending());
  }

  Future<void> _resumePending() async {
    if (!mounted) return;
    final service = context.read<JoinRequestService>();
    final circleId = service.pendingCircleId;
    if (circleId == null) return;
    final req = await service.fetchMyRequest(circleId);
    if (!mounted) return;
    if (req == null) {
      await service.clearPendingCircle();
      return;
    }
    if (req.status == JoinRequestStatus.pending) {
      setState(() => _stage = _JoinStage.waiting);
      service.watchMyRequest(circleId);
    } else if (req.status == JoinRequestStatus.approved) {
      setState(() => _stage = _JoinStage.waiting);
      await _joinAfterApproval(req);
    } else {
      setState(() => _stage = _JoinStage.denied);
      service.watchMyRequest(circleId);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _inviteCode.dispose();
    _phone.dispose();
    _parentPin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final isUrdu = context.read<LanguageService>().isUrdu;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    final service = context.read<JoinRequestService>();
    final (req, err) = await service.submitRequest(
      inviteCode: _inviteCode.text,
      phone: _phone.text,
      parentPin: _parentPin.text,
      displayName: _name.text,
      isUrdu: isUrdu,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    if (req == null) {
      // Returning member — joined directly, no request needed.
      setState(() => _info = tr(isUrdu, 'onb_joinWelcomeBack'));
      return;
    }
    setState(() => _stage = _JoinStage.waiting);
  }

  /// The parent approved: run the normal join now (member node +
  /// role entry — the child's own writes), cache the parent PIN
  /// hash for the offline gates, and let AppRoot move on.
  Future<void> _joinAfterApproval(JoinRequest req) async {
    if (_joiningAfterApproval) return;
    _joiningAfterApproval = true;
    final isUrdu = context.read<LanguageService>().isUrdu;
    final sync = context.read<SyncService>();
    final pin = context.read<PinService>();
    final service = context.read<JoinRequestService>();
    final (circle, err) = await sync.joinCircle(
      req.inviteCode,
      phoneNumber: req.phone,
      role: 'child',
      displayName: req.name,
      isUrdu: isUrdu,
    );
    if (!mounted) return;
    if (circle == null) {
      _joiningAfterApproval = false;
      setState(() => _error = err ?? tr(isUrdu, 'onb_joinFailedRetry'));
      return;
    }
    await sync.cacheParentPinHash(pin);
    await service.clearPendingCircle();
    service.stopWatchingMyRequest();
  }

  Future<void> _retry() async {
    final service = context.read<JoinRequestService>();
    await service.clearPendingCircle();
    service.stopWatchingMyRequest();
    if (!mounted) return;
    setState(() {
      _stage = _JoinStage.form;
      _error = null;
      _parentPin.clear();
    });
  }

  Future<void> _skipForNow() async {
    await context.read<OnboardingService>().markJoinSkipped();
  }

  /// v0.6.31: wrong role tapped by mistake — cancel the request
  /// (if one was sent) and go back to the role screen.
  Future<void> _backToRole() async {
    final service = context.read<JoinRequestService>();
    await service.cancelMyRequest();
    if (!mounted) return;
    await context.read<OnboardingService>().clearRole();
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final service = context.watch<JoinRequestService>();
    final lang = context.watch<LanguageService>();
    String t(String key) => tr(lang.isUrdu, key);
    final req = service.myRequest;

    // Live decision: the parent just allowed / denied while this
    // screen was open.
    if (_stage == _JoinStage.waiting && req != null) {
      if (req.status == JoinRequestStatus.approved &&
          !_joiningAfterApproval) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _joinAfterApproval(req),
        );
      } else if (req.status == JoinRequestStatus.denied) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _stage == _JoinStage.waiting) {
            setState(() => _stage = _JoinStage.denied);
          }
        });
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(t('onb_joinTitle')),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: t('onb_backChangeRole'),
          onPressed: _backToRole,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // Demo mode: joining needs the server, so the request
          // cannot be sent — the notice says so plainly, and the
          // form below stays visible (disabled) so the child sees
          // what joining needs. "Demo mode" skips the join.
          if (!sync.isAvailable) ...[
            Card(
              color: Colors.orange.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  t('onb_joinDemoNotice'),
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _skipForNow,
              child: Text(t('onb_joinDemoContinue')),
            ),
            const SizedBox(height: 16),
          ],
          if (_stage == _JoinStage.waiting) ...[
            const Icon(Icons.hourglass_top, size: 48, color: Colors.orange),
            const SizedBox(height: 16),
            Text(
              t('onb_joinRequestSent'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              t('onb_joinWaiting'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator()),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: req == null
                    ? null
                    : () => _joinAfterApproval(req),
                child: Text(t('onb_joinTryAgain')),
              ),
            ],
          ] else if (_stage == _JoinStage.denied) ...[
            const Icon(Icons.block, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              req?.reason == JoinDenyReason.wrongCode
                  ? t('onb_joinWrongCode')
                  : t('onb_joinDenied'),
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              req?.reason == JoinDenyReason.wrongCode
                  ? t('onb_joinWrongCodeDetail')
                  : t('onb_joinDeniedDetail'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _retry,
              child: Text(t('onb_tryAgain')),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _skipForNow,
              child: Text(t('onb_joinNotNow')),
            ),
          ] else ...[
            Text(
              t('onb_joinFormIntro'),
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: t('onb_yourName'),
                hintText: 'e.g. Ali',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _inviteCode,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: InputDecoration(
                labelText: t('onb_inviteCodeLabel'),
                hintText: 'e.g. 482913',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: t('onb_yourMobile'),
                hintText: 'e.g. 03001234567',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _parentPin,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 6,
              decoration: InputDecoration(
                labelText: t('onb_parentPinCode'),
                hintText: t('onb_parentCodeHint'),
                border: const OutlineInputBorder(),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            if (_info != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _info!,
                  style: const TextStyle(color: Colors.green),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: (!sync.isAvailable || _busy) ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(t('onb_sendJoinRequest')),
            ),
            if (!sync.isAvailable)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  t('onb_joinNeedsSignIn'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _skipForNow,
              child: Text(t('onb_joinNotNow')),
            ),
          ],
        ],
      ),
    );
  }
}
