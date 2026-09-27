import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 【新規 (2026-06-26)】撃墜エフェクト overlay (スマブラ風)。
///
/// `BattleState.ultimateHitEvent` が non-null になった瞬間、battle_page から
/// `controller.fire()` で起動。350ms かけて以下を **同一フレーム開始** で同期再生:
///
/// - **0-180ms**: 画面シェイク (横振 ±10px、減衰) + ホワイトフラッシュ (0→0.6→0)
///                + 爆発リング (0→1.4x スケール拡大 + opacity 1.0→0)
/// - **180-350ms**: フェードアウト余韻 (シェイク弱まり + リング消失)
///
/// 画面シェイクは Stack 外側の `Transform.translate` で実現するため、本 widget
/// は children を受け取って wrap する高層 layer として battle_page の Scaffold
/// body 直下に配置する。
///
/// ## ハプティクスとの同期
///
/// 本 overlay の `controller.fire()` 呼び出しと同フレームで
/// `BattleHapticsService.instance.playUltimateHit()` を呼ぶことで、視覚演出と
/// 振動が同時開始される (caller 側で fire-and-forget)。
/// ホワイトフラッシュ layer の識別子 (テスト用)。
const Key ultimateHitFlashKey = ValueKey('ultimate_hit_flash');

class UltimateHitEffectController {
  UltimateHitEffectController();

  _UltimateHitEffectOverlayState? _state;

  /// 撃墜エフェクトを起動。caller は battle_page の ref.listen 内で同時に
  /// [BattleHapticsService.playUltimateHit] も呼ぶこと (同一フレーム開始)。
  void fire() {
    _state?._fire();
  }

  /// 再生中かどうか (テスト / デバッグ用)。
  ///
  /// 🔴 とどめが必殺技だったときに**これが true になってはいけない** ——
  /// 白フラッシュが KO 演出を覆い隠す (battle_page の発火ガード参照)。
  bool get isPlaying => _state?._isPlaying ?? false;

  void _attach(_UltimateHitEffectOverlayState state) {
    _state = state;
  }

  void _detach(_UltimateHitEffectOverlayState state) {
    if (_state == state) _state = null;
  }
}

class UltimateHitEffectOverlay extends StatefulWidget {
  const UltimateHitEffectOverlay({
    super.key,
    required this.controller,
    required this.child,
  });

  final UltimateHitEffectController controller;
  final Widget child;

  @override
  State<UltimateHitEffectOverlay> createState() =>
      _UltimateHitEffectOverlayState();
}

