import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/language_service.dart';
import '../services/auth_service.dart';
import '../services/family_service.dart';
import '../services/firebase_bootstrap.dart';
import '../services/sms_location_service.dart';
import 'auth_screen.dart';
import 'circle_screen.dart';

/// Settings: language, member count (max 10), lite mode.
/// Account delete (required by Play Store) is a v0.2 Firebase step.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _smsEnabledKey = 'sms_fallback_enabled';
  bool _smsOn = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() => _smsOn = prefs.getBool(_smsEnabledKey) ?? false);
      }
    });
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

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<LanguageService>();
    final family = context.watch<FamilyService>();
    final auth = context.watch<AuthService>();
    final live = FirebaseBootstrap.available && auth.signedIn;
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
