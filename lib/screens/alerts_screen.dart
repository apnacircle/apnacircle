import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/alerts.dart';
import '../core/language_service.dart';
import '../l10n/strings.dart';
import '../services/family_service.dart';
import 'pin_gate_dialog.dart';

/// All 15 alerts, each with its OWN on/off switch.
/// Changing a switch requires the parent PIN — EXCEPT "SOS by
/// SMS" (v0.6.21): any member can turn that one on themselves,
/// with no PIN, so a child in trouble is never locked out of an
/// emergency alert by the admin's permission. A child cannot
/// change the other alerts from their own phone — changes are made
/// on the parent phone and sync to the member (remote control).
class AlertsScreen extends StatelessWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<LanguageService>();
    final isUrdu = lang.isUrdu;
    String t(String key) => tr(isUrdu, key);
    String tf(String key, [Map<String, Object> args = const {}]) =>
        trf(isUrdu, key, args);
    final family = context.watch<FamilyService>();
    final member = family.me;
    if (member == null) {
      return Center(child: Text(t('scr_alertsNoMembers')));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          tf('scr_alertsFor', {
            'name': member.name,
            'count': AlertType.values.length,
          }),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(t('scr_alertsIntro')),
        const SizedBox(height: 16),
        for (final type in AlertType.values)
          SwitchListTile(
            title: Text(type.label(isUrdu: isUrdu)),
            subtitle: type.hint(isUrdu: isUrdu) == null
                ? null
                : Text(type.hint(isUrdu: isUrdu)!),
            value: member.alerts[type] ?? false,
            onChanged: (value) {
              // v0.6.21: SOS by SMS is independent — no PIN, so
              // any member can activate it in an emergency.
              if (!type.needsParentPin) {
                family.setAlert(member.id, type, value);
                return;
              }
              askParentPin(
                context,
                onUnlocked: () => family.setAlert(member.id, type, value),
              );
            },
          ),
      ],
    );
  }
}
