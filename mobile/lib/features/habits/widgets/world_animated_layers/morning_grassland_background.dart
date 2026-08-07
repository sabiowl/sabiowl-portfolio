import 'package:flutter/material.dart';

import 'cloud_layer_widget.dart';

/// 【新規 (2026-07-05) → v1 hotfix (2026-07-07)】「目覚めの山頂」シーン用の
/// 「雲 + 前景レイヤー統合ウィジェット」。旧名称「朝の草原」から rename。
///
/// **配置**: world_frame_section.dart の `_resolveAnimatedLayer` から呼ばれ、
/// world image (world_sunrise.png、旧 world_morning_grassland.png) の**手前**
/// に描画される。(旧: 小鳥アニメ (MorningGrasslandLayers) の**奥** に描画。
/// 2026-07-05 に小鳥アニメが撤去されたため、現在は雲が最前景アニメーション
/// レイヤー)。
///
/// ## 多層構造による「本当に空に浮かぶ雲」の実現
///
/// world_sunrise.png (下敷き) の上に、前景画像 (world_sunrise_1.png) と雲を
/// 組み合わせて、雲が人物の**背後** に隠れる自然な奥行きレイヤリングを実現する。
/// 前景画像は元絵の一部を切り出したもの (人物) で、元絵とピクセル一致するため
/// 見た目は変わらないが、レイヤー順序を制御することで雲が正しい奥行きに配置される。
///
/// ## レイヤー構成 (奥 → 手前)
///
/// ```
/// L4 world_sunrise.png                 (既存フル絵、下敷き、Image.asset で背景描画)
/// L5 MorningGrasslandBackground (本 widget、クラス名は互換のため据置):
///     ├ cloud_layer_4.png (小雲群、60s 横断、ゆっくり漂う、imageScale で縮小、遠く)
///     ├ cloud_layer_3.png (大雲群、30s 横断、少し速い、imageScale で縮小、手前)
///     └ world_sunrise_1.png            (人物、雲より手前 = 雲が人物の背後に隠れる)
/// ```
///
/// 【v1 hotfix 2026-07-07】旧「朝の草原」の tree layer (world_morning_grassland_2.png、
/// 木・草・岩) は「目覚めの山頂」シーンの景色構成 (山頂 = 樹木少なめ) に合わないため
/// 撤去。world_sunrise_3.png は現状未使用 (将来レイヤー拡張用の予備、未接続)。
///
/// 【2026-07-05 更新 v3】雲を「もう少し小さく」の PM 要望に対応し縮小率を
/// 0.70 → 0.50 (手前) / 0.55 → 0.35 (遠く) に。合わせて小鳥アニメ
/// (MorningGrasslandLayers) を撤去 (PM 判断: 「風の演出の黒い波線」に
/// 見えたため)。雲のみの静謐な演出に振り切る。
///
/// ## noon_castle_town との違い (前景配置の理由)
///
/// noon_castle_town は world_noon_castle_town.png の空エリアが**透過**処理
/// されているため、noon_castle_town_background は L4 (world image) の**奥** に
/// 配置され、透過部分から透けて見える構造。一方、目覚めの山頂の world image は
/// 空エリアも含めて完全に不透明 (紫グラデ + 星の描き込み) のため、同じ
/// 「奥」パターンでは雲が完全に隠れる。よって本 widget は L4 の**手前** に
/// 配置し、雲画像の透明地部分から world image が透ける形にする。
///
/// ## 動きの設計 (現実の空を目指す)
///
/// 「静止画を動かしている」ではなく「本当に空に浮かんでいる雲」を目指すため、
/// 以下を組み合わせる:
///
/// 1. **横方向のスクロール**: 一定速度で左方向、シームレスループ (継ぎ目ゼロ)
///    - 30 秒 / 60 秒で画面を 1 回横断 = 「気付くか気付かないか」の速度
///    - 遠くの雲 (小さい・遅い) と近くの雲 (大きい・速い) の速度差で視差感
///
/// 2. **縦方向の sin 波揺れ**: ±1.5px、周期 10-14 秒
///    - 「風に微かに揺られる」自然な浮遊感
///    - 拡大・変形・回転は使わない (静止画の形は保つ)
///
/// 3. **ランダム開始位相**: 起動時に横位相 + sin 波位相をランダム化
///    - 複数レイヤーが同期して動くと不自然に見えるため、位相を独立させる
///    - アプリ起動ごとに違う「今日の空」に見える (毎回の第一印象を新鮮に保つ)
///
/// ## パフォーマンス
///
/// - 各 CloudLayerWidget は `WorldAnimatedLayerBase` 継承で App lifecycle 追従
///   (background 時 stop、resume 時 restart)
/// - `RepaintBoundary` は呼び出し側 (world_frame_section.dart) で wrap 済
/// - `FilterQuality.none` でピクセルアートのドット感を保つ (拡大縮小しない)
/// - Sway の math.sin 計算は `verticalSwayAmplitudePx != 0` の場合のみ実行 (defaults 影響ゼロ)
///
/// ## TUNABLE 定数
///
/// - [_kLayer1DurationSec] (30s): cloud_layer_3 (大雲、手前) 横断時間
/// - [_kLayer2DurationSec] (60s): cloud_layer_4 (小雲、遠く) 横断時間
/// - [_kSwayAmplitudePx] (1.5px): 両レイヤー共通の縦揺れ振幅 (要件 ±1〜2px 内)
/// - [_kLayer1SwayPeriodSec] (10s) / [_kLayer2SwayPeriodSec] (14s): 揺れ周期の差
///
/// ## アセット未配置時のフォールバック
///
/// CloudLayerWidget は errorBuilder で `SizedBox.shrink` にフォールバック
/// (画像が pubspec に未登録の場合や、後から差し替える PM ワークフローに対応)。
class MorningGrasslandBackground extends StatelessWidget {
  const MorningGrasslandBackground({super.key});

