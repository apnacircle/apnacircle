import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/join_request.dart';
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
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    if (req == null) {
      // Returning member — joined directly, no request needed.
      setState(() => _info = 'Welcome back — aap circle mein aa gaye.');
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
    final sync = context.read<SyncService>();
    final pin = context.read<PinService>();
    final service = context.read<JoinRequestService>();
    final (circle, err) = await sync.joinCircle(
      req.inviteCode,
      phoneNumber: req.phone,
      role: 'child',
      displayName: req.name,
    );
    if (!mounted) return;
    if (circle == null) {
      _joiningAfterApproval = false;
      setState(() => _error = err ?? 'Join nahi ho saka — dobara try karein.');
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
        title: const Text('Join family circle'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Wapas — role badlein',
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
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Join ke liye internet + Gmail sign-in chahiye — '
                  'abhi live sync off hai, is liye request nahi bhej '
                  'sakte. Demo mode mein aage badh sakte hain (sab '
                  'kuch sirf is phone par).',
                  style: TextStyle(fontSize: 16),
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _skipForNow,
              child: const Text('Demo mode mein aage badhein'),
            ),
            const SizedBox(height: 16),
          ],
          if (_stage == _JoinStage.waiting) ...[
            const Icon(Icons.hourglass_top, size: 48, color: Colors.orange),
            const SizedBox(height: 16),
            const Text(
              'Request parent ko bhej di gayi hai.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Jaise hi parent Allow karein ge, aap circle mein aa '
              'jayein ge — is screen par hi intezar karein, app '
              'band karne ki zaroorat nahi.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
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
                child: const Text('Dobara join karein'),
              ),
            ],
          ] else if (_stage == _JoinStage.denied) ...[
            const Icon(Icons.block, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              req?.reason == JoinDenyReason.wrongCode
                  ? 'Parent ka code ghalat tha.'
                  : 'Parent ne allow nahi kiya.',
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              req?.reason == JoinDenyReason.wrongCode
                  ? 'Jo parent code aap ne likha, wo parent ke code '
                      'se nahi mila. Sahi code likh kar dobara try karein.'
                  : 'Parent se baat kar ke dobara try karein — jab '
                      'wo Allow karein ge, aap add ho jayein ge.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _retry,
              child: const Text('Dobara try karein'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _skipForNow,
              child: const Text('Abhi nahi — baad mein join karunga'),
            ),
          ] else ...[
            const Text(
              'Parent ke circle mein join hone ke liye un ka code '
              'chahiye. Request parent ko jaye gi — wo Allow karein '
              'ge to aap add ho jayein ge, Deny karein ge to nahi.',
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Aap ka naam',
                hintText: 'e.g. Ali',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _inviteCode,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: '6-digit invite code',
                hintText: 'e.g. 482913',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Apna mobile number',
                hintText: 'e.g. 03001234567',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _parentPin,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'Parent ka PIN / code',
                hintText: 'Wo code jo parent ne banaya tha',
                border: OutlineInputBorder(),
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
                  : const Text('Join request bhejein'),
            ),
            if (!sync.isAvailable)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Request tab bhej sakte hain jab Gmail se sign-in ho '
                  '— abhi live sync off hai.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _skipForNow,
              child: const Text('Abhi nahi — baad mein join karunga'),
            ),
          ],
        ],
      ),
    );
  }
}
