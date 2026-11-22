import 'package:flutter/material.dart';

import '../core/call_distance_service.dart';
import '../core/location_service.dart';
import '../models/member.dart';

/// What the parent sees when a family member calls on a NORMAL SIM
/// call: name, number and distance in km from MY location.
///
/// Real Android path: MainActivity detects the incoming call, looks
/// the number up in the family circle, and shows this screen as a
/// full-screen intent / overlay (SYSTEM_ALERT_WINDOW permission).
/// This screen is also reachable from the home screen's phone button
/// for testing without a real call.
class CallOverlayScreen extends StatelessWidget {
  final Member caller;
  const CallOverlayScreen({super.key, required this.caller});

  // My location — in production this comes from LocationService.
  static const double myLat = 31.5204;
  static const double myLon = 74.3587;

  @override
  Widget build(BuildContext context) {
    final distance = caller.hasLocation
        ? CallDistanceService.formatKm(
            LocationService.distanceKm(myLat, myLon, caller.lat!, caller.lon!),
          )
        : 'Location unknown';
    return Scaffold(
      appBar: AppBar(title: const Text('Incoming call · SIM')),
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
            const Text('Caller distance from you', style: TextStyle(fontSize: 16)),
            Text(
              distance,
              style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              caller.isOnline
                  ? 'Live location'
                  : 'Last location: ${caller.lastSeen}',
              style: const TextStyle(fontSize: 15),
            ),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.call),
                    label: const Text('Answer'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.call_end),
                    label: const Text('Decline'),
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
