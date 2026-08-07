import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';  // 【FEAT-476】

import '../../../core/api/api_client.dart';
import '../models/task_suggestion.dart';

/// 【FEAT-467 (2026-07-02)】タスク候補 API クライアント。
class TaskSuggestionService {
  final ApiClient _apiClient;
  TaskSuggestionService(this._apiClient);

  /// [type] は 'event' / 'todo' / 'habit' のいずれか。
  /// 【FEAT-476 (2026-07-03) → 2026-07-09 hotfix】cache policy を `forceCache` から
  /// `refreshForceCache` に変更 (詳細は BattleService.fetchEnemyList と同経緯)。
  /// admin から TaskSuggestion (追加 / 編集 / is_active) を変更した際に
  /// 即応で反映されるようになる。offline / Backend 障害時は 12h キャッシュから
  /// graceful degrade。
  Future<List<TaskSuggestion>> fetchSuggestions(String type) async {
    final res = await _apiClient.dio.get(
      '/task-suggestions/',
      queryParameters: {'type': type},
      options: CacheOptions(
        store: null,  // インターセプターのグローバルストア (HiveCacheStore) を使用
        policy: CachePolicy.refreshForceCache,
        maxStale: const Duration(hours: 12),
      ).toOptions(),
    );
    final list = res.data as List<dynamic>;
    return list
        .map((e) => TaskSuggestion.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
