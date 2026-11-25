import 'package:apnacircle/core/constants.dart';
import 'package:apnacircle/core/location_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

/// Battery drain fix (v0.6.12, 25 Nov 2026): the background task
/// ran every 60 s and took a FRESH high-accuracy GPS fix every
/// single cycle (~1,440 GPS fixes/day) — the 50 m / 60 s throttle
/// ran AFTER the fix, so it saved server writes but never saved
/// battery. A phone sitting at home all day still fired the GPS
/// radio every minute.
///
/// The fix is cheapest-first: a fresh OS-cached fix near our last
/// fix proves the phone has not moved (no radio); otherwise one
/// LOW-POWER fix (cell/WiFi) checks for movement; GPS only when
/// that check suggests movement, when there is no baseline yet, or
/// when the accurate baseline is older than 30 min. The 60 s cycle
/// and the 50 m / 60 s publish throttle are UNCHANGED — a real move
/// is still caught within ~60 s, and what the parent sees is
/// exactly what it was before. These tests pin the decision layer
/// (pure functions); the platform calls themselves are thin.
void main() {
  // 1 degree of latitude is ~111,320 m (geolocator's haversine).
  Position pos(double lat, double lon, DateTime at,
          {double accuracy = 10}) =>
      Position(
        latitude: lat,
        longitude: lon,
        timestamp: at,
        accuracy: accuracy,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );

  // Home: Lahore Gulberg-ish. 0.00009 deg lat ~= 10 m,
  // 0.0004402 ~= 49 m, 0.0004582 ~= 51 m, 0.0017966 ~= 200 m.
  const homeLat = 31.5200;
  const homeLon = 74.3500;

  group('decideFixAcquisition', () {
    final now = DateTime(2026, 11, 25, 7, 24);

    test('no last fix yet -> highFix (only GPS can set the baseline)',
        () {
      expect(
        decideFixAcquisition(
          lastKnown: pos(homeLat, homeLon, now),
          lastFix: null,
          lastHighFixAt: null,
          now: now,
        ),
        FixAcquisition.highFix,
      );
    });

    test('fresh cached fix near our last fix -> useCached (no radio)',
        () {
      expect(
        decideFixAcquisition(
          lastKnown: pos(homeLat, homeLon, now.subtract(
            const Duration(seconds: 30),
          )),
          lastFix: pos(homeLat, homeLon, now.subtract(
            const Duration(minutes: 5),
          )),
          lastHighFixAt: now.subtract(const Duration(minutes: 5)),
          now: now,
        ),
        FixAcquisition.useCached,
      );
    });

    test('fresh cached fix 200 m away -> mediumCheck (a move is never '
        'swallowed by the cache)', () {
      expect(
        decideFixAcquisition(
          lastKnown: pos(homeLat + 0.0017966, homeLon,
              now.subtract(const Duration(seconds: 30))),
          lastFix: pos(homeLat, homeLon, now.subtract(
            const Duration(minutes: 5),
          )),
          lastHighFixAt: now.subtract(const Duration(minutes: 5)),
          now: now,
        ),
        FixAcquisition.mediumCheck,
      );
    });

    test('stale cached fix (5 min old) -> mediumCheck', () {
      expect(
        decideFixAcquisition(
          lastKnown: pos(homeLat, homeLon, now.subtract(
            const Duration(minutes: 5),
          )),
          lastFix: pos(homeLat, homeLon, now.subtract(
            const Duration(minutes: 5),
          )),
          lastHighFixAt: now.subtract(const Duration(minutes: 5)),
          now: now,
        ),
        FixAcquisition.mediumCheck,
      );
    });

    test('no cached fix at all -> mediumCheck', () {
      expect(
        decideFixAcquisition(
          lastKnown: null,
          lastFix: pos(homeLat, homeLon, now.subtract(
            const Duration(minutes: 5),
          )),
          lastHighFixAt: now.subtract(const Duration(minutes: 5)),
          now: now,
        ),
        FixAcquisition.mediumCheck,
      );
    });

    test('accurate baseline 31 min old -> highFix (30-min re-baseline)',
        () {
      expect(
        decideFixAcquisition(
          lastKnown: pos(homeLat, homeLon, now.subtract(
            const Duration(seconds: 30),
          )),
          lastFix: pos(homeLat, homeLon, now.subtract(
            const Duration(minutes: 31),
          )),
          lastHighFixAt: now.subtract(const Duration(minutes: 31)),
          now: now,
        ),
        FixAcquisition.highFix,
      );
    });

    test('accurate baseline 29 min old + fresh near cache -> useCached',
        () {
      expect(
        decideFixAcquisition(
          lastKnown: pos(homeLat, homeLon, now.subtract(
            const Duration(seconds: 30),
          )),
          lastFix: pos(homeLat, homeLon, now.subtract(
            const Duration(minutes: 29),
          )),
          lastHighFixAt: now.subtract(const Duration(minutes: 29)),
          now: now,
        ),
        FixAcquisition.useCached,
      );
    });

    test('never had a high fix (lastHighFixAt null) -> highFix', () {
      expect(
        decideFixAcquisition(
          lastKnown: pos(homeLat, homeLon, now.subtract(
            const Duration(seconds: 30),
          )),
          lastFix: pos(homeLat, homeLon, now.subtract(
            const Duration(minutes: 5),
          )),
          lastHighFixAt: null,
          now: now,
        ),
        FixAcquisition.highFix,
      );
    });

    test('cache 49 m away -> useCached; 51 m away -> mediumCheck', () {
      final lastFix = pos(homeLat, homeLon, now.subtract(
        const Duration(minutes: 5),
      ));
      final recentHigh = now.subtract(const Duration(minutes: 5));
      expect(
        decideFixAcquisition(
          lastKnown: pos(homeLat + 0.0004402, homeLon,
              now.subtract(const Duration(seconds: 30))),
          lastFix: lastFix,
          lastHighFixAt: recentHigh,
          now: now,
        ),
        FixAcquisition.useCached,
      );
      expect(
        decideFixAcquisition(
          lastKnown: pos(homeLat + 0.0004582, homeLon,
              now.subtract(const Duration(seconds: 30))),
          lastFix: lastFix,
          lastHighFixAt: recentHigh,
          now: now,
        ),
        FixAcquisition.mediumCheck,
      );
    });

    test('cache exactly 2 min old -> useCached; 2 min 1 s old -> '
        'mediumCheck', () {
      final lastFix = pos(homeLat, homeLon, now.subtract(
        const Duration(minutes: 5),
      ));
      final recentHigh = now.subtract(const Duration(minutes: 5));
      expect(
        decideFixAcquisition(
          lastKnown: pos(homeLat, homeLon, now.subtract(
            const Duration(minutes: 2),
          )),
          lastFix: lastFix,
          lastHighFixAt: recentHigh,
          now: now,
        ),
        FixAcquisition.useCached,
      );
      expect(
        decideFixAcquisition(
          lastKnown: pos(homeLat, homeLon,
              now.subtract(const Duration(minutes: 2, seconds: 1))),
          lastFix: lastFix,
          lastHighFixAt: recentHigh,
          now: now,
        ),
        FixAcquisition.mediumCheck,
      );
    });
  });

  group('mediumSuggestsMovement', () {
    final lastFix = pos(homeLat, homeLon, DateTime(2026, 11, 25, 7, 24));

    test('10 m away -> false (stationary, no GPS needed)', () {
      expect(
        mediumSuggestsMovement(
          medium: pos(homeLat + 0.00009, homeLon, DateTime(2026, 11, 25, 7, 24)),
          lastFix: lastFix,
        ),
        isFalse,
      );
    });

    test('49 m away -> false (inside the 50 m publish threshold)', () {
      expect(
        mediumSuggestsMovement(
          medium: pos(homeLat + 0.0004402, homeLon, DateTime(2026, 11, 25, 7, 24)),
          lastFix: lastFix,
        ),
        isFalse,
      );
    });

    test('51 m away -> true (escalates to a GPS fix)', () {
      expect(
        mediumSuggestsMovement(
          medium: pos(homeLat + 0.0004582, homeLon, DateTime(2026, 11, 25, 7, 24)),
          lastFix: lastFix,
        ),
        isTrue,
      );
    });

    test('200 m away -> true', () {
      expect(
        mediumSuggestsMovement(
          medium: pos(homeLat + 0.0017966, homeLon, DateTime(2026, 11, 25, 7, 24)),
          lastFix: lastFix,
        ),
        isTrue,
      );
    });
  });

  group('publish rules unchanged (v0.6.12 must not move them)', () {
    test('50 m / 60 s publish throttle is exactly as before', () {
      expect(AppConstants.minMoveMeters, 50);
      expect(AppConstants.minUpdateInterval, const Duration(seconds: 60));
    });

    test('freshness windows are the documented values', () {
      expect(LocationService.lastKnownFreshWindow,
          const Duration(minutes: 2));
      expect(LocationService.highFixMaxAge, const Duration(minutes: 30));
      expect(LocationService.mediumFixTimeout, const Duration(seconds: 10));
    });

    test('a real move is caught within one 60 s cycle: a fresh cache '
        '200 m away escalates immediately, it never waits for the '
        'next cycle', () {
      final now = DateTime(2026, 11, 25, 7, 24);
      expect(
        decideFixAcquisition(
          lastKnown: pos(homeLat + 0.0017966, homeLon,
              now.subtract(const Duration(seconds: 30))),
          lastFix: pos(homeLat, homeLon, now.subtract(
            const Duration(minutes: 5),
          )),
          lastHighFixAt: now.subtract(const Duration(minutes: 5)),
          now: now,
        ),
        isNot(FixAcquisition.useCached),
      );
    });
  });
}
