import 'package:flutter/material.dart';

import '../core/location_service.dart';

/// Location sharing status card (v0.6.4) — same pattern as the
/// v0.6.3 App Lock card in LocksScreen: show the real state on
/// THIS phone, in plain words, with a button that opens the fix
/// flow. Before this card existed, nobody could tell why a member
/// stopped updating — the app had only ever asked for while-in-use
/// location and fetched it only while the Map screen was open.
///
/// Pure UI: the state and callbacks come from the caller, so this
/// widget is unit-testable without any permission or service.
class LocationStatusCard extends StatelessWidget {
  const LocationStatusCard({
    super.key,
    required this.state,
    required this.serviceRunning,
    this.locationLocked = false,
    required this.onFix,
    required this.onRefresh,
  });

  /// The sharing state on this phone (null = still checking).
  final LocationSharingState? state;

  /// Whether the background location service is running.
  final bool serviceRunning;

  /// v0.6.9: the parent's Location Lock for THIS member. When it is
  /// on and sharing is not "always", the card says the parent
  /// locked it — so the child sees they must turn sharing back on.
  /// There is no in-app off-switch to disable (sharing is governed
  /// by the OS permission); the lock's enforcement is this prompt
  /// plus the locationOff parent alert the background service
  /// already sends when sharing goes off.
  final bool locationLocked;

  /// Runs the fix flow (rationale -> Settings -> "Allow all the
  /// time"), owned by HomeMapScreen.
  final VoidCallback onFix;

  /// Re-checks the state now.
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final isAlways = s == LocationSharingState.always;
    final isWhileInUse = s == LocationSharingState.whileInUse;
    final color = s == null
        ? null
        : isAlways
            ? Colors.green.shade50
            : isWhileInUse
                ? Colors.amber.shade50
                : Colors.red.shade50;
    return Card(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  s == null
                      ? Icons.help_outline
                      : isAlways
                          ? Icons.check_circle
                          : isWhileInUse
                              ? Icons.warning_amber
                              : Icons.location_off,
                  color: s == null
                      ? Colors.grey
                      : isAlways
                          ? Colors.green
                          : isWhileInUse
                              ? Colors.amber.shade800
                              : Colors.red,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s == null
                        ? 'Checking location sharing…'
                        : isAlways
                            ? 'Location sharing ON (always)'
                            : isWhileInUse
                                ? 'Location sharing: only while using the app'
                                : 'Location sharing OFF',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Check again',
                  onPressed: onRefresh,
                ),
              ],
            ),
            Text(
              s == null
                  ? ''
                  : isAlways
                      ? serviceRunning
                          ? 'Your family can see you even when the app is closed.'
                          : 'Permission is "always", but the background service is not running — tap Refresh.'
                      : locationLocked
                          ? 'Location is locked by your parent — turn sharing back on.'
                          : isWhileInUse
                              ? 'Your family can see you ONLY while ApnaCircle is open on this phone. Turn on "Allow all the time" to keep sharing when the app is closed.'
                              : 'Your family cannot see your location at all. Turn location sharing on.',
            ),
            if (s != null && !isAlways) ...[
              const SizedBox(height: 8),
              FilledButton(
                onPressed: onFix,
                child: const Text('Turn on always'),
              ),
            ],
            const SizedBox(height: 4),
            const Text(
              'Every child\'s phone needs "Allow all the time" — it can only be turned on from that phone itself, never from the parent phone.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
