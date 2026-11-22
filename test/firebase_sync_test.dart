import 'package:apnacircle/core/app_lock_service.dart';
import 'package:apnacircle/models/chat_message.dart';
import 'package:apnacircle/models/circle.dart';
import 'package:apnacircle/models/member.dart';
import 'package:apnacircle/services/firebase_config.dart';
import 'package:apnacircle/services/sms_location_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // --- RTDB paths (v0.3) ---
  test('RTDB paths match the fixed schema', () {
    expect(
      FirebaseConfig.circleMemberPath('c1', 'u1'),
      'circles/c1/members/u1',
    );
    expect(
      FirebaseConfig.circleLocksPath('c1', 'u1'),
      'circles/c1/locks/u1',
    );
    expect(
      FirebaseConfig.circleAlertsPath('c1', 'u1'),
      'circles/c1/alerts/u1',
    );
    expect(FirebaseConfig.circleChatPath('c1'), 'circles/c1/chat');
    expect(FirebaseConfig.circleEventsPath('c1'), 'circles/c1/events');
    expect(FirebaseConfig.userProfilePath('u1'), 'users/u1/profile');
    expect(
      FirebaseConfig.userCircleRolePath('u1', 'c1'),
      'users/u1/circles/c1',
    );
    expect(FirebaseConfig.invitePath('482913'), 'invites/482913');
    // Free trial node is keyed by the SHA-256 device hash, NOT by
    // account or circle (once per phone, 23 Nov 2026).
    expect(
      FirebaseConfig.trialPath('a1b2c3hash'),
      'trials/a1b2c3hash',
    );
  });

  test('invite code is 6 digits', () {
    final code = FirebaseConfig.newInviteCode((_) => 12345);
    expect(code, '112345');
    expect(code.length, 6);
    expect(int.tryParse(code), isNotNull);
    // Range check with a max random value.
    expect(FirebaseConfig.newInviteCode((_) => 899999), '999999');
  });

  test('Firebase project is configured (apnacircle-22ef3)', () {
    expect(FirebaseConfig.isConfigured, true);
    expect(FirebaseConfig.projectId, 'apnacircle-22ef3');
    expect(
      FirebaseConfig.databaseUrl,
      'https://apnacircle-22ef3-default-rtdb.asia-southeast1.firebasedatabase.app',
    );
  });

  // --- Circle model ---
  test('CircleInfo JSON round-trip keeps role + invite code', () {
    const c = CircleInfo(
      id: 'c1',
      name: 'Family',
      role: 'parent',
      inviteCode: '482913',
    );
    final back = CircleInfo.fromJson(c.toJson());
    expect(back.id, 'c1');
    expect(back.role, 'parent');
    expect(back.inviteCode, '482913');
    expect(back.isAdmin, true);
    expect(const CircleInfo(id: 'c2', name: 'X', role: 'child').isAdmin,
        false);
  });

  test('CircleEvent JSON round-trip keeps type + location', () {
    final e = CircleEvent(
      type: 'sos',
      fromUid: 'u1',
      fromName: 'Ali',
      at: DateTime(2026, 11, 22, 22, 0),
      lat: 31.5,
      lon: 74.3,
    );
    final back = CircleEvent.fromJson(e.toJson());
    expect(back.type, 'sos');
    expect(back.fromName, 'Ali');
    expect(back.lat, 31.5);
    expect(back.at, DateTime(2026, 11, 22, 22, 0));
  });

  test('ChatMessage JSON round-trip keeps text + time', () {
    final m = ChatMessage(
      id: 'push-key-1',
      senderId: 'u1',
      senderName: 'Ali',
      text: 'Ghar pahunch gaya.',
      at: DateTime(2026, 11, 22, 21, 30),
    );
    final back = ChatMessage.fromJson(m.toJson(), id: 'push-key-1');
    expect(back.id, 'push-key-1');
    expect(back.senderName, 'Ali');
    expect(back.text, 'Ghar pahunch gaya.');
    expect(back.at, DateTime(2026, 11, 22, 21, 30));
  });

  test('locks payload: list of LockedApp JSON round-trips', () {
    const apps = AppLockService.presets;
    final payload = {
      'apps': apps.map((a) => a.toJson()).toList(),
    };
    final back = (payload['apps'] as List)
        .map((a) => LockedApp.fromJson(a as Map<String, dynamic>))
        .toList();
    expect(back.length, apps.length);
    expect(back.firstWhere((a) => a.name == 'PUBG').mode.name, 'time');
  });

  test('Member locationViaSms survives JSON round-trip', () {
    const m = Member(
      id: 'ali',
      name: 'Ali',
      phone: '+923005550103',
      role: 'child',
      lat: 31.5497,
      lon: 74.3436,
      isOnline: false,
      locationViaSms: true,
    );
    final back = Member.fromJson(m.toJson());
    expect(back.locationViaSms, true);
    expect(back.isOnline, false);
    expect(back.copyWith(locationViaSms: false).locationViaSms, false);
  });

  // --- Offline SMS location (v0.3 addition) ---
  test('SMS encode/parse round-trip', () {
    final at = DateTime.fromMillisecondsSinceEpoch(1730000000000);
    final body = SmsLocationService.encodeSms(31.5204, 74.3587, at);
    expect(body, startsWith('APNACIRCLE LOC:'));
    final loc = SmsLocationService.parseSms(body, from: '+923001234567');
    expect(loc, isNotNull);
    expect(loc!.lat, 31.5204);
    expect(loc.lon, 74.3587);
    expect(loc.at, at);
    expect(loc.from, '+923001234567');
  });

  test('SMS parse rejects anything that is not our format', () {
    expect(SmsLocationService.parseSms('Hello, where are you?'), isNull);
    expect(SmsLocationService.parseSms('APNACIRCLE LOC:31.5'), isNull);
    expect(
      SmsLocationService.parseSms('APNACIRCLE LOC:abc,74.3,1730000000000'),
      isNull,
    );
    // Impossible coordinates.
    expect(
      SmsLocationService.parseSms(
        'APNACIRCLE LOC:91.0,74.3,1730000000000',
      ),
      isNull,
    );
    expect(
      SmsLocationService.parseSms(
        'APNACIRCLE LOC:31.5,181.0,1730000000000',
      ),
      isNull,
    );
    // Negative coordinates are fine (southern hemisphere).
    expect(
      SmsLocationService.parseSms(
        'APNACIRCLE LOC:-33.86,151.2,1730000000000',
      ),
      isNotNull,
    );
  });

  test('SMS throttle: first send allowed, then 15 min gap', () {
    final now = DateTime(2026, 11, 22, 22, 0);
    expect(
      SmsLocationService.shouldSendSms(lastSentAt: null, now: now),
      true,
    );
    expect(
      SmsLocationService.shouldSendSms(
        lastSentAt: now.subtract(const Duration(minutes: 14)),
        now: now,
      ),
      false,
    );
    expect(
      SmsLocationService.shouldSendSms(
        lastSentAt: now.subtract(const Duration(minutes: 15)),
        now: now,
      ),
      true,
    );
    expect(
      SmsLocationService.shouldSendSms(
        lastSentAt: now.subtract(const Duration(minutes: 60)),
        now: now,
      ),
      true,
    );
  });
}
