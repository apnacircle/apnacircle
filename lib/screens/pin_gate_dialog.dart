import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/escape_gate.dart';
import '../core/language_service.dart';
import '../l10n/strings.dart';
import '../services/pin_service.dart';
import '../services/sync_service.dart';

/// Shows a PIN prompt and runs [onUnlocked] only when the PIN is
/// correct. Used by EVERY locked change: alert toggles, locks,
/// location sharing, plan changes.
///
/// [expectedHash]: when given, the entered PIN is verified against
/// THIS hash (SHA-256 of "apnacircle:<pin>") instead of the PIN
/// stored on this phone. That is how a child's phone verifies the
/// parent's code for the escape hatches (v0.6.13, part E): the
/// child's phone has no local PIN, so it verifies against the
/// circle's stored parent PIN hash.
Future<void> askParentPin(
  BuildContext context, {
  required VoidCallback onUnlocked,
  String? expectedHash,
}) async {
  final isUrdu = context.read<LanguageService>().isUrdu;
  String t(String key) => tr(isUrdu, key);
  final pinCtrl = TextEditingController();
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(t('scr_pinGateTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pinCtrl,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 6,
              autofocus: true,
              decoration: InputDecoration(
                labelText: t('scr_pinGateEnter'),
                border: const OutlineInputBorder(),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('cancel')),
          ),
          FilledButton(
            onPressed: () {
              final correct = expectedHash != null
                  ? verifyPinAgainstHash(pinCtrl.text, expectedHash)
                  : context.read<PinService>().verify(pinCtrl.text);
              if (correct) {
                Navigator.pop(ctx, true);
              } else {
                setState(() => error = t('pinWrong'));
              }
            },
            child: Text(t('scr_pinGateUnlock')),
          ),
        ],
      ),
    ),
  );
  if (ok == true) onUnlocked();
}

/// Ask for the parent PIN before removing uninstall protection
/// (v0.6.13, both directions of the user's order).
///
/// The gate is the PARENT CODE, not the role: the parent holding
/// the child's phone enters HIS code (verified against the
/// circle's stored parent PIN hash when this phone has no local
/// PIN), and the parent on their own phone enters the same code
/// (verified against the local hash). A child without the code
/// can never get through. When NO parent PIN hash can be found at
/// all (never set, or offline with nothing stored), the removal
/// is BLOCKED — fail closed — with a plain message, never let
/// through unverified.
Future<void> askParentPinForProtectionRemoval(
  BuildContext context, {
  required SyncService sync,
  required PinService pin,
  required VoidCallback onUnlocked,
}) async {
  final isUrdu = context.read<LanguageService>().isUrdu;
  String t(String key) => tr(isUrdu, key);
  final hash = await resolveParentPinHash(sync: sync, pin: pin);
  if (!context.mounted) return;
  if (hash == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(t('scr_pinGateNotFound')),
      ),
    );
    return;
  }
  await askParentPin(context, expectedHash: hash, onUnlocked: onUnlocked);
}
