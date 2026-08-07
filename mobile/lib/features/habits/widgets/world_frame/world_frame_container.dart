import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 額縁コンテナ（glowIntensity / idleGlowValue でダイナミックに変化）
// ─────────────────────────────────────────────────────────────────────────────

/// アプリ世界観に合わせた「ピクセルアート窓枠 + 二重グロウ」スタイルの枠コンテナ。
///
/// - [glowIntensity]: 習慣達成時の瞬間グロウ（0.0〜1.0・最優先）
/// - [idleGlowValue]: アイドル時の呼吸グロウ（0.0〜1.0、1.5s 往復ループ）
///
/// 【FEAT-209】長押し演出廃止に伴い `pressValue` パラメータは削除済み。
/// 【FEAT-487 (2026-07-08)】旧 `world_frame_section.dart` 内 private class
/// `_FrameContainer` から public `WorldFrameContainer` に昇格。
class WorldFrameContainer extends StatelessWidget {
  const WorldFrameContainer({
    required this.child,
    required this.glowIntensity,
    this.idleGlowValue = 0.0,
    super.key,
  });

  final Widget child;
  final double glowIntensity;  // 0.0〜1.0（習慣達成グロウ・最優先）
  final double idleGlowValue;  // 0.0〜1.0（呼吸グロウ・通常時）

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(12);
    final hasActiveGlow = glowIntensity > 0.01;

    // ── アクティブグロウ（習慣達成時の派手な演出）──────────────
    // 【バッテリー消費対策】blur 上限を 55 → 30、外側 multiplier を 2.2 → 1.5 に削減。
    // BoxShadow の GPU コストは blurRadius² に比例して重くなるため、blur=55 から
    // blur=30 への縮小だけで約 1/3 のコスト削減が見込める。
    // アクティブグロウは短時間（600ms）の演出なので画質低下より省電力を優先。
    if (hasActiveGlow) {
      final glow = glowIntensity;
      final shadowBlur    = lerpDouble(16,   30,  glow)!;
      final shadowSpread  = lerpDouble(0,    6,   glow)!;
      final shadowOpacity = lerpDouble(0.22, 0.85, glow)!;
      final borderOpacity = lerpDouble(0.38, 1.0,  glow)!;
      // ボーダー幅: 静止時 1.8px → グロウ時 3.0px（重みが増す感覚）
      final borderWidth   = lerpDouble(1.8,  3.0,  glow)!;

      return Container(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: [
            // ── 内側タイトグロウ（枠に張り付いた鮮明な輝き）─────────
            BoxShadow(
              color:        AppTheme.primary.withValues(alpha: shadowOpacity),
              blurRadius:   shadowBlur,
              spreadRadius: shadowSpread,
            ),
            // ── 外側ワイドグロウ（遠くまで広がる柔らかい光・縮減版）──
            BoxShadow(
              color:        AppTheme.primary.withValues(alpha: shadowOpacity * 0.45),
              blurRadius:   shadowBlur * 1.5,
              spreadRadius: shadowSpread * 0.4,
            ),
            // ── 暗い内側シャドウ（コントラスト確保）───────────
            BoxShadow(
              color:        Colors.black.withValues(alpha: 0.50),
              blurRadius:   8,
              spreadRadius: -2,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: AppTheme.primary.withValues(alpha: borderOpacity),
                width: borderWidth,
              ),
              borderRadius: borderRadius,
            ),
            position: DecorationPosition.foreground,
            child: child,
          ),
        ),
      );
    }

    // ── アイドル（呼吸グロウのみ・GPU 軽量パス）────────────────
    // 【バッテリー消費対策】常時 60fps で発火するアイドル側は BoxShadow を極小に抑える。
    // blur 12〜18px は大きな blur と比べ GPU 負荷が桁違いに小さい。
    // 呼吸感は枠線 opacity の微妙な揺らぎで表現し、視覚的にも違和感は少ない。
    final shadowBlur    = lerpDouble(12,   18,  idleGlowValue)!;
    final shadowOpacity = lerpDouble(0.18, 0.32, idleGlowValue)!;
    final borderOpacity = lerpDouble(0.38, 0.58, idleGlowValue)!;

    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          // ── 呼吸グロウ（軽量・blur 18px 上限）────────────────
          BoxShadow(
            color:        AppTheme.primary.withValues(alpha: shadowOpacity),
            blurRadius:   shadowBlur,
            spreadRadius: 0,
          ),
          // ── 暗い内側シャドウ（コントラスト確保）───────────
          BoxShadow(
            color:        Colors.black.withValues(alpha: 0.50),
            blurRadius:   8,
            spreadRadius: -2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: AppTheme.primary.withValues(alpha: borderOpacity),
              width: 1.8,
            ),
            borderRadius: borderRadius,
          ),
          position: DecorationPosition.foreground,
          child: child,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// フォールバック表示（アセット未配置時）
// ─────────────────────────────────────────────────────────────────────────────

/// アセットファイルが存在しない場合のプレースホルダー。
/// リリース前の開発中でも画面が壊れないよう、グラデーション背景を表示する。
///
/// 【FEAT-487 (2026-07-08)】旧 `world_frame_section.dart` 内 private
/// `_WorldFramePlaceholder` を public 化 (Image.asset errorBuilder から
/// 別 file 参照が必要になったため)。
class WorldFramePlaceholder extends StatelessWidget {
  const WorldFramePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      // BUG-12: アプリ背景 (#1E1E2E) と区別できる明るさに調整。
      // AppTheme.card (#2A2A3E) はカードと同じ色なので「意図的なボックス」として認識される。
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.card,                              // #2A2A3E — アプリ背景より明るい
            AppTheme.surface.withValues(alpha: 0.95),   // #1E1E2E — 微妙な深さで奥行き感
          ],
        ),
        // 内側からの淡い primary グロウで「世界が準備中」感を演出
        boxShadow: const [
          BoxShadow(
            color: Color(0x22534AB7), // AppTheme.primary の約 13% 透明
            blurRadius:  30,
            spreadRadius: -5,
          ),
        ],
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.landscape_outlined,
              // alpha 0.3 → 0.55 に引き上げて視認性を確保
              color: AppTheme.primary.withValues(alpha: 0.55),
              size: 44,
            ),
            const SizedBox(height: 8),
            Text(
              'preparing world...',
              style: TextStyle(
                color:        Colors.white.withValues(alpha: 0.20),
                fontSize:     9,
                letterSpacing: 2.0,
                fontFamily:   'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
