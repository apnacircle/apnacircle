import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../l10n/strings.dart';

/// Play Billing — Family plan $5/year (v0.5, 23 Nov 2026).
///
/// Product id: `apnacircle_family_yearly` (see AppConstants).
///
/// HONEST LIMITS — read before promising anything to the user:
/// * A REAL purchase only works after the product exists in Play
///   Console AND the app is installed from Play (or a Play test
///   track). Until then the store reports "product not found" and
///   this service says so plainly — it NEVER fakes a charge and
///   NEVER claims a purchase succeeded when the store did not say so.
/// * The $5/year product must be created in Play Console by the
///   account owner (Mujahid) — that step is NOT part of this build.
/// * There is no server-side receipt verification yet: entitlement
///   is the store's purchase stream + a local flag. A receipt
///   check on a server is a follow-up for launch.
/// * JazzCash / Easypaisa cannot pay for a Play subscription from
///   inside the app — Play Billing is the only in-app route. The
///   local payment methods are shown on the Plan screen for
///   information only (see README).
enum BillingStatus {
  /// Store / Play Billing not available on this device or build.
  unavailable,
  loading,
  ready,
  productMissing,
  error,
  purchasePending,
  purchased,
}

/// Pure entitlement logic — unit-tested without the store.
class BillingEntitlement {
  /// True when any purchase for [productId] is purchased/restored.
  /// Pending, error and canceled purchases do NOT count.
  static bool isSubscribed(
    List<PurchaseDetails> purchases,
    String productId,
  ) =>
      purchases.any(
        (p) =>
            p.productID == productId &&
            (p.status == PurchaseStatus.purchased ||
                p.status == PurchaseStatus.restored),
      );

  /// True when any purchase for [productId] is still pending.
  static bool hasPendingPurchase(
    List<PurchaseDetails> purchases,
    String productId,
  ) =>
      purchases.any(
        (p) =>
            p.productID == productId &&
            p.status == PurchaseStatus.pending,
      );
}

class BillingService extends ChangeNotifier {
  BillingService({InAppPurchase? store}) : _store = store ?? InAppPurchase.instance;

  final InAppPurchase _store;

  static const _subscribedKey = 'subscription_active_v1';
  static const _productKey = 'subscription_product_v1';

  BillingStatus _status = BillingStatus.loading;
  BillingStatus get status => _status;

  ProductDetails? _product;
  ProductDetails? get product => _product;

  String? _error;
  String? get error => _error;

  /// Locale for user-facing error strings. Set by [initialize];
  /// the purchase stream has no caller to pass one.
  bool _isUrdu = false;

  /// Locally stored entitlement (from the last confirmed purchase).
  bool _subscribed = false;
  bool get isSubscribed => _subscribed;

  StreamSubscription<List<PurchaseDetails>>? _sub;

  /// Connect to the store, restore past purchases and fetch the
  /// product. Safe to call in demo mode — it just reports
  /// [BillingStatus.unavailable] when there is no store.
  Future<void> initialize({bool isUrdu = false}) async {
    _isUrdu = isUrdu;
    final prefs = await SharedPreferences.getInstance();
    _subscribed = prefs.getBool(_subscribedKey) ?? false;
    try {
      final available = await _store.isAvailable();
      if (!available) {
        _set(BillingStatus.unavailable, tr(isUrdu, 'svc_billingUnavailable'));
        return;
      }
      _sub = _store.purchaseStream.listen(
        _onPurchases,
        onError: (_) =>
            _set(BillingStatus.error, tr(isUrdu, 'svc_billingStreamFailed')),
      );
      final response = await _store.queryProductDetails(
        {AppConstants.billingProductId},
      );
      if (response.error != null) {
        _set(BillingStatus.error, tr(isUrdu, 'svc_billingUnreachable'));
        return;
      }
      if (response.productDetails.isEmpty) {
        // The product does not exist in Play Console yet (expected
        // before launch). NOT an error to hide — the Plan screen
        // tells the user plainly.
        _set(
          BillingStatus.productMissing,
          tr(isUrdu, 'svc_billingProductMissing'),
        );
        return;
      }
      _product = response.productDetails.first;
      _set(
        _subscribed ? BillingStatus.purchased : BillingStatus.ready,
        null,
      );
    } catch (e) {
      _set(
        BillingStatus.error,
        trf(isUrdu, 'svc_billingFailed', {'e': e.toString()}),
      );
    }
  }

  void _onPurchases(List<PurchaseDetails> purchases) {
    if (BillingEntitlement.isSubscribed(
      purchases,
      AppConstants.billingProductId,
    )) {
      _markSubscribed(purchases);
      return;
    }
    if (BillingEntitlement.hasPendingPurchase(
      purchases,
      AppConstants.billingProductId,
    )) {
      _set(BillingStatus.purchasePending, null);
      return;
    }
    for (final p in purchases) {
      if (p.status == PurchaseStatus.error) {
        _set(
          BillingStatus.error,
          tr(_isUrdu, 'svc_billingPurchaseFailed'),
        );
      }
      if (p.pendingCompletePurchase) {
        unawaited(_store.completePurchase(p));
      }
    }
  }

  Future<void> _markSubscribed(List<PurchaseDetails> purchases) async {
    _subscribed = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_subscribedKey, true);
    await prefs.setString(_productKey, AppConstants.billingProductId);
    for (final p in purchases) {
      if (p.pendingCompletePurchase) {
        await _store.completePurchase(p);
      }
    }
    _set(BillingStatus.purchased, null);
  }

  /// Start the real Google Play purchase flow. Does nothing (and
  /// says so) when the product is missing or the store is
  /// unavailable. Returns false when no purchase was started.
  Future<bool> buySubscription({bool isUrdu = false}) async {
    if (_product == null) return false;
    try {
      final ok = await _store.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: _product!),
      );
      if (ok) _set(BillingStatus.purchasePending, null);
      return ok;
    } catch (e) {
      _set(
        BillingStatus.error,
        trf(isUrdu, 'svc_billingStartFailed', {'e': e.toString()}),
      );
      return false;
    }
  }

  /// Re-check past purchases (e.g. after reinstall / new phone).
  Future<void> restorePurchases({bool isUrdu = false}) async {
    try {
      await _store.restorePurchases();
    } catch (e) {
      _set(
        BillingStatus.error,
        trf(isUrdu, 'svc_billingRestoreFailed', {'e': e.toString()}),
      );
    }
  }

  void _set(BillingStatus status, String? error) {
    _status = status;
    _error = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