class _UltimateHitEffectOverlayState extends State<UltimateHitEffectOverlay>
    with SingleTickerProviderStateMixin {
  // 全エフェクト合計時間 (ハプティクス余韻と整合: 350ms)
  static const Duration _kDuration = Duration(milliseconds: 350);

  late final AnimationController _ctrl;
  final math.Random _rng = math.Random();

  // シェイク用ランダム seed (発火毎に変えて方向多様化)
  double _shakeSeed = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _kDuration);
    widget.controller._attach(this);
  }

  @override
  void didUpdateWidget(covariant UltimateHitEffectOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._detach(this);
      widget.controller._attach(this);
    }
  }

  @override
  void dispose() {
    widget.controller._detach(this);
    _ctrl.dispose();
    super.dispose();
  }

  void _fire() {
    if (!mounted) return;
    _shakeSeed = _rng.nextDouble() * math.pi * 2;
    _ctrl.forward(from: 0.0);
  }

  /// 再生中か。`_ctrl` の進行状態がそのまま真実値。
  bool get _isPlaying =>
      _ctrl.status == AnimationStatus.forward ||
      (_ctrl.value > 0 && _ctrl.value < 1);

  /// 画面シェイク offset (横振 ±10px、減衰 sin)。
  Offset _shakeOffset(double progress) {
    if (progress <= 0 || progress >= 1) return Offset.zero;
    // 最初の 60% で強くシェイク、残り 40% で減衰
    final amplitude = progress < 0.6
        ? 10.0 * (1.0 - progress / 0.6)
        : 0.0;
    final dx = math.sin(progress * 30 + _shakeSeed) * amplitude;
    final dy = math.cos(progress * 25 + _shakeSeed) * (amplitude * 0.4);
    return Offset(dx, dy);
  }

  /// ホワイトフラッシュ opacity (0→0.6→0、最初の 180ms にピーク)。
  double _flashOpacity(double progress) {
    if (progress >= 0.5) return 0.0;
    if (progress < 0.15) {
      // 0 → 0.6 (急上昇)
      return (progress / 0.15) * 0.6;
    } else {
      // 0.6 → 0 (なだらかに減衰、0.15→0.5)
      return 0.6 * (1.0 - (progress - 0.15) / 0.35);
    }
  }

  /// 爆発リング progress (0.0→1.4 スケール、opacity 1→0)。
  ({double scale, double opacity}) _ringParams(double progress) {
    if (progress >= 0.7) return (scale: 0, opacity: 0);
    final t = progress / 0.7;  // 0..1 over first 70% of duration
    final scale = 0.3 + t * 1.1;  // 0.3 → 1.4
    final opacity = (1.0 - t).clamp(0.0, 1.0);
    return (scale: scale, opacity: opacity);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      child: widget.child,
      builder: (context, child) {
        final progress = _ctrl.value;
        final isActive = _ctrl.status == AnimationStatus.forward ||
            (_ctrl.status == AnimationStatus.completed && progress < 1.0);

        // 非発火時は children だけ素通し (overhead ゼロ)
        if (progress == 0 && !isActive) {
          return child!;
        }

        final shake = _shakeOffset(progress);
        final flash = _flashOpacity(progress);
        final ring = _ringParams(progress);

        return Stack(
          fit: StackFit.expand,
          children: [
            // L1: シェイクされる元コンテンツ
            Transform.translate(
              offset: shake,
              child: child,
            ),
            // L2: ホワイトフラッシュ overlay
            //
            // 🔴 key は**テストの識別子**。画面には他にも白い Container が居る
            // (ゲージ背景など) ので、色で探すと誤検出する。
            // `ko_gate_battle_page_test.dart` が「とどめが必殺のときは出ない」
            // を縛っている。
            if (flash > 0)
              IgnorePointer(
                child: Container(
                  key: ultimateHitFlashKey,
                  color: Colors.white.withValues(alpha: flash),
                ),
              ),
            // L3: 爆発リング (中央に放射状)
            if (ring.opacity > 0)
              IgnorePointer(
                child: Center(
                  child: Transform.scale(
                    scale: ring.scale,
                    child: Opacity(
                      opacity: ring.opacity,
                      child: CustomPaint(
                        size: const Size(240, 240),
                        painter: ExplosionRingPainter(),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 爆発リング描画 (オレンジ → 黄 → 透明 のグラデーション + 外周ライン)。
///
/// 【FEAT-526 (2026-08-21)】KO 演出でも同じ絵を使うため public に変更した
/// (旧 `_ExplosionRingPainter`)。**インパクトの見た目を 2 箇所で二重管理しない。**
class ExplosionRingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.shortestSide / 2;

    // 1. 中心の radial glow (オレンジから透明)
    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFFFFE066).withValues(alpha: 0.9),  // 中心: 明るい黄
          const Color(0xFFFF8800).withValues(alpha: 0.6),  // 中間: オレンジ
          const Color(0xFFFF4400).withValues(alpha: 0.0),  // 外: 透明
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: maxRadius));
    canvas.drawCircle(center, maxRadius, glowPaint);

    // 2. 外周リング (オレンジの輪郭、衝撃波感)
    final ringPaint = Paint()
      ..color = const Color(0xFFFFAA33).withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0;
    canvas.drawCircle(center, maxRadius * 0.85, ringPaint);

    // 3. 内側リング (より細い、白っぽい)
    final innerRingPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, maxRadius * 0.55, innerRingPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
