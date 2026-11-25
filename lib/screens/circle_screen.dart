import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/escape_gate.dart';
import '../services/auth_service.dart';
import '../services/firebase_bootstrap.dart';
import '../services/pin_service.dart';
import '../services/sync_service.dart';
import 'auth_screen.dart';
import 'pin_gate_dialog.dart';

/// Account & Circles (v0.3, 22 Nov 2026).
///
/// This is where the two-phone test happens:
/// 1. PARENT phone: sign in, "Create a circle", share the 6-digit
///    invite code with the child.
/// 2. CHILD phone: sign in, "Join a circle", type the code, role
///    "child". Both phones now see the same circle.
/// 3. Parent changes a lock / alert on the parent phone -> the
///    child's phone gets it live. The child's live location shows
///    on the parent's map.
///
/// Multi-circle: one account can be a member of one circle and
/// admin (parent) of other circles — each circle has its own role,
/// PIN and locks. Switch the active circle here.
///
/// Parent-phone-loss recovery: signing in on a NEW phone restores
/// the circles (they belong to the account). "Restore my circles"
/// also pulls the parent PIN hash from any circle where this
/// account is the parent, so the same PIN works on the new phone.
class CircleScreen extends StatefulWidget {
  const CircleScreen({super.key});
  @override
  State<CircleScreen> createState() => _CircleScreenState();
}

