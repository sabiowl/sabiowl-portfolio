import 'package:flutter/material.dart';

import 'cloud_layer_widget.dart';

/// 【更新 v3 (2026-06-26)】昼の城下町シーン用の「奥背景レイヤー」。
///
/// `world_noon_castle_town.png` の空エリアが透過化されたことに伴い、L1-L3 の
/// 全 3 層 (sky + cloud_layer + cloud_layer_2) を本ウィジェットに集約。
/// 城下町画像の透過部分から透けて見える構成で、雲 2 種の速度差で視差スクロール
/// (parallax) を実現する。
///
/// ## レイヤー構成 (奥 → 手前)
///
/// ```
/// L1 sky.png            (青空グラデーション、静止)            ← Image.asset (BoxFit.cover)
/// L2 cloud_layer.png    (大きな雲、60s 横断、奥側で遅い)      ← CloudLayerWidget
/// L3 cloud_layer_2.png  (小さな雲、40s 横断、手前で少し速い)  ← CloudLayerWidget
/// ```
///
/// 本 widget の上に world_frame_section.dart が L4 として
/// `world_noon_castle_town.png` を描画する。L4 の空部分が透過のため L1-L3 が透ける。
///
/// ## 速度差による視差スクロール
///
/// 大きい雲 (L2) を 60s でゆっくり、小さい雲 (L3) を 40s で少し速く流すことで、
/// 「奥の大きい雲はゆっくり、手前の小さい雲は速い」という擬似的な奥行き感を
/// 演出。Gemini world_frame_camp.md の拡張要件「Cloud Layer 1 / Cloud Layer 2」
/// を満たす実装。
///
/// ## TUNABLE 定数
///
/// - [_kCloudSlowDurationSec] (60s): cloud_layer 横断時間。大きいほど遅い
/// - [_kCloudFastDurationSec] (40s): cloud_layer_2 横断時間。「少し速い」の体感調整可
/// - [_kCloudVerticalShiftPct] (-0.30): 両雲層の縦シフト量
///
/// ## アセット未配置時のフォールバック
///
/// 各 Image.asset / CloudLayerWidget は errorBuilder で `SizedBox.shrink` に
/// フォールバック (PM が画像を後から配置するワークフローに対応)。
class NoonCastleTownBackground extends StatelessWidget {
  const NoonCastleTownBackground({super.key});

  static const String _kSkyAssetPath =
      'assets/images/backgrounds/world/sky.webp';
  static const String _kCloud1AssetPath =
      'assets/images/backgrounds/world/cloud_layer.webp';
  static const String _kCloud2AssetPath =
      'assets/images/backgrounds/world/cloud_layer_2.webp';

  static const double _kCloudSlowDurationSec = 60.0;  // L2 大雲 (遅い)
  static const double _kCloudFastDurationSec = 40.0;  // L3 小雲 (少し速い)
  static const double _kCloudVerticalShiftPct = -0.30; // 両雲を上空エリアへ寄せる

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // L1: 青空 (一番奥)
          Image.asset(
            _kSkyAssetPath,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.none,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
          // L2: 大きな雲 (奥側、ゆっくり)
          const CloudLayerWidget(
            assetPath: _kCloud1AssetPath,
            crossDurationSec: _kCloudSlowDurationSec,
            verticalShiftPct: _kCloudVerticalShiftPct,
          ),
          // L3: 小さな雲 (手前側、少し速い、奥の大雲との速度差で視差感を演出)
          const CloudLayerWidget(
            assetPath: _kCloud2AssetPath,
            crossDurationSec: _kCloudFastDurationSec,
            verticalShiftPct: _kCloudVerticalShiftPct,
          ),
        ],
      ),
    );
  }
}
