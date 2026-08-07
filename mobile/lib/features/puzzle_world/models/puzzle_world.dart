// 【FEAT-479 Phase 2a (2026-07-06)】ジグソーパズル世界システム models。
// 既存 challenge/social_models と同じ plain class + fromJson パターン
// (Freezed 不使用、build_runner 不要)。
//
// Backend Serializer: backend/api/views/puzzle_world.py 参照。

/// シーン基本情報 (state 判定用フラグ含まない共通 serialize)。
class PuzzleScene {
  final String key;
  final String name;
  final int displayOrder;
  final int pieceCount;
  final String backgroundKey;
  final String tagline;

  const PuzzleScene({
    required this.key,
    required this.name,
    required this.displayOrder,
    required this.pieceCount,
    required this.backgroundKey,
    required this.tagline,
  });

  factory PuzzleScene.fromJson(Map<String, dynamic> j) => PuzzleScene(
        key:           j['key']           as String? ?? '',
        name:          j['name']          as String? ?? '',
        displayOrder:  j['display_order'] as int?    ?? 0,
        pieceCount:    j['piece_count']   as int?    ?? 30,
        backgroundKey: j['background_key'] as String? ?? '',
        tagline:       j['tagline']       as String? ?? '',
      );
}

/// アクティブシーン詳細 (piece_states + completed 状態を含む)。
class ActiveSceneDetail {
  final PuzzleScene scene;
  /// [0..2] の整数リスト、length = scene.pieceCount。
  /// 0=未取得、1=grey (輪郭のかけら)、2=colored (彩りのかけら)。
  final List<int> pieceStates;
  final bool isCompleted;
  final DateTime? completedAt;

  const ActiveSceneDetail({
    required this.scene,
    required this.pieceStates,
    required this.isCompleted,
    required this.completedAt,
  });

  factory ActiveSceneDetail.fromJson(Map<String, dynamic> j) => ActiveSceneDetail(
        scene: PuzzleScene.fromJson(j),
        pieceStates: (j['piece_states'] as List<dynamic>? ?? const [])
            .map((e) => e as int)
            .toList(growable: false),
        isCompleted: j['is_completed'] as bool? ?? false,
        completedAt: (j['completed_at'] as String?) != null
            ? DateTime.tryParse(j['completed_at'] as String)
            : null,
      );

  /// 取得済 (grey + colored) の枚数。
  int get ownedCount => pieceStates.where((s) => s >= 1).length;

  /// カラー化済の枚数。
  int get coloredCount => pieceStates.where((s) => s == 2).length;
}

/// シーンステータス enum (`unstarted` / `active` / `in_progress` / `completed`)。
enum SceneStatus {
  unstarted,
  active,
  inProgress,
  completed;

  static SceneStatus fromString(String s) {
    switch (s) {
      case 'active':      return SceneStatus.active;
      case 'in_progress': return SceneStatus.inProgress;
      case 'completed':   return SceneStatus.completed;
      case 'unstarted':
      default:            return SceneStatus.unstarted;
    }
  }
}

/// SceneListView 用の per-scene 詳細 (status + progress + フラグ含む)。
class SceneListEntry {
  final PuzzleScene scene;
  final SceneStatus status;
  final bool isActive;
  final bool isDisplayed;
  final int ownedCount;
  final int coloredCount;
  final int totalCount;

  const SceneListEntry({
    required this.scene,
    required this.status,
    required this.isActive,
    required this.isDisplayed,
    required this.ownedCount,
    required this.coloredCount,
    required this.totalCount,
  });

  factory SceneListEntry.fromJson(Map<String, dynamic> j) {
    final progress = (j['progress'] as Map<String, dynamic>?) ?? const {};
    return SceneListEntry(
      scene:        PuzzleScene.fromJson(j),
      status:       SceneStatus.fromString(j['status'] as String? ?? 'unstarted'),
      isActive:     j['is_active']    as bool? ?? false,
      isDisplayed:  j['is_displayed'] as bool? ?? false,
      ownedCount:   progress['owned']   as int? ?? 0,
      coloredCount: progress['colored'] as int? ?? 0,
      totalCount:   progress['total']   as int? ?? 30,
    );
  }
}

/// 完成履歴 1 エントリ。
class PuzzleHistoryEntry {
  final String sceneKey;
  final String sceneName;
  final DateTime completedAt;
  final int rewardExpGained;
  final int rewardDiamondsGained;

  const PuzzleHistoryEntry({
    required this.sceneKey,
    required this.sceneName,
    required this.completedAt,
    required this.rewardExpGained,
    required this.rewardDiamondsGained,
  });

