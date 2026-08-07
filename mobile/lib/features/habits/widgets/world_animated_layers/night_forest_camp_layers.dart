// 【新規 (2026-06-25)】Gemini world_frame_camp.md 仕様の本格実装移行に伴い、
// 旧 NightForestCampLayers (RadialGradient + ホタル 5 個の暫定版) は
// night_forest_camp/ サブディレクトリの 5 ファイル分離実装に置換された。
//
// 本ファイルは後方互換のための薄い facade。world_frame_section.dart の
// _resolveAnimatedLayer factory から従来通り `NightForestCampLayers` を
// 参照可能。実体は night_forest_camp/camp_scene.dart の CampScene。
//
// 静止/動的の切替は kCampSceneAnimated 定数 (camp_scene.dart) で制御。

import 'package:flutter/material.dart';

import 'night_forest_camp/camp_scene.dart';

/// 後方互換 facade: `NightForestCampLayers` 経由で `CampScene` を返す。
///
/// 真実値は [CampScene] (night_forest_camp/camp_scene.dart)。
class NightForestCampLayers extends StatelessWidget {
  const NightForestCampLayers({super.key});

  @override
  Widget build(BuildContext context) => const CampScene();
}
