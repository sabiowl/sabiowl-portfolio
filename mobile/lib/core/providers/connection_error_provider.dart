import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 【2026-07-09】通信接続エラー / サーバエラー の状態。
///
/// 「admin が設定した緊急メンテナンス」(`maintenanceStatusProvider`) とは独立した
/// 別レイヤーの状態。以下の状況で `hasError=true` に遷移する:
///
/// - BootGate probe が 5xx (`_HealthResult.degraded`) を検知
/// - BootGate probe がタイムアウト / ネットワークエラー (`_HealthResult.timeout`)
///   で完了 (2026-07-09 変更、旧「何もしない」から「connection error 発火」に)
/// - ApiClient の 5xx sentinel (30 秒に連続 3 回) が発火
///
/// 【UI 優先順位】MaintenanceOverlay > ConnectionErrorOverlay > 通常 UI。
/// admin が明示的にメンテ ON にしている場合は MaintenanceOverlay が上位で
/// 表示され、ConnectionErrorOverlay は覆い隠される (main.dart の Layer 順で担保)。
///
/// 【復旧経路】
/// - ConnectionErrorOverlay の「再試行」ボタン: `/api/health/` を叩き 200 なら clear
/// - ApiClient interceptor が業務 API から 2xx を受信: `_reset5xxCounter` 経路で clear
///   (Backend が復旧したことの信号 = 通信接続エラー画面を出し続ける必要はない)
class ConnectionErrorStatus {
  final bool hasError;

  const ConnectionErrorStatus({required this.hasError});

  static const off = ConnectionErrorStatus(hasError: false);
  static const on = ConnectionErrorStatus(hasError: true);
}

final connectionErrorProvider =
    StateNotifierProvider<ConnectionErrorNotifier, ConnectionErrorStatus>((ref) {
  return ConnectionErrorNotifier();
});

class ConnectionErrorNotifier extends StateNotifier<ConnectionErrorStatus> {
  ConnectionErrorNotifier() : super(ConnectionErrorStatus.off);

  /// 【mark】connection error を発火する。既に true なら no-op (state 変更を発生させない)。
  ///
  /// BootGate probe / ApiClient 5xx sentinel の 2 経路から呼ばれる。
  void mark() {
    if (!state.hasError) {
      state = ConnectionErrorStatus.on;
    }
  }

  /// 【clear】connection error を解除する。既に false なら no-op。
  ///
  /// 「再試行」ボタン成功時 / 業務 API から 2xx 受信時に呼ばれる。
  void clear() {
    if (state.hasError) {
      state = ConnectionErrorStatus.off;
    }
  }
}
