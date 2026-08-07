import 'package:flutter/material.dart';

import '../world_animated_layer_base.dart';
import 'fire_widget.dart';
import 'fire_light_widget.dart';
import 'firefly_particle_system.dart';
import 'spark_particle_system.dart';

/// 【新規 (2026-06-25)】森のキャンプシーン: 静止/動的の切替フラグ。
///
/// - `false` (default): 背景に `world_night_forest_camp_org.png` (焚火付き元画像)
///   を使い、アニメーションレイヤーは描画しない (= 現状維持の静止画体験)。
/// - `true`: 背景に `world_night_forest_camp.png` (焚火除去版) を使い、
///   本 [CampScene] が L2-L5 (焚火スプライト / 光 / 火の粉 / ホタル) を重ねる。
///
/// 開発中の比較確認用フラグ。リリース時の最終判断後に削除する想定で、
/// 真実値は本ファイル 1 箇所に集約 ([world_frame_section] も本 const を参照)。
///
/// 注: hot restart が必要 (const のためコンパイル時定数)。
const bool kCampSceneAnimated = true;

/// 【新規 (2026-06-25)】森のキャンプシーン統括コンテナ。
///
/// [Gemini world_frame_camp.md] のレイヤー構成に従い、以下を IgnorePointer +
/// Stack で重ねる:
///   - L2 [FireWidget]: fire_sheet.png 8 フレーム 10FPS ループ
///   - L3 [FireLightWidget]: 焚火周辺の暖色光 (中心 + テント反射 + 地面反射)
///   - L4 [SparkParticleSystem]: 火の粉パーティクル
///   - L5 [FireflyParticleSystem]: ホタル (止-動-止 + 非同期点滅)
///
/// L1 (背景画像) は親 [world_frame_section] が `Image.asset` で描画するため、
/// 本ウィジェットでは透明レイヤーとして L2-L5 のみ統合する。
///
/// パフォーマンス:
///   - 各子ウィジェットは `WorldAnimatedLayerBase` を継承し、`App lifecycle`
///     で個別に pause/resume を管理 ([Gemini] パフォーマンス要件)
///   - 親 [world_frame_section] が `RepaintBoundary` で wrap 済のため、
///     本 Stack 内の再描画はホーム ListView へ波及しない (既存設計継承)
class CampScene extends WorldAnimatedLayerBase {
  const CampScene({super.key});

  @override
  State<CampScene> createState() => _CampSceneState();
}

class _CampSceneState extends WorldAnimatedLayerBaseState<CampScene> {
  // 親 CampScene 自体は AnimationController を持たない (子ウィジェットが各自管理)。
  // 親レベルの lifecycle ガードは子側 (WorldAnimatedLayerBase 継承) で十分。
  @override
  void pauseAnimations() {
    // 子ウィジェットが各自で lifecycle observer を持つため、ここでは no-op。
  }

  @override
  void resumeAnimations() {
    // 同上、no-op。
  }

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // L2 焚火 (背景の焚火位置に 8 frame アニメ)
          FireWidget(),
          // L3 焚火の光 (中心 + テント反射 + 地面反射、非同期ランダム揺らぎ)
          FireLightWidget(),
          // L4 火の粉 (1-3 個/秒、上昇 + 透明化)
          SparkParticleSystem(),
          // L5 ホタル (止-動-止、非同期点滅)
          FireflyParticleSystem(),
        ],
      ),
    );
  }
}
