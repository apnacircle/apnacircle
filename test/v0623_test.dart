import 'package:apnacircle/core/language_service.dart';
import 'package:apnacircle/core/media_share.dart';
import 'package:apnacircle/models/chat_message.dart';
import 'package:apnacircle/screens/home_map_screen.dart';
import 'package:apnacircle/services/alert_history_service.dart';
import 'package:apnacircle/services/auth_service.dart';
import 'package:apnacircle/services/billing_service.dart';
import 'package:apnacircle/services/call_service.dart';
import 'package:apnacircle/services/chat_delete_service.dart';
import 'package:apnacircle/services/family_service.dart';
import 'package:apnacircle/services/media_service.dart';
import 'package:apnacircle/services/notification_service.dart';
import 'package:apnacircle/services/sms_location_service.dart';
import 'package:apnacircle/services/sos_sms_service.dart';
import 'package:apnacircle/services/sync_service.dart';
import 'package:apnacircle/services/pin_service.dart';
import 'package:apnacircle/services/onboarding_service.dart';
import 'package:apnacircle/services/join_request_service.dart';
import 'package:apnacircle/services/trial_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v0.6.23 — media sharing in the family chat: photo / video /
/// audio / document with compress-first, download-to-phone, and
/// the server file deleted once everyone downloaded it or after
/// 24 hours.
///
/// Widget tests here cover the attach button + the demo-mode
/// guard (no sync → a SnackBar, no sheet). The pick/compress/
/// upload/download paths use real plugins (image_picker,
/// file_picker, gal, Storage) and can only be proven on a real
/// phone — the pure rules + model round-trips below pin the
/// logic they depend on.
void main() {
  group('media_share pure rules', () {
    test('24-hour retention in ms', () {
      expect(mediaRetentionHours, 24);
      expect(mediaRetentionMs, 24 * 60 * 60 * 1000);
      expect(mediaExpiresAtMs(1000), 1000 + mediaRetentionMs);
    });

    test('expiry: fresh stays, 24h+1s is gone', () {
      const uploaded = 1000000000000;
      expect(
        isMediaExpired(uploadedAtMs: uploaded, nowMs: uploaded + 1000),
        isFalse,
      );
      expect(
        isMediaExpired(
          uploadedAtMs: uploaded,
          nowMs: uploaded + mediaRetentionMs,
        ),
        isTrue,
      );
      expect(
        isMediaExpired(
          uploadedAtMs: uploaded,
          nowMs: uploaded + mediaRetentionMs + 1000,
        ),
        isTrue,
      );
    });

    test('allMembersDownloaded ignores the sender', () {
      const members = ['parent', 'ali', 'mehvish'];
      // Nobody downloaded yet.
      expect(
        allMembersDownloaded(
          downloadedBy: {},
          memberIds: members,
          senderId: 'parent',
        ),
        isFalse,
      );
      // One member missing.
      expect(
        allMembersDownloaded(
          downloadedBy: {'ali': 1},
          memberIds: members,
          senderId: 'parent',
        ),
        isFalse,
      );
      // Every member except the sender downloaded.
      expect(
        allMembersDownloaded(
          downloadedBy: {'ali': 1, 'mehvish': 2},
          memberIds: members,
          senderId: 'parent',
        ),
        isTrue,
      );
      // The sender alone in the circle: nothing to wait for.
      expect(
        allMembersDownloaded(
          downloadedBy: {},
          memberIds: ['parent'],
          senderId: 'parent',
        ),
        isTrue,
      );
    });

    test('shouldDeleteMediaFromServer: expired OR all downloaded', () {
      const uploaded = 1000000000000;
      const members = ['parent', 'ali'];
      // Fresh, nobody downloaded: keep.
      expect(
        shouldDeleteMediaFromServer(
          uploadedAtMs: uploaded,
          nowMs: uploaded + 1000,
          downloadedBy: {},
          memberIds: members,
          senderId: 'parent',
        ),
        isFalse,
      );
      // Fresh, everyone downloaded: delete.
      expect(
        shouldDeleteMediaFromServer(
          uploadedAtMs: uploaded,
          nowMs: uploaded + 1000,
          downloadedBy: {'ali': 1},
          memberIds: members,
          senderId: 'parent',
        ),
        isTrue,
      );
      // Expired, nobody downloaded: delete (24-hour rule).
      expect(
        shouldDeleteMediaFromServer(
          uploadedAtMs: uploaded,
          nowMs: uploaded + mediaRetentionMs,
          downloadedBy: {},
          memberIds: members,
          senderId: 'parent',
        ),
        isTrue,
      );
    });

    test('formatMediaSize', () {
      expect(formatMediaSize(300), '300 B');
      expect(formatMediaSize(2048), '2 KB');
      expect(formatMediaSize(2500000), '2.4 MB');
      expect(formatMediaSize(12 * 1024 * 1024), '12 MB');
    });

    test('MediaType.fromName', () {
      expect(MediaType.fromName('photo'), MediaType.photo);
      expect(MediaType.fromName('video'), MediaType.video);
      expect(MediaType.fromName('audio'), MediaType.audio);
      expect(MediaType.fromName('document'), MediaType.document);
      expect(MediaType.fromName('bogus'), isNull);
      expect(MediaType.fromName(null), isNull);
    });

    test('photo compress targets + size cap', () {
      expect(photoMaxDimension, 1280);
      expect(photoQuality, 80);
      expect(maxMediaBytes, 100 * 1024 * 1024);
    });

    test('storage path contains circle, sender, message id', () {
      final p = MediaService.storagePath(
        circleId: 'c1',
        senderUid: 'u1',
        messageId: 'm9',
        fileName: 'pic.jpg',
      );
      expect(p, 'circles/c1/media/u1/m9/pic.jpg');
    });
  });

  group('ChatMessage media fields', () {
    test('media round-trip keeps every field', () {
      final now = DateTime.now();
      final m = ChatMessage(
        id: 'm1',
        senderId: 'parent',
        senderName: 'Mujahid',
        text: 'pic.jpg',
        at: now,
        mediaType: MediaType.photo,
        mediaUrl: 'https://example.invalid/pic.jpg',
        storagePath: 'circles/c1/media/parent/m1/pic.jpg',
        fileName: 'pic.jpg',
        fileSize: 123456,
        downloadedBy: const {'ali': 111},
        mediaUploadedAtMs: 1234567890000,
      );
      expect(m.hasMedia, isTrue);
      final back = ChatMessage.fromJson(m.toJson(), id: 'm1');
      expect(back.mediaType, MediaType.photo);
      expect(back.mediaUrl, 'https://example.invalid/pic.jpg');
      expect(back.storagePath, 'circles/c1/media/parent/m1/pic.jpg');
      expect(back.fileName, 'pic.jpg');
      expect(back.fileSize, 123456);
      expect(back.downloadedBy, {'ali': 111});
      expect(back.mediaUploadedAtMs, 1234567890000);
      expect(back.hasMedia, isTrue);
    });

    test('old message without media keys parses cleanly', () {
      final back = ChatMessage.fromJson({
        'senderId': 'ali',
        'senderName': 'Ali',
        'text': 'Ghar pahunch gaya.',
        'at': DateTime.now().toIso8601String(),
      }, id: '1');
      expect(back.hasMedia, isFalse);
      expect(back.mediaType, isNull);
      expect(back.downloadedBy, isEmpty);
    });
  });

  group('chat attach button (widget)', () {
    Future<void> pumpHome(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = AuthService();
      final sync = SyncService(auth);
      final family = FamilyService()..attachSync(sync);
      final sms = SmsLocationService();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => LanguageService()),
            ChangeNotifierProvider.value(value: auth),
            ChangeNotifierProvider.value(value: sync),
            ChangeNotifierProvider.value(value: PinService()),
            ChangeNotifierProvider.value(value: OnboardingService()),
            ChangeNotifierProvider.value(value: JoinRequestService(sync: sync, auth: auth)),
            ChangeNotifierProvider(create: (_) => TrialService()),
            ChangeNotifierProvider(create: (_) => BillingService()),
            ChangeNotifierProvider.value(
              value: NotificationService(sync),
            ),
            ChangeNotifierProvider.value(value: family),
            ChangeNotifierProvider.value(
              value: CallService(family: family),
            ),
            ChangeNotifierProvider.value(
              value: AlertHistoryService(family: family),
            ),
            ChangeNotifierProvider.value(
              value: ChatDeleteService(family: family),
            ),
            Provider.value(value: MediaService(sync)),
            Provider.value(value: sms),
            Provider.value(value: SosSmsService(sms)),
          ],
          child: const MaterialApp(home: HomeMapScreen()),
        ),
      );
      await tester.pump();
    }

    Future<void> openChat(WidgetTester tester) async {
      await tester.tap(find.text('Chat'));
      // Let the SOS FAB finish its exit animation — while it is
      // animating out it still covers the Chat tab's buttons.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('attach button is on the chat input row', (tester) async {
      await pumpHome(tester);
      await openChat(tester);
      expect(
        find.byTooltip('Send photo, video or file'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.attach_file), findsOneWidget);
    });

    testWidgets('attach in demo mode explains it needs sync', (tester) async {
      await pumpHome(tester);
      await openChat(tester);
      await tester.tap(find.byTooltip('Send photo, video or file'));
      await tester.pump();
      // Demo mode has no sync: a SnackBar, no picker sheet.
      expect(
        find.text('You need internet and a circle to send media.'),
        findsOneWidget,
      );
      expect(find.text('Photo'), findsNothing);
    });
  });
}
