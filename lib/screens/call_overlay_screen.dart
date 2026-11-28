import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/language_service.dart';
import '../l10n/strings.dart';
import '../core/viewer_position.dart';
import '../models/member.dart';

/// What the parent sees when a family member calls on a NORMAL SIM
/// call: name, number and distance in km from MY location.
///
/// Real Android path (v0.6.5): CallStateReceiver (manifest-registered,
/// so it works with the app dead) matches the number against the
/// member cache Dart keeps in SharedPreferences and shows a small
/// native overlay window OVER the call screen (CallOverlayManager).
/// That native path was never affected by the v0.6.14 bug: the cache
/// carries my REAL published location. This Flutter screen is the
/// PREVIEW of that overlay — reachable from the home screen's phone
/// button for testing without a real call — and the in-app view of a
/// call. It does NOT answer or decline the real call; those buttons
/// just close this preview.
class CallOverlayScreen extends StatelessWidget {
  final Member caller;

  /// THIS phone's live position, passed in by the caller (the home
  /// screen's foreground loop resolves it). Null = unknown — the
  /// distance shows '—', never a made-up number from a hardcoded
  /// demo point (v0.6.14: this screen used to measure every caller
  /// from hardcoded Lahore, 31.5204 / 74.3587).
  final ViewerPosition? viewerPosition;
  const CallOverlayScreen({
    super.key,
    required this.caller,
    this.viewerPosition,
  });

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<LanguageService>();
    String t(String key) => tr(lang.isUrdu, key);
    String tf(String key, [Map<String, Object> args = const {}]) =>
        trf(lang.isUrdu, key, args);
    final distance = caller.hasLocation
        ? formatMemberDistance(viewer: viewerPosition, member: caller)
        : t('scr_callOverlayLocationUnknown');
    return Scaffold(
      appBar: AppBar(title: Text(t('incomingCallSim'))),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 40,
              child: Text(caller.name[0], style: const TextStyle(fontSize: 32)),
            ),
            const SizedBox(height: 16),
            Text(caller.name, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            Text(caller.phone, style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 24),
            Text(t('callerDistance'), style: const TextStyle(fontSize: 16)),
            Text(
              distance,
              style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              caller.isOnline
                  ? t('scr_callOverlayLive')
                  : tf('scr_callOverlayLastLocation',
                      {'time': caller.lastSeen.toString()}),
              style: const TextStyle(fontSize: 15),
            ),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.call),
                    label: Text(t('scr_callOverlayAnswer')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.call_end),
                    label: Text(t('scr_callDecline')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
