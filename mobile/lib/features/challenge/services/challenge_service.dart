import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';  // 【FEAT-476】

import '../../../core/api/api_client.dart';
import '../models/challenge.dart';

/// 【FEAT-465 (2026-06-24)】月次カテゴリチャレンジ API クライアント。
class ChallengeService {
  final ApiClient _apiClient;
  ChallengeService(this._apiClient);

  /// 【FEAT-476 (2026-07-03) → 2026-07-09 hotfix】cache policy を `forceCache` から
  /// `refreshForceCache` に変更。理由は 2 点:
  ///   1. Challenge master (title / target_count / reward_exp / is_active) の
  ///      admin 編集を即応で反映するため
  ///   2. current_count は全ユーザー横断カウンタで随時変動、5min キャッシュだと
  ///      「他ユーザーの貢献分」が最大 5min 遅れて見える体感が悪化
  /// refreshForceCache = 常にネットワーク優先 / 失敗時のみキャッシュ fallback。
  /// offline / Backend 障害時は 5min キャッシュから graceful degrade。
  Future<ChallengeListData> fetchChallenges() async {
    final res = await _apiClient.dio.get(
      '/challenges/',
      options: CacheOptions(
        store: null,  // インターセプターのグローバルストア (HiveCacheStore) を使用
        policy: CachePolicy.refreshForceCache,
        maxStale: const Duration(minutes: 5),
      ).toOptions(),
    );
    return ChallengeListData.fromJson(res.data as Map<String, dynamic>);
  }
}
