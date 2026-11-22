import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/language_service.dart';
import '../services/family_service.dart';

/// Settings: language, member count (max 10), lite mode.
/// Account delete (required by Play Store) is a v0.2 Firebase step.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<LanguageService>();
    final family = context.watch<FamilyService>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
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
