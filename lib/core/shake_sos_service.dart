import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Shake phone for SOS (AlertType.shakeSos).
/// Fires [onShake] when the accelerometer sees a strong shake.
/// The alert itself must be ON (parent PIN) — this class only
/// detects the gesture; AlertsScreen owns the on/off state.
class ShakeSosService {
  StreamSubscription<AccelerometerEvent>? _sub;
  DateTime _lastFired = DateTime.fromMillisecondsSinceEpoch(0);

  void start({required VoidCallback onShake}) {
    _sub ??= accelerometerEventStream().listen((e) {
      final g = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
      final now = DateTime.now();
      if (g > 28 && now.difference(_lastFired).inSeconds > 5) {
        _lastFired = now;
        onShake();
      }
    });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }
}