  // ── アセット path ────────────────────────────────────────────────────────
  // 【2026-07-05 更新 v2】PM が cloud_layer_3/4 に雲を再分配:
  //   cloud_layer_3.png = 4 個の大きめの雲、上部集中、輪郭はっきり
  //   cloud_layer_4.png = 6 個の小さめの雲、分散配置、控えめ
  // → 大雲群を「手前・速い」、小雲群を「遠く・遅い」レイヤーとして視差構成。
  static const String _kCloudLayerFrontAssetPath =
      'assets/images/backgrounds/world/cloud_layer_3.webp';  // 大雲、手前
  static const String _kCloudLayerBackAssetPath =
      'assets/images/backgrounds/world/cloud_layer_4.webp';  // 小雲、遠く

  // ── 横スクロール速度 (「気付くか気付かないか」の速度、要件 20〜60 秒) ─────
  static const double _kFrontDurationSec = 30.0;  // 手前は少し速い
  static const double _kBackDurationSec  = 60.0;  // 遠くはゆっくり

  // ── 縦 sin 波揺れ (要件 ±1〜2px、周期 8〜15 秒) ──────────────────────────
  static const double _kSwayAmplitudePx = 1.5;
  static const double _kFrontSwayPeriodSec = 10.0;  // 手前は少し短周期
  static const double _kBackSwayPeriodSec  = 14.0;  // 遠くは長周期 (ゆったり)

  // ── 雲画像の縮小率 (v4 で BoxFit.fitWidth に変更、scale は微調整用に) ────
  // 【2026-07-05 v4】cloudFit を BoxFit.cover → BoxFit.fitWidth に変更。
  // fitWidth は画像 aspect 比を保ち幅に合わせて表示するため、cover のような
  // 縦トリミングが起きず「vertical split」の視覚化を根本的に回避する。
  // fitWidth の時点で画像は既に compressed 表示されるため、imageScale は
  // 微調整用に控えめの値 (0.85 / 0.70) に緩和。差 0.15 で奥行き錯視は維持。
  static const double _kFrontCloudScale = 0.85;  // 手前 (v3 0.50、v4 では fitWidth 側で圧縮済)
  static const double _kBackCloudScale  = 0.70;  // 遠く (v3 0.35、v4 では fitWidth 側で圧縮済)

  // ── 縦シフト (雲を空エリアに寄せる) ──────────────────────────────────────
  // 目覚めの山頂シーンは山頂が下部にあるため、雲は画面上部に寄せる。
  // noon_castle_town と同値 (-0.30) を採用、視覚バランスの一貫性維持。
  static const double _kCloudVerticalShiftPct = -0.30;

  // ── 前景画像 path (人物レイヤーのみ) ──────────────────────────────────
  // world_sunrise_1.png: 人物 (最前景、雲より手前)
  //
  // 【v1 hotfix 2026-07-07】旧「朝の草原」の tree layer
  // (world_morning_grassland_2.png、木・草・岩) は「目覚めの山頂」シーンの
  // 景色構成 (山頂 = 樹木少なめ) に合わないため撤去。
  // world_sunrise_3.png は未接続 (将来レイヤー拡張用の予備)。
  //
  // 本画像は元 world_sunrise.png と**ピクセル一致** する前提。元絵の上に
  // ぴったり重なるため見た目は変わらないが、レイヤー順で雲が人物の背後に来る
  // 「自然な奥行き」を実現する。
  static const String _kForegroundCharacterAssetPath =
      'assets/images/backgrounds/world/world_sunrise_1.webp';

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── L1: 遠くの小雲群 (奥、cloud_layer_4.png、ゆっくり) ────────
          // 60 秒でゆっくり漂う。cloudFit: fitWidth で aspect 比を保ちながら
          // 幅に fit → 縦トリミングによる「vertical split」を回避。
          // imageScale=0.70 で さらに微縮小 = 遠景の錯視。
          CloudLayerWidget(
            assetPath: _kCloudLayerBackAssetPath,
            crossDurationSec: _kBackDurationSec,
            verticalShiftPct: _kCloudVerticalShiftPct,
            randomStartPhase: true,
            verticalSwayAmplitudePx: _kSwayAmplitudePx,
            verticalSwayPeriodSec: _kBackSwayPeriodSec,
            imageScale: _kBackCloudScale,
            cloudFit: BoxFit.fitWidth,
          ),
          // ── L2: 手前の大雲群 (cloud_layer_3.png、少し速い) ──────────────
          // 30 秒で速めに横切る。cloudFit: fitWidth + imageScale=0.85 で
          // L1 より一回り大きく = 「近い」錯視。sway 10s で別々の風感。
          CloudLayerWidget(
            assetPath: _kCloudLayerFrontAssetPath,
            crossDurationSec: _kFrontDurationSec,
            verticalShiftPct: _kCloudVerticalShiftPct,
            randomStartPhase: true,
            verticalSwayAmplitudePx: _kSwayAmplitudePx,
            verticalSwayPeriodSec: _kFrontSwayPeriodSec,
            imageScale: _kFrontCloudScale,
            cloudFit: BoxFit.fitWidth,
          ),
          // ── 前景キャラクター (最前景、雲より手前) ─────────────────────
          // world_sunrise_1.png は元絵の人物部分。雲より手前 = 人物と背景の
          // 間に雲が挟まる自然な立体感が完成。
          // 【v1 hotfix 2026-07-07】旧 tree layer (world_morning_grassland_2.png)
          // は「目覚めの山頂」シーンの景色に合わないため撤去。
          Image.asset(
            _kForegroundCharacterAssetPath,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.none,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
