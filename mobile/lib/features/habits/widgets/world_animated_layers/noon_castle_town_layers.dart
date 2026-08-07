import 'package:flutter/material.dart';
import 'world_animated_layer_base.dart';

/// 🏰 昼の城下町: 背景画像 [world_noon_castle_town.png] の **手前** に重ねる
/// 前景アニメ層。
///
/// ## レイヤー位置 (world_frame_section.dart の Stack 3 層構成)
///
/// ```
/// L0 NoonCastleTownBackground     ← sky + cloud_layer + cloud_layer_2
/// L1 world_noon_castle_town.png   ← 城下町 (空エリアは透過で L0 透ける)
/// L2 NoonCastleTownLayers (本層)  ← 空 placeholder (将来の前景アニメ用)
/// ```
///
/// ## 設計変更履歴
///
/// v1 (2026-06-25): 旗 ×4 + CloudLayerWidget。
/// v2 (2026-06-26 朝): 旗削除 + 雲を奥 (L0) に移動 → SizedBox.shrink。
/// v3 (2026-06-26 昼): castle town 不透明問題で雲を本層 (L2) に再配置。
/// v4 (2026-06-26 当): castle town 透過化対応 + cloud_layer_2 追加 → 雲を奥
///     (NoonCastleTownBackground) に集約。本層は再び SizedBox.shrink に戻る。
///
/// ## 将来拡張
///
/// 「城下町を歩く人 / 鳥の飛行 / 桜の花びら」等、背景画像より手前で動く要素を
/// 追加する場合は本ファイルに実装する。雲・空などの「背景演出」は
/// [NoonCastleTownBackground] (L0) を使う。
class NoonCastleTownLayers extends WorldAnimatedLayerBase {
  const NoonCastleTownLayers({super.key});

  @override
  State<NoonCastleTownLayers> createState() => _NoonCastleTownLayersState();
}

class _NoonCastleTownLayersState
    extends WorldAnimatedLayerBaseState<NoonCastleTownLayers> {
  @override
  void pauseAnimations() {
    // 現状アニメ無し
  }

  @override
  void resumeAnimations() {
    // 現状アニメ無し
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}
