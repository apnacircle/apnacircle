import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/setup_service.dart';

/// Guided first-run setup (v0.6.19) — the answer to "parents
/// cannot be expected to find every permission in Settings".
///
/// One screen, one step per permission. Each step has ONE big
/// button that opens exactly the right settings page (or the
/// system dialog); coming back, the step shows a green tick when
/// it is really granted. Nothing needs to be understood — the
/// parent just taps the buttons top to bottom.
///
/// Honest limit, shown on the screen itself: Android does not let
/// any app turn these on by itself — every step still needs one
/// tap from the phone's owner. What this screen removes is the
/// hunting: no more "where in Settings is that?".
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> with WidgetsBindingObserver {
  /// null = still checking, true/false = live status on this phone.
  final Map<SetupStep, bool?> _done = {
    for (final s in SetupStep.values) s: null,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_checkAll());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from a settings page — re-check everything,
    // so the tick appears without the user tapping anything.
    if (state == AppLifecycleState.resumed) unawaited(_checkAll());
  }

  Future<void> _checkAll() async {
    for (final step in SetupStep.values) {
      final done = await isSetupStepDone(step);
      if (!mounted) return;
      setState(() => _done[step] = done);
    }
  }

  Future<void> _runStep(SetupStep step) async {
    await runSetupStepAction(context, step);
    // The action may have opened Settings — re-check when we get
    // back (didChangeAppLifecycleState), and also right now, so
    // a dialog grant ticks immediately.
    final done = await isSetupStepDone(step);
    if (!mounted) return;
    setState(() => _done[step] = done);
  }

  Future<void> _finish() async {
    await context.read<SetupService>().markComplete();
    if (!mounted) return;
    // Pushed from Settings: go back there. Shown as the app's
    // first screen (AppRoot): nothing to pop, and marking complete
    // rebuilds AppRoot onto the map.
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final doneCount = _done.values.where((done) => done == true).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Setup — ApnaCircle')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'One-time setup — tap each button, allow it, come back.',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            'Android does not let any app turn these on by itself — '
            'each one needs one tap from you. This screen opens the '
            'right page for each, so you never have to hunt through '
            'Settings. A green tick means it is done.',
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: doneCount / SetupStep.values.length,
          ),
          const SizedBox(height: 4),
          Text('$doneCount of ${SetupStep.values.length} done'),
          const SizedBox(height: 12),
          for (final step in SetupStep.values) _stepCard(step),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _finish,
            child: const Text('Done — go to the map'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _finish,
            child: const Text('Skip for now'),
          ),
          const SizedBox(height: 8),
          const Text(
            'You can come back anytime: Settings → "Setup — permissions".',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _stepCard(SetupStep step) {
    final done = _done[step];
    final index = SetupStep.values.indexOf(step) + 1;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              done == true ? Icons.check_circle : Icons.circle_outlined,
              color: done == true ? Colors.green : Colors.grey,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$index. ${step.title}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    step.isRequired ? 'Required' : 'Recommended',
                    style: TextStyle(
                      color: step.isRequired ? Colors.red : Colors.grey,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(step.why),
                  const SizedBox(height: 8),
                  if (done != true) ...[
                    FilledButton.tonal(
                      onPressed: () => _runStep(step),
                      child: Text(step.actionLabel),
                    ),
                    if (step == SetupStep.battery) ...[
                      // v0.6.22: the exemption dialog never comes
                      // back on Oppo/ColorOS after one denial, so
                      // "Allow" alone can be a dead button. The
                      // manual route is always visible next to it:
                      // it opens the App info page, where Battery
                      // → "Unrestricted" lives.
                      const SizedBox(height: 8),
                      FilledButton.tonal(
                        onPressed: () async {
                          await openBatterySettings();
                          if (!mounted) return;
                          final d = await isSetupStepDone(step);
                          if (!mounted) return;
                          setState(() => _done[step] = d);
                        },
                        child: const Text('Open battery settings'),
                      ),
                    ],
                  ] else
                    const Text(
                      'Done ✓',
                      style: TextStyle(color: Colors.green),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
