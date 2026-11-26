import 'dart:io';
import 'dart:typed_data';

import 'package:apnacircle/core/alert_notification.dart';
import 'package:flutter_test/flutter_test.dart';

/// SOS alert rings longer + louder (v0.6.17).
///
/// User-reported 26 Nov 2026: the SOS alert was "bohat chhota" —
/// the phone played the short default system ding (~1 s) and
/// nobody could tell an alert had arrived. Fix: a custom
/// 3-second hi-lo siren (`res/raw/sos_alert.wav`) as the channel
/// sound + a 3-second vibration pattern, on a FRESH channel id.
///
/// The fresh id is the whole point: Android NEVER updates an
/// existing channel's sound or vibration, so keeping
/// `apnacircle_alerts` would have left the old ding in place
/// forever, no matter what the code says. The old channel is
/// deleted at startup.
void main() {
  group('alert channel (v0.6.17) — fresh id for the new sound', () {
    test('channel id is the v2 id, legacy id is different', () {
      expect(AlertNotifications.channelId, 'apnacircle_alerts_v2');
      expect(AlertNotifications.legacyChannelId, 'apnacircle_alerts');
      expect(
        AlertNotifications.channelId,
        isNot(AlertNotifications.legacyChannelId),
      );
    });

    test('manifest FCM default channel points at the v2 id', () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(
        manifest,
        contains('apnacircle_alerts_v2'),
      );
      expect(
        manifest,
        contains('default_notification_channel_id'),
      );
    });
  });

  group('siren + vibration (v0.6.17) — at least 2.5 seconds', () {
    test('sound resource name is sos_alert', () {
      expect(AlertNotifications.alertSoundName, 'sos_alert');
    });

    test('vibration pattern totals 3 seconds, no initial delay', () {
      const pattern = AlertNotifications.alertVibrationPatternMs;
      expect(pattern.first, 0);
      expect(pattern.length % 2, 0);
      expect(AlertNotifications.alertVibrationTotalMs, 3000);
      expect(AlertNotifications.alertVibrationTotalMs, greaterThanOrEqualTo(2500));
    });

    test('siren file exists and rings at least 2.5 seconds', () {
      final file = File(
        'android/app/src/main/res/raw/sos_alert.wav',
      );
      expect(file.existsSync(), isTrue);
      final durationMs = _wavDurationMs(file.readAsBytesSync());
      expect(durationMs, greaterThanOrEqualTo(2500));
    });
  });
}

/// Duration of a PCM WAV file in milliseconds, parsed from its
/// 44-byte header (no audio libraries needed).
int _wavDurationMs(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final sampleRate = data.getUint32(24, Endian.little);
  final channels = data.getUint16(22, Endian.little);
  final bitsPerSample = data.getUint16(34, Endian.little);
  final dataSize = data.getUint32(40, Endian.little);
  final bytesPerSecond =
      sampleRate * channels * (bitsPerSample ~/ 8);
  return (dataSize * 1000) ~/ bytesPerSecond;
}