class _CircleScreenState extends State<CircleScreen> {
  final _circleName = TextEditingController();
  final _inviteCode = TextEditingController();
  String _joinRole = 'child';
  bool _busy = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _circleName.dispose();
    _inviteCode.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final sync = context.read<SyncService>();
    final pin = context.read<PinService>();
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    await sync.refreshMyCircles();
    // Parent PIN recovery: for every circle where I am the parent,
    // adopt its stored PIN hash if this phone has no PIN yet.
    var restoredPin = false;
    for (final c in sync.myCircles) {
      if (c.role != 'parent' || pin.hasPin) break;
      final hash = await sync.fetchPinHash(c.id);
      if (hash != null) {
        await pin.adoptHash(hash);
        restoredPin = true;
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _info = restoredPin
          ? 'Circles restored — and your parent PIN was recovered from your circle.'
          : 'Circles restored.';
    });
  }

  Future<void> _createCircle() async {
    final sync = context.read<SyncService>();
    final pin = context.read<PinService>();
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    final (circle, err) = await sync.createCircle(
      _circleName.text,
      pinHash: pin.pinHash,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
      _info = circle == null
          ? null
          : 'Circle "${circle.name}" created! Invite code: ${circle.inviteCode} — share it with the child.';
    });
    if (circle != null) _circleName.clear();
  }

  Future<void> _joinCircle() async {
    final sync = context.read<SyncService>();
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    final (circle, err) = await sync.joinCircle(
      _inviteCode.text,
      role: _joinRole,
    );
    if (!mounted) return;
    if (circle != null) {
      // v0.6.13 (offline rule): cache the parent PIN hash now, so
      // this phone's PIN gates work even before the next start —
      // never leave a member's phone with no local copy after its
      // first sync.
      await sync.cacheParentPinHash(context.read<PinService>());
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
      _info = circle == null
          ? null
          : 'Joined "${circle.name}" as ${circle.role}.';
    });
    if (circle != null) _inviteCode.clear();
  }

  /// Escape-hatch gate (v0.6.13, part E): a CHILD signing out or
  /// deleting their account must first enter the parent PIN — the
  /// SAME parent PIN that unlocks apps (one PIN for everything).
  /// Signing out is how a child drops out of the circle silently,
  /// so it is gated exactly like deleting. Parent role: never
  /// gated. No hash anywhere (never set, or offline with nothing
  /// stored) = fail closed: the escape is blocked, with a plain
  /// message, never let through unverified.
  Future<bool> _passEscapeGate() async {
    final sync = context.read<SyncService>();
    if (!childEscapeNeedsParentPin(sync.activeCircle?.role)) return true;
    final hash = await resolveParentPinHash(
      sync: sync,
      pin: context.read<PinService>(),
    );
    if (!mounted) return false;
    if (hash == null) {
      setState(() => _error =
          'Parent PIN is needed for this — connect to the internet and try again.');
      return false;
    }
    var passed = false;
    await askParentPin(
      context,
      expectedHash: hash,
      onUnlocked: () => passed = true,
    );
    return passed;
  }

  Future<void> _signOut() async {
    if (!await _passEscapeGate()) return;
    await _doSignOut();
  }

  Future<void> _doSignOut() async {
    await context.read<AuthService>().signOut();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const AuthScreen()),
    );
  }

  Future<void> _deleteAccount() async {
    if (!await _passEscapeGate()) return;
    await _doDeleteAccount();
  }

  Future<void> _doDeleteAccount() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This deletes your ApnaCircle account. Your circles stay '
          'for the other members, but you leave them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final err = await context.read<AuthService>().deleteAccount();
    if (!mounted) return;
    if (err != null) {
      setState(() => _error = err);
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const AuthScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final sync = context.watch<SyncService>();
    final live = FirebaseBootstrap.available && auth.signedIn;

    if (!live) {
      return Scaffold(
        appBar: AppBar(title: const Text('Account & Circles')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Live sync is OFF — Firebase is not set up yet, or '
                'nobody is signed in. The app works in demo mode '
                '(everything on this phone only).',
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AuthScreen()),
                ),
                child: const Text('Sign in / Create account'),
              ),
            ],
          ),
        ),
      );
    }

    final identity = auth.email ?? auth.phoneNumber ?? 'Account';
    return Scaffold(
      appBar: AppBar(title: const Text('Account & Circles')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const Icon(Icons.account_circle),
            title: Text(identity),
            subtitle: Text(
              'Live sync ON · ${sync.myCircles.length} circle(s)',
            ),
          ),
          const Divider(),
          const Text(
            'My circles',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const Text(
            'One account, many circles: you can be a member in one '
            'circle and the parent (admin) of others. Tap a circle '
            'to make it active.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          if (sync.myCircles.isNotEmpty)
            RadioGroup<String>(
              groupValue: sync.activeCircleId,
              onChanged: (v) {
                if (v != null) sync.setActiveCircle(v);
              },
              child: Column(
                children: [
                  for (final c in sync.myCircles)
                    RadioListTile<String>(
                      title: Text(c.name),
                      subtitle: Text(
                        'Role: ${c.role}${c.inviteCode.isNotEmpty ? ' · Code: ${c.inviteCode}' : ''}',
                      ),
                      value: c.id,
                    ),
                ],
              ),
            ),
          if (sync.myCircles.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No circles yet — create one below.'),
            ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _restore,
            child: const Text('Restore my circles'),
          ),
          const Divider(height: 32),
          const Text(
            'Create a circle (parent)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _circleName,
            decoration: const InputDecoration(
              labelText: 'Circle name',
              hintText: 'e.g. Family',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _createCircle,
            child: const Text('Create circle & get invite code'),
          ),
          const Divider(height: 32),
          const Text(
            'Join a circle (child / member)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
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
          DropdownButtonFormField<String>(
            initialValue: _joinRole,
            decoration: const InputDecoration(labelText: 'My role'),
            items: const [
              DropdownMenuItem(value: 'child', child: Text('Child')),
              DropdownMenuItem(value: 'elderly', child: Text('Elderly')),
              DropdownMenuItem(value: 'member', child: Text('Member')),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _joinRole = v);
            },
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _joinCircle,
            child: const Text('Join circle'),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child:
                  Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          if (_info != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _info!,
                style: const TextStyle(color: Colors.green),
              ),
            ),
          const Divider(height: 32),
          OutlinedButton(
            onPressed: _busy ? null : _signOut,
            child: const Text('Sign out'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : _deleteAccount,
            child: const Text(
              'Delete my account',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }
}
