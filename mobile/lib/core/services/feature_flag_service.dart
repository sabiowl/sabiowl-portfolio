import 'package:dio/dio.dart';

/// 【FEAT-477 (2026-07-03)】Feature Flag サービス。
///
/// /api/feature-flags/ から Switch / Sample / Flag を {name: bool} で取得し、
/// isEnabled(flagName) で個別 flag の ON/OFF を返す。
///
/// DB 障害 / ネットワーク不良時は {} を返し、全 flag=false で動作する (Pre-mortem S4)。
/// 未定義 flag は false (機能 OFF) にフォールバック (Pre-mortem S2)。
///
/// flag 命名規約: <domain>_<action>_<state>
///   例: iap_pack_120_enabled / battle_ui_v2_enabled / challenge_beta_active
class FeatureFlagService {
  FeatureFlagService(this._dio);
  final Dio _dio;

  Future<Map<String, bool>> fetchFlags() async {
    try {
      final resp = await _dio.get('/feature-flags/');
      final raw = resp.data['flags'] as Map<String, dynamic>;
      return raw.map((k, v) => MapEntry(k, v == true));
    } catch (_) {
      return {};
    }
  }

  /// [flags] マップから [flagName] の値を返す。未定義は false。
  static bool isEnabled(Map<String, bool>? flags, String flagName) {
    return flags?[flagName] ?? false;
  }
}
