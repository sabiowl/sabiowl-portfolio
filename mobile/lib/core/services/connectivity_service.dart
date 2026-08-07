/// 【FEAT-370 (2026-05-28)】BUG-70 構造解消: offline 検知 Riverpod provider。
///
/// 既存の `connectivity_indicator.dart` (`ConnectivityNotifier`) は **API 結果から
/// 推測する** 事後的な offline 判定 (Dio エラー後に markOffline) で、SWR のキャッシュ
/// 表示制御に特化していた。本ファイルは **OS レベルの network 状態を事前に判定する**
/// 用途で、`timelineAutoCreateProvider` が POST をスキップするかどうかの判断に使う。
///
/// 2 つを併存させる設計理由:
/// - `connectivity_indicator` は「直近 API が通ったか」= UX 表示用、軽量。
/// - `connectivity_service` は「物理的に online か」= 副作用の事前抑止用、OS API 駆動。
/// - 統合すると責務が混ざるため分離維持。

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// `connectivity_plus` の生のステータスストリーム。
///
/// テスト時は `connectivityStatusProvider.overrideWith(...)` で
/// `Stream<List<ConnectivityResult>>.value([ConnectivityResult.none])` 等を
/// 注入すれば offline 状態を簡単に再現できる。
final connectivityStatusProvider =
    StreamProvider<List<ConnectivityResult>>((ref) {
  return Connectivity().onConnectivityChanged;
});

/// オンライン判定の bool provider。
///
/// - `ConnectivityResult.none` のみが返ってきた場合: offline (false)
/// - 上記以外 (wifi / mobile / ethernet / vpn / bluetooth / other): online (true)
/// - 不明 (Stream loading / error): **online 扱い** (false-positive を避けて
///   既存挙動互換、副作用抑止の主目的は「明確に offline」のときのみ発動）
///
/// テストでは `isOnlineProvider.overrideWithValue(false)` で直接モック可能。
final isOnlineProvider = Provider<bool>((ref) {
  final asyncStatus = ref.watch(connectivityStatusProvider);
  return asyncStatus.maybeWhen(
    data: (list) {
      if (list.isEmpty) return true;
      // 全要素 ConnectivityResult.none = 物理的に offline。
      // 1 つでも別 type があれば online (例: wifi + bluetooth) = 通信可能。
      return list.any((r) => r != ConnectivityResult.none);
    },
    orElse: () => true,
  );
});
