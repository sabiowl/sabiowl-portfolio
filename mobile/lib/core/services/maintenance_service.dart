import 'package:dio/dio.dart';

import '../l10n/service_l10n.dart';  // 【FEAT-489 Phase 2D】BuildContext なし層の l10n

/// 【FEAT-463 (2026-06-22)】緊急メンテナンス状態。
class MaintenanceStatus {
  final bool isEnabled;
  final String title;
  final String body;
  final DateTime? expiresAt;

  const MaintenanceStatus({
    required this.isEnabled,
    required this.title,
    required this.body,
    this.expiresAt,
  });

  factory MaintenanceStatus.fromJson(Map<String, dynamic> json) {
    return MaintenanceStatus(
      isEnabled: json['is_enabled'] as bool? ?? false,
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      expiresAt: json['expires_at'] != null
          ? DateTime.tryParse(json['expires_at'] as String)
          : null,
    );
  }

  static const off = MaintenanceStatus(isEnabled: false, title: '', body: '');

  /// 【Pre-mortem S4】header 検知直後、詳細 (title/body) 取得前の仮 ON 状態。
  /// サビ口調 default 文言と同値 (CLAUDE.md / MaintenanceConfig default と整合)。
  ///
  /// 【FEAT-489 Phase 2D】文言が locale 依存になったため `const` → getter 化。
  /// BuildContext を持たない層なので [ServiceL10n] 経由で解決する。
  static MaintenanceStatus get placeholderOn => MaintenanceStatus(
        isEnabled: true,
        title: ServiceL10n.current.coreMaintenancePlaceholderTitle,
        body: ServiceL10n.current.coreMaintenancePlaceholderBodySabi_message,
      );
}

/// GET /api/maintenance/ を叩いて [MaintenanceStatus] を取得するサービス。
class MaintenanceService {
  final Dio _dio;
  MaintenanceService(this._dio);

  /// 通信失敗時は [MaintenanceStatus.off] にフォールバックする。
  /// 【Pre-mortem S6/S8】ユーザーが完全に締め出されないための defense-in-depth。
  Future<MaintenanceStatus> fetchStatus() async {
    try {
      final res = await _dio.get('/maintenance/');
      return MaintenanceStatus.fromJson(res.data as Map<String, dynamic>);
    } catch (_) {
      return MaintenanceStatus.off;
    }
  }
}
