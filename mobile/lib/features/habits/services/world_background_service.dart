/// 【FEAT-388 (2026-05-30) → FEAT-479 v1 pivot (2026-07-07)】
/// ワールドフレーム背景画像 path を PuzzleWorldScene.background_key から解決する service。
///
/// ## 責務 (v1 pivot 後、時間帯連動廃止)
///
/// - `pathForBackgroundKey(key)`: PuzzleWorldScene.background_key → 背景 asset path 解決
/// - `monoPathForBackgroundKey(key)`: 未完成シーン用モノクロ preview 画像 path 解決
///
/// 旧責務 (FEAT-388、`resolvePath()`) — **v1 pivot で撤廃**:
/// - 時間帯判定 (朝/昼/夕/夜) → 8 画像 rotation
/// - rest_day / levelUp / 冬季による状態連動判定
///
/// 撤廃理由: 「今取り組んでいる景色」を常に可視化するプロダクトミッション
/// (FEAT-479 眠る世界) と衝突するため。背景は puzzle_world の active/displayed
/// scene のみで決定する仕様に統一。
class WorldBackgroundService {
  WorldBackgroundService._();

  static final WorldBackgroundService instance = WorldBackgroundService._();

  // ── 背景 path 定数 (puzzle_world seed 3 シーン分のみ) ──────────────────────

  /// 【FEAT-479 v1 hotfix (2026-07-07)】朝の草原 → 目覚めの山頂 rename に伴い
  /// asset を world_morning_grassland.png → world_sunrise.png に変更。
  /// 変数名 `_kMorningGrassland` は既存参照互換のため据え置き。
  static const String _kMorningGrassland =
      'assets/images/backgrounds/world/world_sunrise.webp';
  static const String _kNoonCastleTown =
      'assets/images/backgrounds/world/world_noon_castle_town.webp';
  static const String _kNightForestCamp =
      'assets/images/backgrounds/world/world_night_forest_camp.webp';

  /// フォールバック path (画像 load 失敗時の secondary asset)。
  ///
  /// v1 pivot 前は `_kEveningGrasslandClouds` (時間帯 rotation の汎用夕背景)
  /// を採用していたが、時間帯連動撤廃に伴い puzzle_world の starter scene
  /// (目覚めの山頂) を fallback に統一。
  static const String kFallbackPath = _kMorningGrassland;

  /// 【FEAT-479 Phase 2d (2026-07-06 → v1 hotfix 2026-07-07)】
  /// PuzzleWorldScene.background_key から asset path を返す。
  ///
  /// FEAT-479 v1 seed シーンをカバー (`sunrise` (旧 morning_grassland) /
  /// `noon_castle_town` / `night_forest_camp`)。unknown key の場合は null を返し、
  /// 呼出側で fallback を適用する。
  ///
  /// **旧 key 'morning_grassland' との後方互換**: migration 0178 で
  /// background_key を 'sunrise' に統一済だが、旧 client (v1.0.x) がキャッシュ
  /// している場合の safety net として `morning_grassland` case も残置。
  ///
  /// v1.2+ でシーン追加時は本メソッドに case を追加すれば WorldFrameSection の
  /// 変更なしで対応可能。
  static String? pathForBackgroundKey(String key) {
    switch (key) {
      case 'sunrise':            return _kMorningGrassland;  // 目覚めの山頂
      case 'morning_grassland':  return _kMorningGrassland;  // 旧 key、後方互換
      case 'noon_castle_town':   return _kNoonCastleTown;
      case 'night_forest_camp':  return _kNightForestCamp;
      default: return null;  // unknown → 呼出側で fallback
    }
  }

  /// 【FEAT-479 (2026-07-06 → v1 hotfix 2026-07-07)】未完成シーン用モノクロ
  /// preview 画像 path を返す。
  ///
  /// 用途:
  /// - SceneSelectionPage の各カード右上 thumbnail (完成モチベ喚起)
  /// - **【hybrid hotfix 2026-07-07】WorldFrame の piece overlay で state=1
  ///   (タスク達成) セルの切り抜き描画** (world_frame_section.dart の
  ///   `_PuzzleGridPainter` が `ResizeImage` 経由で decode し、cell 単位で
  ///   `canvas.drawImageRect` する)
  ///
  /// カラー版と同ディレクトリ配置。unknown key は null。
  static String? monoPathForBackgroundKey(String key) {
    switch (key) {
      case 'sunrise':
      case 'morning_grassland':  // 旧 key、後方互換
        // 【hybrid hotfix 2026-07-07】専用 mono asset `world_sunrise_mono.png` を
        // 採用 (7/7 追加済、2.3MB)。旧 `world_morning_grassland_mono.png` からの
        // 差替えでピース差別化の視覚品質を向上。
        return 'assets/images/backgrounds/world/world_sunrise_mono.webp';
      case 'noon_castle_town':
        return 'assets/images/backgrounds/world/world_noon_castle_town_mono.webp';
      case 'night_forest_camp':
        return 'assets/images/backgrounds/world/world_night_forest_camp_mono.webp';
      default: return null;
    }
  }
}
