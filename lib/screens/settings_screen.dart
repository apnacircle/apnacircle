import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/call_distance_service.dart';
import '../core/escape_gate.dart';
import '../core/language_service.dart';
import '../l10n/strings.dart';
import '../services/auth_service.dart';
import '../services/device_admin_service.dart';
import '../services/device_owner_service.dart';
import '../services/family_service.dart';
import '../services/firebase_bootstrap.dart';
import '../services/pin_service.dart';
import '../services/sim_change_service.dart';
import '../services/sms_location_service.dart';
import '../services/sync_service.dart';
import 'auth_screen.dart';
import 'circle_screen.dart';
import 'device_owner_setup_screen.dart';
import 'pin_gate_dialog.dart';

/// Settings: language, member count (max 10), lite mode.
///
/// v0.5 additions: Device Admin (uninstall protection), SIM-change
/// alert status, SIM-call permissions, and account delete (Play
/// Store requirement — Settings → Delete account).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  static const _smsEnabledKey = 'sms_fallback_enabled';
  bool _smsOn = false;

  // v0.5 statuses (null = still loading).
  bool? _adminActive;
  // v0.6.13: device-owner status (null = still loading).
  bool? _isOwner;
  bool? _simReadable;
  bool? _callLogGranted;
  // v0.6.5: call distance overlay statuses (null = still loading).
  bool? _overlayGranted;
  bool? _outgoingGranted;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() => _smsOn = prefs.getBool(_smsEnabledKey) ?? false);
      }
    });
    _refreshProtectionStatuses();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from Android's system screens (Device Admin,
    // permission dialogs) — re-read the real statuses.
    if (state == AppLifecycleState.resumed) _refreshProtectionStatuses();
  }

  Future<void> _refreshProtectionStatuses() async {
    final admin = await DeviceAdminService().isAdminActive();
    final owner = await DeviceOwnerService().isDeviceOwner();
    final simHash = await SimChangeService().currentHash();
    final callLog = await CallDistanceService.hasCallLogPermission();
    final overlay = await CallDistanceService.canDrawOverlays();
    final outgoing = await CallDistanceService.hasOutgoingCallPermission();
    // v0.6.13: keep the cached protection level fresh for the
    // background task, which publishes it with the member node.
    await DeviceOwnerService().cacheLevel();
    if (!mounted) return;
    setState(() {
      _adminActive = admin;
      _isOwner = owner;
      _simReadable = simHash != null;
      _callLogGranted = callLog;
      _overlayGranted = overlay;
      _outgoingGranted = outgoing;
    });
  }

  /// Remove ALL uninstall protection from this phone (v0.6.13,
  /// both directions of the user's order): the parent enters HIS
  /// code — the same parent PIN that unlocks apps — and Device
  /// Owner (if any) + Device Admin (if any) come off, so the app
  /// can then be uninstalled. A child without the code can never
  /// get through; the parent is never locked out, on this phone
  /// or on the child's phone.
  Future<void> _removeProtection() async {
    final sync = context.read<SyncService>();
    final pin = context.read<PinService>();
    await askParentPinForProtectionRemoval(
      context,
      sync: sync,
      pin: pin,
      onUnlocked: () async {
        final ok = await DeviceOwnerService().removeAllProtection();
        await _refreshProtectionStatuses();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ok
                  ? 'Protection removed — the app can now be uninstalled.'
                  : 'Removal failed — check the protection status above.',
            ),
          ),
        );
      },
    );
  }

  Future<void> _toggleSms(bool value) async {
    if (value) {
      // Plain explanation FIRST, then the OS permission dialog.
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('SMS location when offline?'),
          content: const Text(
            'When this phone has no internet (no Wi-Fi, no mobile '
            'data), ApnaCircle sends its GPS location to the PARENT\'s '
            'number by SMS — at most once every 15 minutes, only '
            'when moved. SMS needs mobile signal and uses SMS '
            'balance. SMS is never sent to anyone except the parent.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Turn on'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      if (!mounted) return;
      final granted = await context
          .read<SmsLocationService>()
          .ensureSmsPermission();
      if (!mounted) return;
      if (!granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('SMS permission was not given.'),
          ),
        );
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_smsEnabledKey, true);
      setState(() => _smsOn = true);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_smsEnabledKey, false);
    setState(() => _smsOn = false);
  }

  /// SIM-call permissions: plain explanation FIRST, then the
  /// Android permission dialog. Never request silently.
  Future<void> _requestCallPermissions() async {
    final lang = context.read<LanguageService>();
    String t(String key) => tr(lang.isUrdu, key);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('callPermissions')),
        content: Text(t('callPermissionsWhy')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('allowPermissions')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final granted = await CallDistanceService.requestCallPermissions();
    if (!mounted) return;
    if (granted['callLog'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('callPermissionsOff'))),
      );
    }
    await _refreshProtectionStatuses();
  }

  /// Call distance overlay (v0.6.5): plain explanation FIRST, then
  /// Android's "Display over other apps" page. Only the user's own
  /// tap there can grant it — no app can grant it itself. Without
  /// it, no distance can appear over a call screen.
  Future<void> _requestOverlayPermission() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Show distance during calls?'),
        content: const Text(
          'When a family member calls on a normal SIM call — or you '
          'call them — ApnaCircle shows their name and distance on '
          'top of the call screen. For that, Android needs "Display '
          'over other apps" turned on for ApnaCircle. The overlay '
          'only ever appears for family members, never for strangers.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await CallDistanceService.openOverlaySettings();
    // The system page opens; status refreshes when the user comes
    // back (lifecycle observer).
  }

  /// Account delete (Play Store requirement). Order: remove my
  /// RTDB data first, then delete the Auth account, then clear
  /// local data — EXCEPT the per-device trial cache, so a deleted
  /// account cannot restart the free trial in demo mode.
  Future<void> _deleteAccount() async {
    final lang = context.read<LanguageService>();
    String t(String key) => tr(lang.isUrdu, key);
    final auth = context.read<AuthService>();
    final sync = context.read<SyncService>();
    // Escape-hatch gate (v0.6.13, part E — same as CircleScreen):
    // a CHILD deleting their account must first enter the parent
    // PIN (the SAME parent PIN that unlocks apps). Parent role:
    // never gated. No hash anywhere = fail closed.
    if (childEscapeNeedsParentPin(sync.activeCircle?.role)) {
      final hash = await resolveParentPinHash(
        sync: sync,
        pin: context.read<PinService>(),
      );
      if (!mounted) return;
      if (hash == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Parent PIN is needed for this — connect to the internet and try again.',
            ),
          ),
        );
        return;
      }
      var passed = false;
      await askParentPin(
        context,
        expectedHash: hash,
        onUnlocked: () => passed = true,
      );
      if (!mounted) return;
      if (!passed) return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('deleteAccount')),
        content: Text(
          '${t('deleteAccountConfirm')}\n\n${t('deleteAccountNote')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('delete')),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _deleting = true);
    if (sync.isAvailable) await sync.deleteMyAccountData();
    final err = await auth.deleteAccount();
    if (!mounted) return;
    if (err == null) {
      final prefs = await SharedPreferences.getInstance();
      final trialCache = <String, String>{};
      for (final key in prefs.getKeys()) {
        if (key.startsWith('trial_state_v1')) {
          final value = prefs.getString(key);
          if (value != null) trialCache[key] = value;
        }
      }
      await prefs.clear();
      for (final e in trialCache.entries) {
        await prefs.setString(e.key, e.value);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('deleteAccountDone'))),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            err == 'Sign in again first, then delete the account.'
                ? t('signInAgainFirst')
                : t('deleteAccountFailed'),
          ),
        ),
      );
    }
    setState(() => _deleting = false);
  }

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<LanguageService>();
    final family = context.watch<FamilyService>();
    final auth = context.watch<AuthService>();
    final live = FirebaseBootstrap.available && auth.signedIn;
    String t(String key) => tr(lang.isUrdu, key);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          leading: const Icon(Icons.account_circle),
          title: const Text('Account & Circles'),
          subtitle: Text(
            live
                ? 'Signed in as ${auth.email ?? auth.phoneNumber ?? ''} · Live sync ON'
                : 'Not signed in — demo mode (this phone only)',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CircleScreen()),
          ),
        ),
        if (!live)
          ListTile(
            title: const Text('Sign in to sync across phones'),
            subtitle: const Text(
              'Parent on one phone, child on another — needs an account.',
            ),
            trailing: FilledButton.tonal(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AuthScreen()),
              ),
              child: const Text('Sign in'),
            ),
          ),
        SwitchListTile(
          title: const Text('SMS location when offline'),
          subtitle: const Text(
            'No internet? Send GPS location to the parent by SMS '
            '(every 15 min, only when moved). Needs SMS permission.',
          ),
          value: _smsOn,
          onChanged: _toggleSms,
        ),
        ListTile(
          title: const Text('Language / زبان'),
          subtitle: Text(lang.isUrdu ? 'اردو' : 'English'),
          trailing: FilledButton.tonal(
            onPressed: () => lang.toggle(),
            child: Text(lang.isUrdu ? 'English' : 'اردو'),
          ),
        ),
        ListTile(
          title: const Text('Family members'),
          subtitle: Text(
            '${family.memberCount} / 10 — works on old and new Android phones',
          ),
        ),
        const ListTile(
          title: Text('Lite mode'),
          subtitle: Text(
            'Low battery and low data use: location updates only when moving.',
          ),
          trailing: Icon(Icons.battery_saver),
        ),
        const Divider(),
        // --- v0.5: protection ---
        ListTile(
          leading: Icon(
            Icons.shield,
            color: _adminActive == true ? Colors.green : Colors.grey,
          ),
          title: Text(t('deviceAdmin')),
          subtitle: Text(
            _adminActive == null
                ? '…'
                : _adminActive!
                    ? t('deviceAdminOn')
                    : t('deviceAdminOff'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            t('deviceAdminNote'),
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: _adminActive == true
              // v0.6.13: removing protection is PIN-gated for
              // EVERYONE — the parent enters HIS code (the same
              // parent PIN that unlocks apps) and the protection
              // comes off; a child without the code can never get
              // through, and the parent is never locked out.
              ? OutlinedButton(
                  onPressed: _removeProtection,
                  child: const Text('Remove protection (parent code needed)'),
                )
              : FilledButton(
                  onPressed: () async {
                    await DeviceAdminService().requestAdmin();
                    // The system screen opens; status refreshes
                    // when the user comes back (lifecycle observer).
                  },
                  child: Text(t('enableProtection')),
                ),
        ),
        // v0.6.13: Device Owner — the only truly non-uninstallable
        // protection (one-time QR setup on a fresh / factory-reset
        // phone). The setup screen is PIN-gated too.
        ListTile(
          leading: Icon(
            Icons.verified_user,
            color: _isOwner == true
                ? Colors.green
                : _adminActive == true
                    ? Colors.orange
                    : Colors.grey,
          ),
          title: const Text('Uninstall protection (Device Owner)'),
          subtitle: Text(
            _isOwner == null
                ? '…'
                : _isOwner!
                    ? 'Device Owner ON — cannot be uninstalled from Settings'
                    : _adminActive == true
                        ? 'Device Admin only — tap to set up the stronger protection'
                        : 'Not protected — tap to set up uninstall protection',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const DeviceOwnerSetupScreen(),
              ),
            );
            await _refreshProtectionStatuses();
          },
        ),
        ListTile(
          leading: Icon(
            Icons.sim_card,
            color: _simReadable == true ? Colors.green : Colors.grey,
          ),
          title: Text(t('simCheck')),
          subtitle: Text(
            _simReadable == null
                ? '…'
                : _simReadable!
                    ? t('simCheckOn')
                    : t('simCheckOff'),
          ),
        ),
        ListTile(
          leading: Icon(
            Icons.phone_in_talk,
            color: _callLogGranted == true ? Colors.green : Colors.grey,
          ),
          title: Text(t('callPermissions')),
          subtitle: Text(
            _callLogGranted == null
                ? '…'
                : _callLogGranted!
                    ? t('callPermissionsOn')
                    : t('callPermissionsOff'),
          ),
          trailing: _callLogGranted == true
              ? null
              : FilledButton.tonal(
                  onPressed: _requestCallPermissions,
                  child: Text(t('allowPermissions')),
                ),
        ),
        // v0.6.5: call distance overlay — shows name + distance on
        // top of the SIM call screen, for family members only.
        ListTile(
          leading: Icon(
            Icons.picture_in_picture_alt,
            color: _overlayGranted == true ? Colors.green : Colors.grey,
          ),
          title: const Text('Call distance overlay'),
          subtitle: Text(
            _overlayGranted == null
                ? '…'
                : _overlayGranted!
                    ? 'ON — distance shows on top of SIM calls'
                    : 'OFF — no distance can appear during a call',
          ),
          trailing: _overlayGranted == true
              ? null
              : FilledButton.tonal(
                  onPressed: _requestOverlayPermission,
                  child: const Text('Allow'),
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            _outgoingGranted == true
                ? 'Incoming + outgoing calls: distance shows for family members only. Tap the card to dismiss it; it hides when the call ends.'
                : 'Incoming calls need Phone + Call Log (above); outgoing calls also need the outgoing-call permission, granted together with them. Without "Display over other apps" above, nothing appears during a call.',
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ),
        const Divider(),
        if (live)
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: Text(
              t('deleteAccount'),
              style: const TextStyle(color: Colors.red),
            ),
            subtitle: Text(t('deleteAccountNote')),
            trailing: _deleting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _deleting ? null : _deleteAccount,
          ),
        const ListTile(
          title: Text('About ApnaCircle'),
          subtitle: Text(
            'Family location safety. No ads. Location data is never sold.',
          ),
        ),
      ],
    );
  }
}
