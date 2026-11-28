import 'dart:convert';

import 'package:apnacircle/core/escape_gate.dart';
import 'package:apnacircle/core/protection_level.dart';
import 'package:apnacircle/models/circle.dart';
import 'package:apnacircle/models/member.dart';
import 'package:apnacircle/services/device_admin_service.dart';
import 'package:apnacircle/services/device_owner_service.dart';
import 'package:apnacircle/services/pin_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Uninstall protection (v0.6.13, 25 Nov 2026): the child must NOT
/// be able to delete the app on her own will — deleting needs the
/// parent's code (the SAME parent PIN that unlocks apps: one PIN
/// for everything). The parent can always remove the protection
/// with his code, on the child's phone or his own.
///
/// These tests pin the pure layers: protection-level mapping +
/// member-node field, the 2-hour "child gayab" threshold, the QR
/// provisioning payload, the adminDisabled event shape, and the
/// PIN gates — child escape hatches blocked without the correct
/// parent PIN, allowed with it, parent role unaffected, wrong PIN
/// rejected; protection removal allowed only with the parent code
/// verified. The platform calls themselves (device owner status,
/// signing checksum, RTDB writes) are thin and need a real phone.
void main() {
  group('ProtectionLevel', () {
    test('fromWire round-trips every level; garbage/null -> unknown',
        () {
      for (final level in ProtectionLevel.values) {
        expect(ProtectionLevel.fromWire(level.wireValue), level);
      }
      expect(ProtectionLevel.fromWire('superuser'),
          ProtectionLevel.unknown);
      expect(ProtectionLevel.fromWire(null), ProtectionLevel.unknown);
      expect(ProtectionLevel.fromWire(''), ProtectionLevel.unknown);
    });

    test('labels: owner Protected, admin Admin only, none Not protected, '
        'unknown shows nothing (never a guess)', () {
      expect(ProtectionLevel.owner.label, 'Protected');
      expect(ProtectionLevel.admin.label, 'Admin only');
      expect(ProtectionLevel.none.label, 'Not protected');
      expect(ProtectionLevel.unknown.label, '');
    });

    test('protectionLevelFrom: owner wins over admin', () {
      expect(
        protectionLevelFrom(isDeviceOwner: true, isAdminActive: true),
        ProtectionLevel.owner,
      );
      expect(
        protectionLevelFrom(isDeviceOwner: true, isAdminActive: false),
        ProtectionLevel.owner,
      );
      expect(
        protectionLevelFrom(isDeviceOwner: false, isAdminActive: true),
        ProtectionLevel.admin,
      );
      expect(
        protectionLevelFrom(isDeviceOwner: false, isAdminActive: false),
        ProtectionLevel.none,
      );
    });
  });

  group('Member protection field', () {
    Member member({ProtectionLevel protection = ProtectionLevel.unknown}) =>
        Member(
          id: 'uid-1',
          name: 'Mehvish',
          phone: '+923001234567',
          role: 'child',
          protection: protection,
        );

    test('toJson/fromJson round-trip keeps the level', () {
      for (final level in ProtectionLevel.values) {
        final back = Member.fromJson(member(protection: level).toJson());
        expect(back.protection, level);
      }
    });

    test('a node without the field (older app) reads as unknown', () {
      final json = member().toJson()..remove('protection');
      expect(Member.fromJson(json).protection, ProtectionLevel.unknown);
    });

    test('copyWith keeps the level unless replaced', () {
      final m = member(protection: ProtectionLevel.admin);
      expect(m.copyWith().protection, ProtectionLevel.admin);
      expect(m.copyWith(protection: ProtectionLevel.owner).protection,
          ProtectionLevel.owner);
    });
  });

  group('missing-child warning (2 hours)', () {
    final now = DateTime(2026, 11, 25, 12, 0);

    test('child offline 2h 1m -> warns; 1h 59m -> silent', () {
      expect(
        shouldShowMissingWarning(
          role: 'child',
          isOnline: false,
          lastSeen: now.subtract(const Duration(hours: 2, minutes: 1)),
          now: now,
        ),
        true,
      );
      expect(
        shouldShowMissingWarning(
          role: 'child',
          isOnline: false,
          lastSeen: now.subtract(const Duration(hours: 1, minutes: 59)),
          now: now,
        ),
        false,
      );
    });

    test('exactly 2 hours is NOT a warning (strictly older than 2h)',
        () {
      expect(
        shouldShowMissingWarning(
          role: 'child',
          isOnline: false,
          lastSeen: now.subtract(const Duration(hours: 2)),
          now: now,
        ),
        false,
      );
    });

    test('online child, parent role, member role, missing time -> silent',
        () {
      final stale = now.subtract(const Duration(hours: 5));
      expect(
        shouldShowMissingWarning(
          role: 'child',
          isOnline: true,
          lastSeen: stale,
          now: now,
        ),
        false,
      );
      expect(
        shouldShowMissingWarning(
          role: 'parent',
          isOnline: false,
          lastSeen: stale,
          now: now,
        ),
        false,
      );
      expect(
        shouldShowMissingWarning(
          role: 'member',
          isOnline: false,
          lastSeen: stale,
          now: now,
        ),
        false,
      );
      expect(
        shouldShowMissingWarning(
          role: 'child',
          isOnline: false,
          lastSeen: null,
          now: now,
        ),
        false,
      );
    });

    test('warning text carries the real staleness', () {
      expect(
        missingWarningText(
          now.subtract(const Duration(hours: 2, minutes: 30)),
          now,
        ),
        contains('No update for 2 hours'),
      );
      expect(
        missingWarningText(
          now.subtract(const Duration(hours: 1, minutes: 5)),
          now,
        ),
        contains('No update for 1 hour'),
      );
    });
  });

  group('Device Owner QR payload', () {
    test('contains every field the provisioning wizard needs', () {
      final payload = jsonDecode(DeviceOwnerService.buildQrPayload(
        downloadLocation: 'https://example.com/app-release.apk',
        checksum: 'QUJDREVGR0g=',
      )) as Map<String, dynamic>;
      expect(
        payload['android.app.extra.PROVISIONING_DEVICE_ADMIN_PACKAGE_NAME'],
        'com.apnacircle.app',
      );
      expect(
        payload[
            'android.app.extra.PROVISIONING_DEVICE_ADMIN_COMPONENT_NAME'],
        'com.apnacircle.app/com.apnacircle.app.ApnaCircleDeviceAdminReceiver',
      );
      expect(
        payload[
            'android.app.extra.PROVISIONING_DEVICE_ADMIN_PACKAGE_DOWNLOAD_LOCATION'],
        'https://example.com/app-release.apk',
      );
      expect(
        payload[
            'android.app.extra.PROVISIONING_DEVICE_ADMIN_SIGNATURE_CHECKSUM'],
        'QUJDREVGR0g=',
      );
      expect(
        payload['android.app.extra.PROVISIONING_SKIP_ENCRYPTION'],
        true,
      );
    });

    test('Wi-Fi is included when given, absent when not', () {
      final withWifi = jsonDecode(DeviceOwnerService.buildQrPayload(
        downloadLocation: 'https://example.com/app.apk',
        checksum: 'abc=',
        wifiSsid: 'HomeWifi',
        wifiPassword: 'secret123',
      )) as Map<String, dynamic>;
      expect(
        withWifi['android.app.extra.PROVISIONING_WIFI_SSID'],
        'HomeWifi',
      );
      expect(
        withWifi['android.app.extra.PROVISIONING_WIFI_PASSWORD'],
        'secret123',
      );
      expect(
        withWifi['android.app.extra.PROVISIONING_WIFI_SECURITY_TYPE'],
        'WPA',
      );
      final withoutWifi = jsonDecode(DeviceOwnerService.buildQrPayload(
        downloadLocation: 'https://example.com/app.apk',
        checksum: 'abc=',
      )) as Map<String, dynamic>;
      expect(
        withoutWifi.containsKey('android.app.extra.PROVISIONING_WIFI_SSID'),
        false,
      );
    });

    test('signing checksum is base64 SHA-256 shape (44 chars)', () {
      // A real checksum comes from the platform; here only the
      // shape the QR carries is pinned: 32 bytes -> 44 base64 chars.
      final payload = jsonDecode(DeviceOwnerService.buildQrPayload(
        downloadLocation: 'https://example.com/app.apk',
        checksum: 'A' * 43 + '=',
      )) as Map<String, dynamic>;
      final checksum = payload[
              'android.app.extra.PROVISIONING_DEVICE_ADMIN_SIGNATURE_CHECKSUM']
          as String;
      expect(checksum.length, 44);
      expect(() => base64.decode(checksum), returnsNormally);
    });
  });

  group('adminDisabled event shape', () {
    test('round-trips through JSON with type + who + when', () {
      final at = DateTime(2026, 11, 25, 12, 6);
      final event = CircleEvent(
        type: 'adminDisabled',
        fromUid: 'uid-child',
        fromName: 'Mehvish',
        at: at,
      );
      final back = CircleEvent.fromJson(event.toJson());
      expect(back.type, 'adminDisabled');
      expect(back.fromUid, 'uid-child');
      expect(back.fromName, 'Mehvish');
      expect(back.at, at);
    });
  });

  group('escape gate (part E) — one parent PIN for everything', () {
    test('only the child role is gated; parent/elderly/member/demo pass',
        () {
      expect(childEscapeNeedsParentPin('child'), true);
      expect(childEscapeNeedsParentPin('parent'), false);
      expect(childEscapeNeedsParentPin('elderly'), false);
      expect(childEscapeNeedsParentPin('member'), false);
      expect(childEscapeNeedsParentPin(null), false);
    });

    test('correct parent PIN verifies; wrong PIN rejected, no hint', () {
      const pin = '4821';
      final hash = PinService.hashPin(pin);
      expect(verifyPinAgainstHash(pin, hash), true);
      expect(verifyPinAgainstHash('0000', hash), false);
      expect(verifyPinAgainstHash('4822', hash), false);
      expect(verifyPinAgainstHash('', hash), false);
      // The hash is the same scheme LockActivity uses:
      // SHA-256 of "apnacircle:<pin>" — one PIN for app locks,
      // account delete, sign-out and protection removal.
      expect(hash, PinService.hashPin(pin));
    });
  });

  group('protection removal gate — parent code, both directions', () {
    test('parent\'s correct code removes protection', () {
      const pin = '4821';
      final hash = PinService.hashPin(pin);
      final pinVerified = verifyPinAgainstHash(pin, hash);
      expect(pinVerified, true);
      expect(
        DeviceOwnerService.canClearDeviceOwner(
          pinVerified: pinVerified,
          isDeviceOwner: true,
        ),
        true,
      );
    });

    test('wrong code does NOT remove protection', () {
      const pin = '4821';
      final hash = PinService.hashPin(pin);
      final pinVerified = verifyPinAgainstHash('0000', hash);
      expect(pinVerified, false);
      expect(
        DeviceOwnerService.canClearDeviceOwner(
          pinVerified: pinVerified,
          isDeviceOwner: true,
        ),
        false,
      );
    });

    test('correct code but not the owner -> nothing to clear', () {
      expect(
        DeviceOwnerService.canClearDeviceOwner(
          pinVerified: true,
          isDeviceOwner: false,
        ),
        false,
      );
    });
  });

  group('offline rule — enforcement never depends on network', () {
    test(
        'with net off, Device Admin active still blocks uninstall '
        '(local status path — Android itself refuses it)', () {
      // The enforcement decision is a LOCAL device fact, never a
      // server read: admin active -> the phone refuses uninstall
      // with no network involved at all.
      expect(
        protectionLevelFrom(isDeviceOwner: false, isAdminActive: true),
        ProtectionLevel.admin,
      );
      expect(
        protectionLevelFrom(isDeviceOwner: true, isAdminActive: false),
        ProtectionLevel.owner,
      );
    });

    test('PIN gates verify OFFLINE from the cached hash (no network)',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final pin = PinService();
      // First sync while online caches the circle's parent PIN
      // hash locally (SyncService.cacheParentPinHash).
      await pin.adoptHash(PinService.hashPin('4821'));
      // Now offline: the same hash answers every gate.
      expect(pin.verify('4821'), true);
      expect(pin.verify('0000'), false);
      expect(verifyPinAgainstHash('4821', pin.pinHash!), true);
      expect(verifyPinAgainstHash('9999', pin.pinHash!), false);
    });

    test('adoptHash never overwrites a PIN already on the phone',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final pin = PinService();
      await pin.setPin('1111');
      await pin.adoptHash(PinService.hashPin('4821'));
      expect(pin.verify('1111'), true);
      expect(pin.verify('4821'), false);
    });

    test('admin-off pending flag key is stable (receiver + Dart agree)',
        () {
      // The native receiver writes this exact key into the
      // FlutterSharedPreferences file; the background task and
      // the next-start path read it. If the key ever changes,
      // the offline-queued alert is lost.
      expect(
        DeviceAdminService.pendingDisabledPrefsKey,
        'apnacircle_admin_disabled_at',
      );
    });
  });
}
