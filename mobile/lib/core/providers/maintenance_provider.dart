import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../services/maintenance_service.dart';

/// 【FEAT-463 (2026-06-22)】緊急メンテナンスモードの provider。
///
/// 手動 Provider / StateNotifierProvider を採用 (新規 core 機能だが、CLAUDE.md
/// 「@riverpod は型安全な family / autoDispose が必要なときに採用」の趣旨に対し
/// 本機能は単純な Singleton 状態のため、build_runner 不要な手動定義で十分)。
final maintenanceServiceProvider = Provider<MaintenanceService>((ref) {
  return MaintenanceService(ref.watch(apiClientProvider).dio);
});

/// 現在の maintenance 状態。デフォルト off で開始、起動時 refresh + Dio
/// interceptor の header 検知で書き換わる (autoDispose にしない: アプリ全体で
/// 保持し続けるグローバル状態のため、CLAUDE.md「autoDispose の使い分け」遵守)。
final maintenanceStatusProvider =
    StateNotifierProvider<MaintenanceStatusNotifier, MaintenanceStatus>((ref) {
  return MaintenanceStatusNotifier(ref.watch(maintenanceServiceProvider));
});

class MaintenanceStatusNotifier extends StateNotifier<MaintenanceStatus> {
  MaintenanceStatusNotifier(this._service) : super(MaintenanceStatus.off);
  final MaintenanceService _service;

  /// 起動時 / overlay の「再試行」ボタンから呼ばれる。
  Future<void> refresh() async {
    state = await _service.fetchStatus();
  }

  /// Dio interceptor が `X-Maintenance: 1` header を検知した直後に呼ばれる。
  ///
  /// 【Pre-mortem S4】header だけでは title/body が取れないため、まず
  /// サビ口調 default 文言で仮 ON にして即座に overlay 表示 → 並行で
  /// [refresh] を呼んで実際の title/body (admin 設定値) を取得する。
  ///
  /// 【2026-07-07】ApiClient の 5xx sentinel からも同経路で呼ばれる。連続
  /// 5xx を検知した際に Backend degradation として placeholderOn 状態に
  /// 自動遷移するため、user への状況通知を統一する経路として機能する。
  void markEnabledFromHeader() {
    if (!state.isEnabled) {
      state = MaintenanceStatus.placeholderOn;
      // ignore: discarded_futures — fire-and-forget で詳細を取得
      refresh();
    }
  }

  /// 【2026-07-07】BootGate widget の起動時 probe から呼ばれる。
  ///
  /// probe で得た admin 設定 (title / body / expires_at 含む) を直接 set する。
  /// [markEnabledFromHeader] と異なり、既に isEnabled=true な state を上書きしても
  /// 良い (probe で取得した値の方が新鮮なため)。
  void setStatusForBoot(MaintenanceStatus status) {
    state = status;
  }
}
