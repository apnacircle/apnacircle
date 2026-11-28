import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/language_service.dart';
import '../core/location_service.dart';
import '../l10n/strings.dart';

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
    // v0.6.32: nullable watch — unit tests pump this card bare
    // (no LanguageService); it then falls back to English.
    final lang = context.watch<LanguageService?>();
    final isUrdu = lang?.isUrdu ?? false;
    String t(String key) => tr(isUrdu, key);
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
                        ? t('scr_locChecking')
                        : isAlways
                            ? t('scr_locOnAlways')
                            : isWhileInUse
                                ? t('scr_locWhileInUse')
                                : t('scr_locOff'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: t('scr_lockCheckAgain'),
                  onPressed: onRefresh,
                ),
              ],
            ),
            Text(
              s == null
                  ? ''
                  : isAlways
                      ? serviceRunning
                          ? t('scr_locFamilySees')
                          : t('scr_locServiceNotRunning')
                      : locationLocked
                          ? t('scr_locLockedByParent')
                          : isWhileInUse
                              ? t('scr_locOnlyWhileOpen')
                              : t('scr_locCannotSee'),
            ),
            if (s != null && !isAlways) ...[
              const SizedBox(height: 8),
              FilledButton(
                onPressed: onFix,
                child: Text(t('scr_locTurnOnAlways')),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              t('scr_lockEveryChild'),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
