import '../../../core/api/api_client.dart';
import '../models/sabi_message.dart';
// 【SEC-11】sabi_nav_result.dart は SabiNavigate(LLM) 廃止（2026-05-15）で削除済み。

export '../models/sabi_message.dart';

/// Sabi メッセージ API のレスポンスモデル（後方互換エイリアス）。
///
/// 新規コードでは [SabiMessage] を直接使用すること。
/// [isRestDay] のみ必要な場合は [SabiMessage.isRestDay] を参照。
typedef SabiResponse = SabiMessage;

class SabiService {
  final ApiClient _apiClient;
  SabiService(this._apiClient);

  /// ホーム画面用メッセージ（時間帯ベース、休息日フラグ付き）。
  ///
  /// 【新規 (2026-06-26)】[nonce] は pull-to-refresh 用の seed 撹乱値。
  /// Mobile が refresh 毎にインクリメントして送信、Backend が seed に含めて
  /// 異なるメッセージを返す。null/0 のときは未送信 (= 1 日 1 メッセージの
  /// 現状互換動作)。
  Future<SabiMessage> fetchMessage({
    String? timeSegment,
    int? nonce,
  }) async {
    final params = <String, String>{};
    if (timeSegment != null) params['time_segment'] = timeSegment;
    if (nonce != null && nonce > 0) params['nonce'] = nonce.toString();
    final res = await _apiClient.dio.get(
      '/sabi/message/',
      queryParameters: params.isEmpty ? null : params,
    );
    return SabiMessage.fromJson(res.data as Map<String, dynamic>);
  }

  /// 習慣達成時メッセージ（context=achievement）
  Future<SabiMessage> fetchAchievementMessage({
    required String habitCategory,
    required String habitName,
  }) async {
    final res = await _apiClient.dio.get(
      '/sabi/message/',
      queryParameters: {
        'context': 'achievement',
        'habit_category': habitCategory,
        'habit_name': habitName,
      },
    );
    return SabiMessage.fromJson(res.data as Map<String, dynamic>);
  }

  /// 連続記録メッセージ（context=streak）
  Future<SabiMessage> fetchStreakMessage({required int streak}) async {
    final res = await _apiClient.dio.get(
      '/sabi/message/',
      queryParameters: {
        'context': 'streak',
        'streak': streak.toString(),
      },
    );
    return SabiMessage.fromJson(res.data as Map<String, dynamic>);
  }

  // 【SEC-11】対話型ナビゲーション (navigate) は 2026-05-15 機能廃止で削除。
  // バックエンドの `POST /api/sabi/navigate/` も同時撤去済み。
}
