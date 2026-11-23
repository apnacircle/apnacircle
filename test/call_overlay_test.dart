import 'dart:convert';

import 'package:apnacircle/core/call_distance_service.dart';
import 'package:apnacircle/core/call_member_cache.dart';
import 'package:apnacircle/models/member.dart';
import 'package:flutter_test/flutter_test.dart';

/// v0.6.5 — real SIM-call distance overlay.
///
/// The native receiver (CallStateReceiver) and Dart share ONE
/// contract: the cache JSON built by CallMemberCache.buildJson, and
/// the number-normalization rules (same vectors in Kotlin's
/// CallMemberCache.kt comments). These tests pin the Dart side of
/// that contract, including the lookup the native side performs.
void main() {
  group('normalizePhoneNumber', () {
    test('Pakistani +92 with spaces collapses', () {
      expect(CallMemberCache.normalizePhoneNumber('+92 300 1234567'),
          '+923001234567');
    });
    test('Pakistani 03… with dashes collapses to +92', () {
      expect(CallMemberCache.normalizePhoneNumber('0300-1234567'),
          '+923001234567');
    });
    test('Pakistani 92… without + gains +', () {
      expect(CallMemberCache.normalizePhoneNumber('923001234567'),
          '+923001234567');
    });
    test('Pakistani 0300… without spaces collapses', () {
      expect(CallMemberCache.normalizePhoneNumber('03001234567'),
          '+923001234567');
    });
    test('10-digit 3… gains +92', () {
      expect(CallMemberCache.normalizePhoneNumber('3001234567'),
          '+923001234567');
    });
    test('non-Pakistani number keeps its country code', () {
      expect(CallMemberCache.normalizePhoneNumber('+1 415 555 0132'),
          '+14155550132');
    });
    test('empty stays empty', () {
      expect(CallMemberCache.normalizePhoneNumber(''), '');
    });
  });

  group('phonesMatch', () {
    test('+92 and 03 spellings of the same number match', () {
      expect(CallMemberCache.phonesMatch('+923001234567', '03001234567'),
          isTrue);
    });
    test('last-10-digits fallback matches', () {
      expect(CallMemberCache.phonesMatch('+923001234567', '3001234567'),
          isTrue);
    });
    test('different numbers do not match', () {
      expect(CallMemberCache.phonesMatch('+923001234567', '03007654321'),
          isFalse);
    });
    test('different country, same last 10 digits — still matches '
        '(same fallback the native side uses)', () {
      expect(CallMemberCache.phonesMatch('+923001234567', '+913001234567'),
          isTrue);
    });
    test('short numbers do not match on fallback', () {
      expect(CallMemberCache.phonesMatch('123', '0123'), isFalse);
    });
  });

  group('distance + format', () {
    test('Haversine: Lahore Gulberg to Model Town is ~5-6 km', () {
      final km = CallDistanceService.distanceKm(
          31.5204, 74.3587, 31.4800, 74.3200);
      expect(km, greaterThan(4.0));
      expect(km, lessThan(7.0));
    });
    test('Haversine: same point is 0 km', () {
      expect(CallDistanceService.distanceKm(31.5, 74.3, 31.5, 74.3), 0.0);
    });
    test('formatKm: under 1 km shows metres', () {
      expect(CallDistanceService.formatKm(0.35), '350 m');
    });
    test('formatKm: kilometres show one decimal', () {
      expect(CallDistanceService.formatKm(3.64), '3.6 km');
      expect(CallDistanceService.formatKm(295.44), '295.4 km');
    });
  });

  Member member({
    required String id,
    required String name,
    required String phone,
    double? lat,
    double? lon,
    bool sharing = true,
  }) =>
      Member(
        id: id,
        name: name,
        phone: phone,
        lat: lat,
        lon: lon,
        lastSeen: DateTime.utc(2026, 11, 23, 10, 53),
        locationSharingOn: sharing,
      );

  group('buildJson cache contract', () {
    test('member lookup by a raw 03… number finds the member', () {
      final json = CallMemberCache.buildJson([
        member(id: 'me', name: 'Me', phone: '+923111111111',
            lat: 31.5204, lon: 74.3587),
        member(id: 'ali', name: 'Ali', phone: '+923001234567',
            lat: 31.4800, lon: 74.3200),
      ], myId: 'me');
      // Simulate the native lookup: decode, match by phonesMatch.
      final decoded = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
      final members = decoded['members'] as List;
      Map<String, dynamic>? hit;
      for (final e in members) {
        final m = e as Map<String, dynamic>;
        if (CallMemberCache.phonesMatch(m['phone'] as String, '03001234567')) {
          hit = m;
          break;
        }
      }
      expect(hit, isNotNull);
      expect(hit!['name'], 'Ali');
      expect(decoded['myLat'], 31.5204);
      expect(decoded['myLon'], 74.3587);
    });
    test('member with no phone is left out of the cache', () {
      final json = CallMemberCache.buildJson([
        member(id: 'me', name: 'Me', phone: '', lat: 31.5, lon: 74.3),
      ]);
      expect((json['members'] as List), isEmpty);
    });
    test('member with sharing OFF is left out of the cache', () {
      final json = CallMemberCache.buildJson([
        member(id: 'ali', name: 'Ali', phone: '+923001234567',
            lat: 31.5, lon: 74.3, sharing: false),
      ]);
      expect((json['members'] as List), isEmpty);
    });
    test('empty member list builds an empty cache, no crash', () {
      final json = CallMemberCache.buildJson([]);
      expect((json['members'] as List), isEmpty);
      expect(json['myLat'], isNull);
    });
    test('my location comes from my own member entry', () {
      final json = CallMemberCache.buildJson([
        member(id: 'ali', name: 'Ali', phone: '+923001234567',
            lat: 31.4800, lon: 74.3200),
        member(id: 'me', name: 'Me', phone: '+923111111111',
            lat: 31.5204, lon: 74.3587),
      ], myId: 'me');
      expect(json['myLat'], 31.5204);
      expect(json['myLon'], 74.3587);
    });
    test('phone in the cache is stored normalized', () {
      final json = CallMemberCache.buildJson([
        member(id: 'ali', name: 'Ali', phone: '0300 1234567',
            lat: 31.5, lon: 74.3),
      ]);
      final members = json['members'] as List;
      expect((members.first as Map)['phone'], '+923001234567');
    });
  });
}
