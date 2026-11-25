import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/escape_gate.dart';
import '../services/device_admin_service.dart';
import '../services/device_owner_service.dart';
import '../services/pin_service.dart';
import '../services/sync_service.dart';
import 'pin_gate_dialog.dart';

/// Device Owner one-time setup (v0.6.13, 25 Nov 2026).
///
/// The user order: a child must NOT be able to delete the app on
/// her own will — deleting needs the parent's code. Device Owner
/// is the only enforcement Android itself provides: a device-owner
/// app has NO working uninstall in Settings.
///
/// FLOW (parent-driven, once per child phone):
/// 1. The parent opens this screen on their own phone. The screen
///    asks for the parent PIN first — a child holding the phone
///    cannot even see the QR without the code.
/// 2. The parent fills the APK download URL (the exact build the
///    QR checksum is computed from — see below) and, optionally,
///    the home Wi-Fi, and shows the QR code.
/// 3. The child's phone is factory-reset (or brand new) → setup
///    wizard → tap 6 times on the welcome screen → scan the QR.
///    Android downloads the APK, checks the signature checksum,
///    installs it and makes it the device owner.
/// 4. From then on the child cannot uninstall from Settings. The
///    parent removes it only from here (PIN-gated) or by a
///    recovery-mode factory reset.
///
/// HONEST LIMITS — shown on this screen, not hidden:
/// * Needs a factory reset once (or a fresh phone). It CANNOT be
///   done on an already-set-up phone without a reset.
/// * A recovery-mode factory reset still wipes the phone — no app
///   can stop that. Google FRP still applies.
/// * The checksum is the signing certificate of the APK at the
///   download URL. CI builds are debug-signed with a FRESH key
///   per run, so the QR is only valid for the exact APK build it
///   was generated from — the screen computes the checksum from
///   the app installed on THIS phone, so put THAT build at the URL.
/// * Keep the parent PIN secret from the child: anyone who knows
///   the code can remove the protection. If the parent forgets
///   the PIN, only a factory reset removes the protection.
/// * Play Store will need a justification for device-owner use at
///   submission (family-safety / parental control).
class DeviceOwnerSetupScreen extends StatefulWidget {
  const DeviceOwnerSetupScreen({super.key});
  @override
  State<DeviceOwnerSetupScreen> createState() =>
      _DeviceOwnerSetupScreenState();
}

class _DeviceOwnerSetupScreenState extends State<DeviceOwnerSetupScreen> {
  final _urlCtrl = TextEditingController();
  final _ssidCtrl = TextEditingController();
  final _wifiPassCtrl = TextEditingController();

  bool? _isOwner;
  bool? _isAdmin;
  String? _checksum;
  String? _qrPayload;
  bool _pinChecked = false;
  bool _removing = false;

