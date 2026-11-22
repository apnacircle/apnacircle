import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/pin_service.dart';

/// Shows a PIN prompt and runs [onUnlocked] only when the PIN is
/// correct. Used by EVERY locked change: alert toggles, locks,
/// location sharing, plan changes.
Future<void> askParentPin(
  BuildContext context, {
  required VoidCallback onUnlocked,
}) async {
  final pinCtrl = TextEditingController();
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Parent PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pinCtrl,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 6,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Enter parent PIN',
                border: OutlineInputBorder(),
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (context.read<PinService>().verify(pinCtrl.text)) {
                Navigator.pop(ctx, true);
              } else {
                setState(() => error = 'Wrong PIN. Try again.');
              }
            },
            child: const Text('Unlock'),
          ),
        ],
      ),
    ),
  );
  if (ok == true) onUnlocked();
}
