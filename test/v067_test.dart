import 'package:apnacircle/core/chat_paging.dart';
import 'package:apnacircle/core/language_service.dart';
import 'package:apnacircle/models/chat_message.dart';
import 'package:apnacircle/screens/home_map_screen.dart';
import 'package:apnacircle/services/auth_service.dart';
import 'package:apnacircle/services/billing_service.dart';
import 'package:apnacircle/services/family_service.dart';
import 'package:apnacircle/services/notification_service.dart';
import 'package:apnacircle/services/sms_location_service.dart';
import 'package:apnacircle/services/sync_service.dart';
import 'package:apnacircle/services/trial_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

ChatMessage _msg(String id, int minutesAgo) => ChatMessage(
      id: id,
      senderId: 'u1',
      senderName: 'Ali',
      text: 'msg $id',
      at: DateTime(2026, 11, 23, 12, 0).subtract(Duration(minutes: minutesAgo)),
    );

void main() {
  group('mergeChatMessages (v0.6.7 pagination)', () {
    test('merges an older page under the live page, oldest first', () {
      final live = [_msg('k50', 2), _msg('k51', 1)];
      final older = [_msg('k48', 5), _msg('k49', 3)];
      final merged = mergeChatMessages(live, older);
      expect(merged.map((m) => m.id).toList(),
          ['k48', 'k49', 'k50', 'k51']);
    });

    test('a live update never drops messages from a loaded older page',
        () {
      final loaded = [_msg('k48', 5), _msg('k49', 3), _msg('k50', 2)];
      final liveUpdate = [_msg('k50', 2), _msg('k51', 1)];
      final merged = mergeChatMessages(loaded, liveUpdate);
      expect(merged.map((m) => m.id).toList(),
          ['k48', 'k49', 'k50', 'k51']);
    });

    test('de-duplicates by id, newest copy wins', () {
      final existing = [_msg('k50', 2)];
      final incoming = [
        ChatMessage(
          id: 'k50',
          senderId: 'u1',
          senderName: 'Ali',
          text: 'edited',
          at: DateTime(2026, 11, 23, 11, 58),
        ),
      ];
      final merged = mergeChatMessages(existing, incoming);
      expect(merged.length, 1);
      expect(merged.first.text, 'edited');
    });

    test('empty sides are fine', () {
      expect(mergeChatMessages([], [_msg('k1', 1)]).length, 1);
      expect(mergeChatMessages([_msg('k1', 1)], []), [
        isA<ChatMessage>().having((m) => m.id, 'id', 'k1'),
      ]);
      expect(mergeChatMessages([], []), isEmpty);
    });
  });

  group('chat page size', () {
    test('newest page is 50 messages', () {
      expect(chatPageSize, 50);
    });
  });

  group('SyncService.load() (v0.6.7 cold start)', () {
    test('restores the cached circle list from local prefs only', () async {
      SharedPreferences.setMockInitialValues({
        'active_circle_id': 'c1',
        'my_circles_v1':
            '[{"id":"c1","name":"apna ghr","role":"parent","inviteCode":"660287"}]',
      });
      final sync = SyncService(AuthService());
      await sync.load();
      expect(sync.activeCircleId, 'c1');
      expect(sync.myCircles.length, 1);
      expect(sync.myCircles.first.name, 'apna ghr');
      // No Firebase in tests: load() must not touch the network —
      // the server refresh now happens post-first-frame from main().
      expect(sync.isAvailable, isFalse);
    });
  });

  group('lazy tab build (v0.6.7)', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/geolocator'),
        (call) async {
          if (call.method == 'checkPermission') return 0; // denied
          return null;
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'),
        (call) async {
          if (call.method == 'checkConnectivity') return <String>['wifi'];
          return null;
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(
        'dev.fluttercommunity.plus/connectivity_status',
        (message) async {
          const codec = StandardMethodCodec();
          final call = codec.decodeMethodCall(message);
          if (call.method == 'listen' || call.method == 'cancel') {
            return codec.encodeSuccessEnvelope(null);
          }
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/geolocator'),
        null,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'),
        null,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(
        'dev.fluttercommunity.plus/connectivity_status',
        null,
      );
    });

    Future<void> pumpHome(WidgetTester tester) async {
      final auth = AuthService();
      final sync = SyncService(auth);
      final family = FamilyService()..attachSync(sync);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => LanguageService()),
            ChangeNotifierProvider.value(value: auth),
            ChangeNotifierProvider.value(value: sync),
            ChangeNotifierProvider(create: (_) => TrialService()),
            ChangeNotifierProvider(create: (_) => BillingService()),
            ChangeNotifierProvider.value(
              value: NotificationService(sync),
            ),
            ChangeNotifierProvider.value(value: family),
            Provider.value(value: SmsLocationService()),
          ],
          child: const MaterialApp(home: HomeMapScreen()),
        ),
      );
      // No pumpAndSettle: the screen runs a 60 s periodic location
      // timer, which would make pumpAndSettle time out.
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    testWidgets('map is built only on the Map tab; switching tabs works',
        (tester) async {
      await pumpHome(tester);

      // Map tab (default): the map + SOS button are there.
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.text('SOS'), findsOneWidget);

      // Switch to Chat: the map leaves the tree — its widget
      // subtree (markers, member cards) is no longer built.
      await tester.tap(find.text('Chat'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(FlutterMap), findsNothing);
      expect(find.text('Message family…'), findsOneWidget);

      // Switch back to Map: the map is built again, same as before.
      // (Duration pumps let the FAB's exit/enter animation finish:
      // mid-animation the old and new FAB overlap in the tree.)
      await tester.tap(find.text('Map'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.text('SOS'), findsOneWidget);
    });
  });
}
