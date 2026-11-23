import 'package:apnacircle/core/call_distance_service.dart';
import 'package:apnacircle/services/billing_service.dart';
import 'package:apnacircle/services/sim_change_service.dart';
import 'package:apnacircle/services/sync_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

/// v0.5 tests: SIM-change hash logic, billing entitlement states,
/// account-delete cleanup paths, and the SIM-call channel fallback.
/// Trial behaviour is NOT touched here (see test/trial_test.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  PurchaseDetails fakePurchase({
    required String productID,
    required PurchaseStatus status,
  }) =>
      PurchaseDetails(
        purchaseID: 'test-purchase-1',
        productID: productID,
        verificationData: PurchaseVerificationData(
          localVerificationData: '',
          serverVerificationData: '',
          source: 'test',
        ),
        transactionDate: '1700000000000',
        status: status,
      );

  // --- SIM-change fingerprint (pure) ---

  test('SIM fingerprint hash is stable and hides the raw values', () {
    const fields = ['26201', 'PK', 'Jazz'];
    final h1 = SimChangeDetector.hashFingerprint(fields);
    final h2 = SimChangeDetector.hashFingerprint(fields);
    expect(h1, h2);
    expect(h1.length, 64); // SHA-256 hex
    expect(h1.contains('26201'), false);
    expect(h1.contains('Jazz'), false);
    expect(h1.contains('PK'), false);
  });

  test('SIM fingerprint differs when the SIM changes', () {
    final a = SimChangeDetector.hashFingerprint(['26201', 'PK', 'Jazz']);
    final b = SimChangeDetector.hashFingerprint(['26203', 'PK', 'Telenor']);
    expect(a, isNot(b));
  });

  test('SIM change is only reported with a previous hash', () {
    // First run: no baseline yet — store it, do NOT alert.
    expect(SimChangeDetector.isChanged(null, 'abc'), false);
    // Same SIM: no change.
    expect(SimChangeDetector.isChanged('abc', 'abc'), false);
    // Different SIM: alert.
    expect(SimChangeDetector.isChanged('abc', 'def'), true);
    // Unreadable SIM: no alert either way.
    expect(SimChangeDetector.isChanged('abc', null), false);
  });

  // --- Billing entitlement (pure) ---

  test('subscribed only on a purchased/restored matching product', () {
    const product = 'apnacircle_family_yearly';
    expect(BillingEntitlement.isSubscribed([], product), false);
    expect(
      BillingEntitlement.isSubscribed(
        [fakePurchase(productID: product, status: PurchaseStatus.pending)],
        product,
      ),
      false,
    );
    expect(
      BillingEntitlement.isSubscribed(
        [fakePurchase(productID: product, status: PurchaseStatus.error)],
        product,
      ),
      false,
    );
    expect(
      BillingEntitlement.isSubscribed(
        [fakePurchase(productID: product, status: PurchaseStatus.canceled)],
        product,
      ),
      false,
    );
    expect(
      BillingEntitlement.isSubscribed(
        [fakePurchase(productID: 'other_product', status: PurchaseStatus.purchased)],
        product,
      ),
      false,
    );
    expect(
      BillingEntitlement.isSubscribed(
        [fakePurchase(productID: product, status: PurchaseStatus.purchased)],
        product,
      ),
      true,
    );
    expect(
      BillingEntitlement.isSubscribed(
        [fakePurchase(productID: product, status: PurchaseStatus.restored)],
        product,
      ),
      true,
    );
  });

  test('pending purchase is detected, purchased is not pending', () {
    const product = 'apnacircle_family_yearly';
    expect(
      BillingEntitlement.hasPendingPurchase(
        [fakePurchase(productID: product, status: PurchaseStatus.pending)],
        product,
      ),
      true,
    );
    expect(
      BillingEntitlement.hasPendingPurchase(
        [fakePurchase(productID: product, status: PurchaseStatus.purchased)],
        product,
      ),
      false,
    );
    expect(BillingEntitlement.hasPendingPurchase([], product), false);
  });

  // --- Account-delete cleanup paths (pure) ---

  test('cleanup paths touch only my own nodes', () {
    final paths = SyncService.accountCleanupPaths(
      'uid-1',
      ['circle-a', 'circle-b'],
    );
    expect(paths, [
      'users/uid-1',
      'circles/circle-a/members/uid-1',
      'circles/circle-b/members/uid-1',
    ]);
    // No other user's uid appears anywhere.
    for (final p in paths) {
      expect(p.contains('uid-2'), false);
    }
  });

  test('cleanup paths with no circles is just the user node', () {
    expect(
      SyncService.accountCleanupPaths('uid-1', []),
      ['users/uid-1'],
    );
  });

  // --- SIM-call channel fallback ---

  test('incomingNumber returns null when the channel throws', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('apnacircle/calls'),
      (MethodCall call) async {
        throw PlatformException(code: 'UNAVAILABLE');
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('apnacircle/calls'),
        null,
      );
    });
    expect(await CallDistanceService.incomingNumber(), isNull);
    expect(await CallDistanceService.hasCallLogPermission(), false);
  });

  test('hasCallLogPermission reads the native value', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('apnacircle/calls'),
      (MethodCall call) async {
        if (call.method == 'hasCallLogPermission') return true;
        return null;
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('apnacircle/calls'),
        null,
      );
    });
    expect(await CallDistanceService.hasCallLogPermission(), true);
  });
}
