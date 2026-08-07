import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../l10n/service_l10n.dart';  // 【FEAT-489 Phase 2D】BuildContext なし層の l10n

/// 【FEAT-436 (2026-06-17)】RevenueCat 経由の IAP 薄ラッパー (iOS 先行)。
///
/// v1.0.1 hot fix で買い切りダイヤパック 2 種 (`diamond_pack_120` / `diamond_pack_660`)
/// を販売する。Android は Google Play Console 未加入のため v1.0.2 で対応予定。
///
/// 設計:
/// - 初期化: `IAPService.instance.configure(playerId)` をログイン完了後に 1 回呼ぶ
/// - 商品取得: `getOfferings()` → `Offering.current.availablePackages`
/// - 購入: `purchasePackage(package)` → 完了時に CustomerInfo 返却
/// - 復元: `restorePurchases()` (consumable には実質不要だが、復旧経路として保持)
/// - 領収書検証は RevenueCat が代行、Backend へは webhook 経由で通知 (Phase 2)
///
/// Android では `Platform.isAndroid` チェックで `IAPUnavailableException` を投げる。
/// Mobile UI 側で catch して「現在 iOS のみ対応」案内を表示する設計。
class IAPService {
  IAPService._();
  static final IAPService instance = IAPService._();

  bool _configured = false;
  String? _currentAppUserId;

  /// 現在 IAP が利用可能なプラットフォームか。
  /// v1.0.1: iOS のみ true。Android は v1.0.2 で Play Console 加入後に切替。
  bool get isAvailable => Platform.isIOS;

  /// RevenueCat SDK 初期化。
  /// 認証完了時 (PlayerProfile.id 確定後) に呼ぶ。再 configure は冪等。
  ///
  /// API キーは `--dart-define=REVENUECAT_PUBLIC_API_KEY_IOS=appl_xxx...` で
  /// ビルド時注入する (リポジトリにコミットしない、Phase 1 setup guide §H 参照)。
  Future<void> configure(String playerId) async {
    if (!isAvailable) {
      debugPrint('[IAPService] skip configure: platform=${Platform.operatingSystem}');
      return;
    }
    if (_configured && _currentAppUserId == playerId) {
      // 同一ユーザーで再 configure はスキップ
      return;
    }

    const apiKey = String.fromEnvironment('REVENUECAT_PUBLIC_API_KEY_IOS');
    if (apiKey.isEmpty) {
      debugPrint(
        '[IAPService] REVENUECAT_PUBLIC_API_KEY_IOS not set, skip configure. '
        'Use --dart-define to inject the key.',
      );
      return;
    }

    if (kDebugMode) {
      await Purchases.setLogLevel(LogLevel.debug);
    }

    final config = PurchasesConfiguration(apiKey)..appUserID = playerId;
    await Purchases.configure(config);
    _configured = true;
    _currentAppUserId = playerId;
    debugPrint('[IAPService] configured for player=$playerId');
  }

  /// ログアウト時の identity リセット。
  /// 次の configure で別 player に紐付け可能になる。
  Future<void> logOut() async {
    if (!isAvailable || !_configured) return;
    try {
      await Purchases.logOut();
    } catch (e) {
      debugPrint('[IAPService] logOut failed: $e');
    }
    _currentAppUserId = null;
  }

  /// 商品リスト取得。RevenueCat ダッシュボードで定義した Offering "default" の
  /// availablePackages を返す。
  ///
  /// 戻り値の Package は `package.identifier` (= `diamond_pack_120` 等) で識別し、
  /// `package.storeProduct.priceString` (例: "¥120") を UI 表示に使う。
  Future<List<Package>> getOfferings() async {
    if (!isAvailable) {
      throw IAPUnavailableException();
    }
    if (!_configured) {
      throw const IAPNotConfiguredException();
    }
    final offerings = await Purchases.getOfferings();
    final current = offerings.current;
    if (current == null) {
      // RevenueCat ダッシュボードで Offering "default" 未定義 or App 接続未完了
      debugPrint('[IAPService] current Offering is null, check RevenueCat dashboard');
      return const [];
    }
    return current.availablePackages;
  }

  /// 購入起動。決済 UI が表示され、ユーザーが Face ID / 指紋認証で承認すると
  /// `PurchaseResult` (= `customerInfo` + `transaction` のラッパー) が返る。
  ///
  /// 【FEAT-436 hotfix v3 (2026-06-17)】purchases_flutter ^10 では戻り値が
  /// `CustomerInfo` → `PurchaseResult` に変更された (v8 系から API 破壊)。
  /// 呼出側は `result.customerInfo` で従来の CustomerInfo を取得可能。
  ///
  /// 例外: `PlatformException` で投げられる (purchases_flutter ^10 標準仕様)。
  /// 呼出側は `PurchasesErrorHelper.getErrorCode(e)` で `PurchasesErrorCode`
  /// を解決し、`purchaseCancelledError` ならサイレント、それ以外はエラー
  /// 通知する (diamond_pack_page.dart 参照)。
  ///
  /// 成功時、RevenueCat から Backend にも webhook が飛び、Backend で
  /// ダイヤ加算 + IAPReceipt 記録が走る (Phase 2)。Mobile 側は PurchaseResult
  /// を受け取った時点で UI 「購入処理中」を解除し、Backend からの残高同期を
  /// 1-2 秒待ってから playerNotifierProvider invalidate で表示更新する。
  Future<PurchaseResult> purchasePackage(Package package) async {
    if (!isAvailable) {
      throw IAPUnavailableException();
    }
    if (!_configured) {
      throw const IAPNotConfiguredException();
    }
    final result = await Purchases.purchasePackage(package);
    return result;
  }

  /// 購入復元。consumable では実質不要 (一度付与で完結) だが、
  /// 「購入したのに付与されない」事故救済の経路として保持。
  Future<CustomerInfo> restorePurchases() async {
    if (!isAvailable) {
      throw IAPUnavailableException();
    }
    if (!_configured) {
      throw const IAPNotConfiguredException();
    }
    return Purchases.restorePurchases();
  }
}

/// プラットフォーム未対応 (Android で IAP を呼んだ際に投げられる)。
///
/// 【FEAT-489 Phase 2D】`toString()` はそのまま SnackBar に表示されるため arb 化。
/// Exception は BuildContext を持たないので [ServiceL10n] 経由で解決する。
class IAPUnavailableException implements Exception {
  IAPUnavailableException();
  @override
  String toString() => ServiceL10n.current.coreIapUnavailableSabi_message;
}

/// SDK 未初期化 (API キー未注入 or configure 未呼出)。
class IAPNotConfiguredException implements Exception {
  const IAPNotConfiguredException();
  @override
  String toString() => ServiceL10n.current.coreIapNotConfiguredSabi_message;
}
