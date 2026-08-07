import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../../../core/services/iap_service.dart';
import '../../habits/providers/habits_provider.dart';

/// 【FEAT-436 (2026-06-17)】IAP サービスの Riverpod プロバイダ。
///
/// 設計:
/// - `iapOfferingsProvider` (FutureProvider.autoDispose): 商品リスト取得、
///   購入画面表示時に再フェッチ
/// - `iapPurchaseInFlightProvider` (StateProvider): 現在購入中の Package
///   identifier (例: `'diamond_pack_660'`)、null = 購入中なし。UI 側は
///   自 package の identifier と一致するかで判定し、他 package カードには
///   スピナーが表示されないようにする。旧 `bool` 実装では 660 選択時に
///   120/1440 も同時に spinner 化するバグ (2026-07-05 修正) の構造解消。
///
/// purchaseStatus は最終的に Backend webhook 経由でダイヤ残高に反映されるため、
/// 本 provider では in-flight 状態のみ管理。UI 完了通知は purchasePackage が
/// 成功した時点で「処理を受け付けました」SnackBar 表示、その後 1-2 秒の
/// Backend 同期待ちを経て playerNotifierProvider invalidate で残高更新。

/// IAP Service の参照 provider (singleton wrapper)。
final iapServiceProvider = Provider<IAPService>((ref) {
  return IAPService.instance;
});

/// 商品リスト取得。RevenueCat ダッシュボードの Offering "default" の
/// availablePackages を返す。
///
/// 設計: 初回フェッチ時に IAPService を player.id で configure (冪等)、
/// そのまま offerings を取得する。purchase_flutter SDK の logIn を内包する形で、
/// 認証完了 → 購入画面遷移の流れで自動的に identity が確立される。
///
/// 失敗時 (プラットフォーム未対応、SDK 未初期化、ネットワークエラー等) は
/// AsyncValue.error で UI に伝播。
final iapOfferingsProvider = FutureProvider.autoDispose<List<Package>>((ref) async {
  final service = ref.watch(iapServiceProvider);
  try {
    // 認証済 PlayerProfile.id を取得して IAP に渡す (RevenueCat の app_user_id 紐付け)
    final player = await ref.watch(playerNotifierProvider.future);
    await service.configure(player.id.toString());
    return await service.getOfferings();
  } catch (e, st) {
    debugPrint('[iapOfferingsProvider] failed: $e\n$st');
    rethrow;
  }
});

/// 現在購入中の Package identifier (null = なし)。
///
/// 【2026-07-05 hotfix】旧 `StateProvider<bool>` 実装では 660 個選択時に
/// 120/1440 の 2 カードにも spinner が表示されてしまうバグがあった。
/// 購入中の package を identifier で明示保持し、UI 側で自 identifier と一致した
/// カードのみ spinner を出すことで構造解消する。
final iapPurchaseInFlightProvider = StateProvider<String?>((ref) => null);
