import 'package:apnacircle/core/app_lock_service.dart';
import 'package:apnacircle/core/time_lock.dart';
import 'package:flutter_test/flutter_test.dart';

/// App Lock — Play Store + WhatsApp Business (v0.6.8).
///
/// User-reported 24 Nov 2026: both apps did NOT lock although the
/// parent typed their names in the custom-add box and locked them.
/// Cause: neither was in the presets, and the custom-name path
/// matched labels exactly / by substring only — "whatsapp business"
/// does not contain "wa business", and "playstore" (one word) is
/// not the label "Play Store". Fix: both are presets now with
/// exact package names, and known short forms resolve immediately
/// (Dart) and on the child's phone (MainActivity, native).
void main() {
  group('presets (v0.6.8) — Play Store + WhatsApp Business', () {
    test('Play Store preset uses the exact package com.android.vending',
        () {
      final playStore = AppLockService.presets
          .where((a) => a.packageName == 'com.android.vending');
      expect(playStore, hasLength(1));
      expect(playStore.first.name, 'Play Store');
      expect(playStore.first.locked, isTrue);
      expect(playStore.first.mode, LockMode.always);
    });

    test('WhatsApp Business preset uses com.whatsapp.w4b', () {
      final waBusiness = AppLockService.presets
          .where((a) => a.packageName == 'com.whatsapp.w4b');
      expect(waBusiness, hasLength(1));
      expect(waBusiness.first.name, 'WhatsApp Business');
      expect(waBusiness.first.locked, isTrue);
      expect(waBusiness.first.mode, LockMode.always);
    });

    test('plain WhatsApp preset is untouched (com.whatsapp)', () {
      final wa = AppLockService.presets
          .where((a) => a.packageName == 'com.whatsapp');
      expect(wa, hasLength(1));
      expect(wa.first.name, 'WhatsApp');
    });

    test('lockedPackagesNow includes both new presets when locked', () {
      final pkgs = AppLockService.lockedPackagesNow(
        AppLockService.presets,
        DateTime(2026, 11, 24, 10, 0),
      );
      expect(pkgs, contains('com.android.vending'));
      expect(pkgs, contains('com.whatsapp.w4b'));
      expect(pkgs, contains('com.whatsapp'));
    });
  });

  group('knownPackageForName (v0.6.8) — short forms', () {
    test('"WA Business" resolves to WhatsApp Business', () {
      expect(
        AppLockService.knownPackageForName('WA Business'),
        'com.whatsapp.w4b',
      );
    });

    test('case and spacing do not matter', () {
      expect(
        AppLockService.knownPackageForName('wa business'),
        'com.whatsapp.w4b',
      );
      expect(
        AppLockService.knownPackageForName('  WA  Business  '),
        'com.whatsapp.w4b',
      );
      expect(
        AppLockService.knownPackageForName('WhatsApp Business'),
        'com.whatsapp.w4b',
      );
    });

    test('"Playstore" (one word) resolves to the Play Store', () {
      expect(
        AppLockService.knownPackageForName('Playstore'),
        'com.android.vending',
      );
      expect(
        AppLockService.knownPackageForName('Play Store'),
        'com.android.vending',
      );
      expect(
        AppLockService.knownPackageForName('Google Play Store'),
        'com.android.vending',
      );
    });

    test('unknown names resolve to null (still custom:<name>)', () {
      expect(AppLockService.knownPackageForName('Snapchat'), isNull);
      expect(AppLockService.knownPackageForName(''), isNull);
      expect(AppLockService.knownPackageForName('   '), isNull);
    });
  });

  group('customApp (v0.6.8) — known names resolve at add time', () {
    test('"WA Business" is stored with the real package', () {
      final app = AppLockService.customApp('WA Business');
      expect(app.packageName, 'com.whatsapp.w4b');
      expect(app.isCustom, isTrue);
      expect(app.name, 'WA Business');
      expect(app.locked, isTrue);
    });

    test('"Playstore" is stored with the real package', () {
      final app = AppLockService.customApp('  Playstore ');
      expect(app.packageName, 'com.android.vending');
      expect(app.name, 'Playstore');
    });

    test('unknown names still fall back to custom:<name>', () {
      final app = AppLockService.customApp('Snapchat');
      expect(app.packageName, 'custom:snapchat');
      expect(app.isCustom, isTrue);
    });
  });
}
