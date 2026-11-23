import 'package:apnacircle/core/location_service.dart';
import 'package:apnacircle/screens/location_status_card.dart';
import 'package:apnacircle/services/background_location_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

/// Background location (v0.6.4): before this version the app only
/// ever asked for while-in-use location and only fetched it while
/// the Map screen was open — members went stale/offline the moment
/// the app went to background. These tests pin the new contract:
/// permission -> sharing state mapping, the start/stop decision,
/// the location-off alert firing exactly once per switch-off, and
/// the status card showing the right words for each state.
void main() {
  group('locationStateFromPermission', () {
    test('always -> always', () {
      expect(locationStateFromPermission(LocationPermission.always),
          LocationSharingState.always);
    });

    test('whileInUse -> whileInUse', () {
      expect(locationStateFromPermission(LocationPermission.whileInUse),
          LocationSharingState.whileInUse);
    });

    test('denied -> off', () {
      expect(locationStateFromPermission(LocationPermission.denied),
          LocationSharingState.off);
    });

    test('deniedForever -> off', () {
      expect(
          locationStateFromPermission(LocationPermission.deniedForever),
          LocationSharingState.off);
    });

    test('unableToDetermine -> off', () {
      expect(
          locationStateFromPermission(
              LocationPermission.unableToDetermine),
          LocationSharingState.off);
    });
  });

  group('BackgroundLocationService.shouldRunBackgroundSharing', () {
    test('in a circle + always -> runs', () {
      expect(
          BackgroundLocationService.shouldRunBackgroundSharing(
            inCircle: true,
            state: LocationSharingState.always,
          ),
          isTrue);
    });

    test('in a circle + whileInUse -> does NOT run', () {
      expect(
          BackgroundLocationService.shouldRunBackgroundSharing(
            inCircle: true,
            state: LocationSharingState.whileInUse,
          ),
          isFalse);
    });

    test('in a circle + off -> does NOT run', () {
      expect(
          BackgroundLocationService.shouldRunBackgroundSharing(
            inCircle: true,
            state: LocationSharingState.off,
          ),
          isFalse);
    });

    test('no circle + always -> does NOT run', () {
      expect(
          BackgroundLocationService.shouldRunBackgroundSharing(
            inCircle: false,
            state: LocationSharingState.always,
          ),
          isFalse);
    });
  });

  group('BackgroundLocationService constants', () {
    test('the notification tells the truth about what is shared', () {
      expect(BackgroundLocationService.notificationText,
          'ApnaCircle is sharing your location with your family');
      expect(BackgroundLocationService.notificationTitle, 'ApnaCircle');
      expect(BackgroundLocationService.channelId, 'apnacircle_location');
    });

    test('task data keys are distinct', () {
      final keys = {
        BackgroundLocationService.dataCircleId,
        BackgroundLocationService.dataUid,
        BackgroundLocationService.dataName,
      };
      expect(keys.length, 3);
    });
  });

  group('LocationOffDetector — alert once per switch-off', () {
    test('enabled -> disabled alerts once', () {
      final d = LocationOffDetector();
      expect(d.check(false), isTrue);
    });

    test('stays disabled -> no repeat alert', () {
      final d = LocationOffDetector();
      expect(d.check(false), isTrue);
      expect(d.check(false), isFalse);
      expect(d.check(false), isFalse);
    });

    test('enabled stays enabled -> never alerts', () {
      final d = LocationOffDetector();
      expect(d.check(true), isFalse);
      expect(d.check(true), isFalse);
    });

    test('re-enable then disable again -> alerts again', () {
      final d = LocationOffDetector();
      expect(d.check(false), isTrue);
      expect(d.check(false), isFalse);
      expect(d.check(true), isFalse);
      expect(d.check(false), isTrue);
    });
  });

  group('LocationStatusCard', () {
    Future<void> pumpCard(
      WidgetTester tester,
      LocationSharingState? state,
      bool running,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocationStatusCard(
              state: state,
              serviceRunning: running,
              onFix: () {},
              onRefresh: () {},
            ),
          ),
        ),
      );
    }

    testWidgets('always + running shows ON (always)', (tester) async {
      await pumpCard(tester, LocationSharingState.always, true);
      expect(find.text('Location sharing ON (always)'), findsOneWidget);
      expect(find.text('Turn on always'), findsNothing);
    });

    testWidgets('always but service stopped says so', (tester) async {
      await pumpCard(tester, LocationSharingState.always, false);
      expect(find.text('Location sharing ON (always)'), findsOneWidget);
      expect(
        find.textContaining('background service is not running'),
        findsOneWidget,
      );
    });

    testWidgets('whileInUse shows the limit + fix button',
        (tester) async {
      await pumpCard(tester, LocationSharingState.whileInUse, false);
      expect(
        find.text('Location sharing: only while using the app'),
        findsOneWidget,
      );
      expect(find.text('Turn on always'), findsOneWidget);
    });

    testWidgets('off shows OFF + fix button', (tester) async {
      await pumpCard(tester, LocationSharingState.off, false);
      expect(find.text('Location sharing OFF'), findsOneWidget);
      expect(find.text('Turn on always'), findsOneWidget);
    });

    testWidgets('null state shows checking, no fix button',
        (tester) async {
      await pumpCard(tester, null, false);
      expect(find.text('Checking location sharing…'), findsOneWidget);
      expect(find.text('Turn on always'), findsNothing);
    });
  });
}
