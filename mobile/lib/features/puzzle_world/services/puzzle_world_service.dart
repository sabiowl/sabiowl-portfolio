import '../../../core/api/api_client.dart';
import '../models/puzzle_world.dart';

/// 【FEAT-479 (2026-07-06)】ジグソーパズル世界システム API クライアント。
///
/// Backend endpoint: `backend/api/views/puzzle_world.py`
/// - GET  /api/puzzle-world/            → [fetchStatus]
/// - GET  /api/puzzle-world/scenes/     → [fetchScenes]
/// - POST /api/puzzle-world/active/     → [selectActive]
/// - POST /api/puzzle-world/displayed/  → [selectDisplayed]
///
/// 【FEAT-479 hotfix (2026-07-06)】キャッシュ層 (dio_cache_interceptor
/// `CachePolicy.forceCache`) を廃止。パズル世界は per-user データで、
/// piece 獲得 / active_scene 切替 で頻繁に状態が変わるため、
/// キャッシュがあると「この世界を救う」タップ後に UI が反映されない
/// 不具合が発生 (invalidate しても forceCache が古い値を返す)。
/// master data (Character / Enemy) と異なり cache 対象外。
class PuzzleWorldService {
  final ApiClient _apiClient;
  PuzzleWorldService(this._apiClient);

  /// 現在の状態を取得 (per-user、キャッシュなし、常に fresh)。
  Future<PuzzleWorldStatus> fetchStatus() async {
    final res = await _apiClient.dio.get('/puzzle-world/');
    return PuzzleWorldStatus.fromJson(res.data as Map<String, dynamic>);
  }

  /// 全シーンの一覧 (SceneSelectionPage 用、キャッシュなし)。
  Future<PuzzleSceneList> fetchScenes() async {
    final res = await _apiClient.dio.get('/puzzle-world/scenes/');
    return PuzzleSceneList.fromJson(res.data as Map<String, dynamic>);
  }

  /// アクティブシーンを切り替える。
  ///
  /// レスポンスは `{detail, active_scene}` (成功時) or error_response 形式 (失敗時)。
  /// 失敗時は Dio Exception が上位に伝播する (呼出側で ApiError 経由でハンドリング)。
  Future<void> selectActive(String sceneKey) async {
    await _apiClient.dio.post(
      '/puzzle-world/active/',
      data: {'scene_key': sceneKey},
    );
  }

  /// 額縁表示シーンを切り替える (sceneKey=null で自動 fallback)。
  Future<void> selectDisplayed(String? sceneKey) async {
    await _apiClient.dio.post(
      '/puzzle-world/displayed/',
      data: {'scene_key': sceneKey},
    );
  }
}
