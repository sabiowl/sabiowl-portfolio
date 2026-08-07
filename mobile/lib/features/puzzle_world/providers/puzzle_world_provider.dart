import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../models/puzzle_world.dart';
import '../services/puzzle_world_service.dart';

/// 【FEAT-479 Phase 3 (2026-07-06)】演出発火用の pending piece 状態。
/// non-null にセットすると PuzzlePieceListener が overlay モーダルを起動する。
///
/// 経路: habits_provider / timeline (view side) / battle_provider が
/// Backend レスポンスの `puzzle_piece_awarded` / `puzzle_piece_colored` を
/// 直接 set。listener が overlay 起動後 → 演出完了で null にリセット。

/// Task piece (grey 追加) の pending 状態。
final puzzlePieceAwardedProvider =
    StateProvider<PuzzlePieceAwarded?>((ref) => null);

/// Quest piece (color 化) の pending 状態。
/// `scene_completed=true` のときは追加で `reward_exp` / `reward_diamonds` /
/// `next_scene_hint` が含まれる。Phase 3 では通常の quest piece 演出のみ、
/// 完成演出は Phase 4 で扱う (listener 側で分岐)。
final puzzlePieceColoredProvider =
    StateProvider<PuzzlePieceColored?>((ref) => null);

/// 【FEAT-479 (2026-07-06)】ジグソーパズル世界システム providers。
///
/// 既存の手動プロバイダー feature (social / settings / challenge 等) と整合
/// (CLAUDE.md「既存の手動プロバイダー feature は移行しない、新規は @riverpod を
/// 検討」、本 FEAT は指示書 §4.1 の skeleton をそのまま踏襲して手動パターンを採用)。

/// PuzzleWorldService は Provider (autoDispose 不要、通常存続)。
final puzzleWorldServiceProvider = Provider<PuzzleWorldService>((ref) {
  return PuzzleWorldService(ref.watch(apiClientProvider));
});

/// GET /api/puzzle-world/ の結果。ホーム画面等で watch。
/// autoDispose = ホーム画面から離れたら破棄、再訪時に再取得。
final puzzleWorldStatusProvider =
    FutureProvider.autoDispose<PuzzleWorldStatus>((ref) {
  return ref.watch(puzzleWorldServiceProvider).fetchStatus();
});

/// GET /api/puzzle-world/scenes/ の結果。SceneSelectionPage で watch。
final puzzleScenesProvider =
    FutureProvider.autoDispose<PuzzleSceneList>((ref) {
  return ref.watch(puzzleWorldServiceProvider).fetchScenes();
});

/// アクティブシーン / 額縁表示シーン切替のコマンド (write path)。
/// 呼出後は puzzleWorldStatusProvider / puzzleScenesProvider を invalidate すること。
final puzzleWorldCommandProvider = Provider<PuzzleWorldCommand>((ref) {
  return PuzzleWorldCommand(
    service: ref.watch(puzzleWorldServiceProvider),
    ref:     ref,
  );
});

/// 【FEAT-479】シーン切替コマンド。呼出後の invalidate を担う。
///
/// 通常の service 呼出 + 成功時に fetch provider を invalidate することで、
/// 呼出側は「操作を投げる」だけで UI が最新化される。
class PuzzleWorldCommand {
  final PuzzleWorldService service;
  final Ref ref;

  PuzzleWorldCommand({required this.service, required this.ref});

  /// アクティブシーン切替。成功時に status + scenes を invalidate。
  Future<void> selectActive(String sceneKey) async {
    await service.selectActive(sceneKey);
    ref.invalidate(puzzleWorldStatusProvider);
    ref.invalidate(puzzleScenesProvider);
  }

  /// 額縁表示シーン切替。sceneKey=null で自動 fallback。
  Future<void> selectDisplayed(String? sceneKey) async {
    await service.selectDisplayed(sceneKey);
    ref.invalidate(puzzleWorldStatusProvider);
    ref.invalidate(puzzleScenesProvider);
  }
}
