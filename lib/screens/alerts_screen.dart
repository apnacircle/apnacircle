import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/alerts.dart';
import '../services/family_service.dart';
import 'pin_gate_dialog.dart';

/// All 15 alerts, each with its OWN on/off switch.
/// Changing ANY switch requires the parent PIN. A child cannot
/// change alerts from their own phone — changes are made on the
/// parent phone and sync to the member (remote control).
class AlertsScreen extends StatelessWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final family = context.watch<FamilyService>();
    final member = family.me;
    if (member == null) {
      return const Center(child: Text('No family members yet.'));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Alerts for ${member.name} — ${AlertType.values.length} alerts',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Each alert has its own switch. Changing a switch needs the parent PIN.',
        ),
        const SizedBox(height: 16),
        for (final type in AlertType.values)
          SwitchListTile(
            title: Text(type.labelEn),
            subtitle:
                type.hintEn == null ? null : Text(type.hintEn!),
            value: member.alerts[type] ?? false,
            onChanged: (value) {
              askParentPin(
                context,
                onUnlocked: () =>
                    family.setAlert(member.id, type, value),
              );
            },
          ),
      ],
    );
  }
}