  @override
  void initState() {
    super.initState();
    _refreshStatuses();
    WidgetsBinding.instance.addPostFrameCallback((_) => _gateWithPin());
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _ssidCtrl.dispose();
    _wifiPassCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshStatuses() async {
    final owner = await DeviceOwnerService().isDeviceOwner();
    final admin = await DeviceAdminService().isAdminActive();
    final checksum = await DeviceOwnerService().signingChecksum();
    if (!mounted) return;
    setState(() {
      _isOwner = owner;
      _isAdmin = admin;
      _checksum = checksum;
    });
  }

  /// The QR (and the removal button) are parent-only: ask for the
  /// parent code before showing anything. Wrong code / cancel =
  /// back to Settings. No hash anywhere = fail closed with a plain
  /// message (the parent PIN must exist first).
  Future<void> _gateWithPin() async {
    if (_pinChecked || !mounted) return;
    final sync = context.read<SyncService>();
    final pin = context.read<PinService>();
    final hash = await resolveParentPinHash(sync: sync, pin: pin);
    if (!mounted) return;
    if (hash == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Parent PIN is not set up yet — set the parent PIN first.',
          ),
        ),
      );
      Navigator.pop(context);
      return;
    }
    _pinChecked = true;
    await askParentPin(
      context,
      expectedHash: hash,
      onUnlocked: () {
        _pinUnlocked = true;
      },
    );
    if (!mounted) return;
    // askParentPin only calls onUnlocked on a correct PIN; a
    // cancel / wrong PIN leaves the flag false, so the screen
    // closes without showing the QR or the removal button.
    if (!_pinUnlocked) Navigator.pop(context);
  }

  bool _pinUnlocked = false;

  Future<void> _showQr() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('APK download URL is needed for the QR code.'),
        ),
      );
      return;
    }
    final checksum = _checksum ??
        await DeviceOwnerService().signingChecksum();
    if (!mounted) return;
    if (checksum == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not read this app\'s signing certificate — no QR shown.',
          ),
        ),
      );
      return;
    }
    setState(() {
      _qrPayload = DeviceOwnerService.buildQrPayload(
        downloadLocation: url,
        checksum: checksum,
        wifiSsid:
            _ssidCtrl.text.trim().isEmpty ? null : _ssidCtrl.text.trim(),
        wifiPassword: _wifiPassCtrl.text.isEmpty
            ? null
            : _wifiPassCtrl.text,
      );
    });
  }

  Future<void> _removeProtection() async {
    final sync = context.read<SyncService>();
    final pin = context.read<PinService>();
    await askParentPinForProtectionRemoval(
      context,
      sync: sync,
      pin: pin,
      onUnlocked: () async {
        if (!mounted) return;
        setState(() => _removing = true);
        final ok = await DeviceOwnerService().removeAllProtection();
        await _refreshStatuses();
        if (!mounted) return;
        setState(() => _removing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ok
                  ? 'Protection removed — the app can now be uninstalled.'
                  : 'Removal failed — check the protection status below.',
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final protected = _isOwner == true || _isAdmin == true;
    return Scaffold(
      appBar: AppBar(title: const Text('Uninstall protection')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: Icon(
              Icons.shield,
              color: _isOwner == true
                  ? Colors.green
                  : _isAdmin == true
                      ? Colors.orange
                      : Colors.grey,
            ),
            title: const Text('This phone'),
            subtitle: Text(
              _isOwner == null
                  ? '…'
                  : _isOwner!
                      ? 'Device Owner ON — cannot be uninstalled from Settings'
                      : _isAdmin == true
                          ? 'Device Admin only — uninstall needs deactivation first (+ parent alert)'
                          : 'Not protected — the app can be uninstalled freely',
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'How the strongest protection works (one time, parent only):\n'
              '1. Fill the APK link below and show the QR code.\n'
              '2. Factory-reset the child\'s phone (or use a new phone).\n'
              '3. On the welcome screen tap 6 times, then scan the QR.\n'
              '4. Android installs the app as device owner — from then on '
              'the child cannot uninstall it from Settings.\n\n'
              'Honest limits: this needs a factory reset once — it cannot '
              'be done on an already-set-up phone without one. A '
              'recovery-mode factory reset still wipes the phone; no app '
              'can stop that. The QR only works for the exact APK build '
              'at the link (the checksum is computed from the app on '
              'this phone). Protection itself needs no internet — '
              'Android enforces it on the phone, even with data off. '
              'Keep the parent PIN secret from the child — '
              'anyone who knows the code can remove the protection. If '
              'the parent forgets the PIN, only a factory reset removes it.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          TextField(
            controller: _urlCtrl,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'APK download URL (required)',
              hintText: 'https://…/app-release.apk',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ssidCtrl,
            decoration: const InputDecoration(
              labelText: 'Wi-Fi name (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _wifiPassCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Wi-Fi password (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _showQr,
            child: const Text('Show QR code'),
          ),
          if (_qrPayload != null) ...[
            const SizedBox(height: 16),
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(
                  data: _qrPayload!,
                  version: QrVersions.auto,
                  size: 280,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Scan this on the child\'s phone during setup (after the '
              'factory reset, tap 6 times on the welcome screen).',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
          const SizedBox(height: 16),
          const Divider(),
          if (protected)
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: _removing ? null : _removeProtection,
              child: Text(
                _removing
                    ? 'Removing…'
                    : 'Remove protection on this phone (parent code needed)',
              ),
            ),
          if (protected)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'The parent enters HIS code → protection is removed → '
                'only then can the app be uninstalled. The parent is '
                'never locked out: his code always works.',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ),
        ],
      ),
    );
  }
}