  factory PuzzleHistoryEntry.fromJson(Map<String, dynamic> j) => PuzzleHistoryEntry(
        sceneKey:             j['scene_key']              as String? ?? '',
        sceneName:            j['scene_name']             as String? ?? '',
        completedAt:          DateTime.tryParse(j['completed_at'] as String? ?? '')
            ?? DateTime.fromMillisecondsSinceEpoch(0),
        rewardExpGained:      j['reward_exp_gained']      as int? ?? 0,
        rewardDiamondsGained: j['reward_diamonds_gained'] as int? ?? 0,
      );
}

/// GET /api/puzzle-world/ の統合レスポンス。
class PuzzleWorldStatus {
  /// null = onboarding 未完了 (Mobile 側で選択画面へ誘導)
  final ActiveSceneDetail? activeScene;
  /// null = 自動 fallback (active → 時間帯連動 → 静止画)
  final PuzzleScene? displayedScene;
  /// 完成履歴 (最新順、最大 10 件)
  final List<PuzzleHistoryEntry> history;

  const PuzzleWorldStatus({
    required this.activeScene,
    required this.displayedScene,
    required this.history,
  });

  factory PuzzleWorldStatus.fromJson(Map<String, dynamic> j) => PuzzleWorldStatus(
        activeScene: (j['active_scene'] as Map<String, dynamic>?) != null
            ? ActiveSceneDetail.fromJson(j['active_scene'] as Map<String, dynamic>)
            : null,
        displayedScene: (j['displayed_scene'] as Map<String, dynamic>?) != null
            ? PuzzleScene.fromJson(j['displayed_scene'] as Map<String, dynamic>)
            : null,
        history: ((j['history'] as List<dynamic>?) ?? const [])
            .map((e) => PuzzleHistoryEntry.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );

  /// Onboarding 未完了 = active_scene が null。
  bool get needsOnboarding => activeScene == null;
}

/// GET /api/puzzle-world/scenes/ のレスポンス。
class PuzzleSceneList {
  final List<SceneListEntry> scenes;

  const PuzzleSceneList({required this.scenes});

  factory PuzzleSceneList.fromJson(Map<String, dynamic> j) => PuzzleSceneList(
        scenes: ((j['scenes'] as List<dynamic>?) ?? const [])
            .map((e) => SceneListEntry.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );
}

/// Habit / Timeline レスポンスの `puzzle_piece_awarded` field 用。
class PuzzlePieceAwarded {
  final int pieceIndex;
  final int newState;  // 常に 1 (grey)
  final String sceneKey;

  const PuzzlePieceAwarded({
    required this.pieceIndex,
    required this.newState,
    required this.sceneKey,
  });

  factory PuzzlePieceAwarded.fromJson(Map<String, dynamic> j) => PuzzlePieceAwarded(
        pieceIndex: j['piece_index'] as int? ?? 0,
        newState:   j['new_state']   as int? ?? 1,
        sceneKey:   j['scene_key']   as String? ?? '',
      );
}

/// Battle FinishView レスポンスの `puzzle_piece_colored` field 用。
class PuzzlePieceColored {
  final int pieceIndex;
  final int newState;  // 常に 2 (colored)
  final String sceneKey;
  final bool sceneCompleted;
  /// 完成時のみ non-null (Backend 側で計算済報酬値)
  final int? rewardExp;
  final int? rewardDiamonds;
  /// 完成 + 未着手シーンが残っている場合のみ non-null
  final PuzzleNextSceneHint? nextSceneHint;

  const PuzzlePieceColored({
    required this.pieceIndex,
    required this.newState,
    required this.sceneKey,
    required this.sceneCompleted,
    required this.rewardExp,
    required this.rewardDiamonds,
    required this.nextSceneHint,
  });

  factory PuzzlePieceColored.fromJson(Map<String, dynamic> j) => PuzzlePieceColored(
        pieceIndex:     j['piece_index']     as int? ?? 0,
        newState:       j['new_state']       as int? ?? 2,
        sceneKey:       j['scene_key']       as String? ?? '',
        sceneCompleted: j['scene_completed'] as bool? ?? false,
        rewardExp:      j['reward_exp']      as int?,
        rewardDiamonds: j['reward_diamonds'] as int?,
        nextSceneHint: (j['next_scene_hint'] as Map<String, dynamic>?) != null
            ? PuzzleNextSceneHint.fromJson(j['next_scene_hint'] as Map<String, dynamic>)
            : null,
      );
}

/// 完成後の次シーン誘導 hint (Sabi 台詞 + シーン選択画面遷移用)。
class PuzzleNextSceneHint {
  final String sceneKey;
  final String name;
  final String tagline;

  const PuzzleNextSceneHint({
    required this.sceneKey,
    required this.name,
    required this.tagline,
  });

  factory PuzzleNextSceneHint.fromJson(Map<String, dynamic> j) => PuzzleNextSceneHint(
        sceneKey: j['scene_key'] as String? ?? '',
        name:     j['name']      as String? ?? '',
        tagline:  j['tagline']   as String? ?? '',
      );
}
