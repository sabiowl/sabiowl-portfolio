// 【gameplay_review 20260709 §A-2 対応 (2026-07-09)】
// パズル世界のかけらグリッド layout の**真実値**。
//
// pieceStates.length → (columns, rows) の対応表を定義。以下 3 site から
// 参照されるため、シーン仕様変更 (15 / 45 / 60 piece 追加等) は本ファイルの
// entry を追加するだけで 3 site が同時追従する。
//
// 参照元 3 site:
//   1. ホーム WorldFrame 側 grid overlay
//      `mobile/lib/features/habits/widgets/world_frame/puzzle_grid_overlay.dart`
//   2. かけら取得 / 彩色演出 popup
//      `mobile/lib/features/puzzle_world/widgets/puzzle_piece_overlay_modal.dart`
//   3. シーン詳細画面のグリッド表示
//      `mobile/lib/features/puzzle_world/pages/puzzle_scene_detail_page.dart`
//
// 追加履歴:
//   - 2026-07-07 FEAT-479 v1 pivot: morning_grassland (目覚めの山頂) を
//     30 → 3 piece に、WorldFrame の grid_overlay が最初に追従
//   - 2026-07-09 (99f3f15): popup も pieceStates.length で動的解決 (2 site 目)
//   - 2026-07-09 (本 util 化): 詳細画面の追従漏れを解消 + 3 site を単一真実値に
//     集約 (gameplay_review 20260709 §2-1 P2 #2 対応)

/// pieceStates.length → (columns, rows) を返す。
///
/// - 3  → (3, 1)  morning_grassland、目覚めの山頂 (1 行 3 マス横並び)
/// - 30 → (6, 5)  noon_castle_town / night_forest_camp 等 (既存 6×5)
/// - その他 → (6, 5) fallback、safe-fill で不足マスは state=0 相当で塗る
///
/// 将来 15 / 45 / 60 piece scene を追加する際は本関数に entry を足すだけで、
/// 参照元 3 site が同時追従する。
(int columns, int rows) resolvePieceGridLayout(int count) {
  switch (count) {
    case 3:  return (3, 1);
    case 30: return (6, 5);
    default: return (6, 5);
  }
}
