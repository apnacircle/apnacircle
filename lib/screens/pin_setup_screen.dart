import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/pin_service.dart';
import '../services/sync_service.dart';

/// Parent sets their PIN on first run. No default PIN in the real
/// app (the web demo used 1234 — that must NOT ship here).
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key});
  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_pin.text.length < 4) {
      setState(() => _error = 'PIN must be at least 4 digits.');
      return;
    }
    if (_pin.text != _confirm.text) {
      setState(() => _error = 'PINs do not match.');
      return;
    }
    final pinService = context.read<PinService>();
    await pinService.setPin(_pin.text);
    // v0.3: store the PIN hash on the active circle (parent only)
    // so the same PIN is recovered when the parent signs in on a
    // NEW phone. The hash is SHA-256 — never the PIN itself.
    if (mounted) {
      final sync = context.read<SyncService>();
      final circle = sync.activeCircle;
      if (sync.isAvailable &&
          circle != null &&
          circle.isAdmin &&
          pinService.pinHash != null) {
        await sync.publishPinHash(circle.id, pinService.pinHash!);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set parent PIN')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Only the parent knows this PIN. It locks alerts, '
              'location lock and app lock.',
              style: TextStyle(fontSize: 17),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _pin,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'Parent PIN',
                border: OutlineInputBorder(),
              ),
            ),
            TextField(
              controller: _confirm,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'Confirm PIN',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: const Text('Save PIN')),
          ],
        ),
      ),
    );
  }
}
