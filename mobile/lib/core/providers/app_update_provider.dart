import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../constants/preferences_keys.dart';
import '../services/app_update_service.dart';
import 'app_version_provider.dart';

/// 【FEAT-543 (2026-09-23)】バージョンアップ告知の provider。
///
/// `maintenance_provider.dart` (FEAT-463) と同じ手動 Provider の形。
final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  return AppUpdateService(ref.watch(apiClientProvider).dio);
});

/// サーバから取った設定（しきい値 2 本 + 推奨更新の文面）。
///
/// 既定は off。**起動時に 1 回だけ** `refresh()` される（`main.dart`）。
///
/// ⛔ メンテナンスと違い `X-App-Update` ヘッダーは無い。更新は
/// 「今すぐ止める必要がある事象」ではなく、毎レスポンスに判定を載せると
/// **メンテ告知で踏んだ誤発火の系統**を増やすだけである。
final appUpdateStatusProvider =
    StateNotifierProvider<AppUpdateStatusNotifier, AppUpdateStatus>((ref) {
  return AppUpdateStatusNotifier(ref.watch(appUpdateServiceProvider));
});

class AppUpdateStatusNotifier extends StateNotifier<AppUpdateStatus> {
  AppUpdateStatusNotifier(this._service) : super(AppUpdateStatus.off);
  final AppUpdateService _service;

  Future<void> refresh() async {
    state = await _service.fetchStatus();
  }
}

/// いま出すべき告知。
///
/// 🔴 **端末の版と突き合わせるのはここ。** サーバは版を知らない。
///
/// ⚠️ 推奨更新は 24 時間抑制を通す。**必須更新は通さない** ——
/// あちらは毎回出す。
final appUpdateDecisionProvider = FutureProvider<AppUpdateKind>((ref) async {
  final config = ref.watch(appUpdateStatusProvider);
  if (!config.isEnabled) return AppUpdateKind.none;

  // ⚠️ `appVersionProvider` は `PackageInfo` 由来。
  //    🔴 ビルド番号ではなく**表示バージョン**である（ストアに出るのはこちら）。
  final currentVersion = await ref.watch(appVersionProvider.future);
  final kind = resolveAppUpdateKind(
    config: config,
    currentVersion: currentVersion,
  );
  if (kind != AppUpdateKind.recommended) return kind;

  final suppressed = await isAppUpdateNoticeSuppressed(config.latestVersion);
  return suppressed ? AppUpdateKind.none : kind;
});
