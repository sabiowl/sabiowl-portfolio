// 【FEAT-388 Phase 2 (2026-05-30) → FEAT-479 v1 pivot (2026-07-07)】
// WorldFrame L2 軽量動きレイヤー + 基底クラス。
// world_frame_section.dart から _resolveAnimatedLayer(path) factory で呼ばれる。
// 各 widget は WorldAnimatedLayerBase を継承し 30fps 制限 + lifecycle 監視 + RepaintBoundary。
//
// 【v1 pivot 2026-07-07】時間帯連動背景 (FEAT-388) 撤廃に伴い以下 5 widget を削除:
//   evening_grassland_clouds_layers.dart
//   night_lighthouse_layers.dart
//   night_owl_library_layers.dart
//   night_tavern_layers.dart
//   night_snowy_cabin_layers.dart
// 現在の active barrel export: puzzle_world seed 3 シーン
// (sunrise/morning_grassland、noon_castle_town、night_forest_camp) 用 widget のみ。
//
// 【FEAT-479 hotfix (2026-07-05)】小鳥 3 羽 (MorningGrasslandLayers) は PM 判断で
// アニメを撤去したが、file 自体は将来 puzzle_world 拡張時の再利用に備えて barrel
// export 継続 (dead code ではなく "使用停止中" 状態、削除しない)。
//
// 【新規 (2026-06-25)】森のキャンプシーンは Gemini world_frame_camp.md 仕様の
// 本格実装に移行 (night_forest_camp/ サブディレクトリ、CampScene 統括)。
// 静止/動的の切替は kCampSceneAnimated 定数で制御。world_frame_section.dart は
// 本フラグを参照して背景画像 (org.png 静止 vs .png 動的) も swap する。
export 'world_animated_layer_base.dart';
export 'cloud_layer_widget.dart';                // 汎用 雲スクロールレイヤー
export 'noon_castle_town_background.dart';       // 昼の城下町: 奥背景 (sky + cloud)
export 'morning_grassland_background.dart';      // 目覚めの山頂: 奥背景 (cloud_layer_3/4)
export 'morning_grassland_layers.dart';          // 使用停止中 (小鳥アニメ、future 参照用)
export 'noon_castle_town_layers.dart';
export 'night_forest_camp_layers.dart';     // facade (後方互換)
export 'night_forest_camp/camp_scene.dart'; // 本実装 + kCampSceneAnimated フラグ
