import 'dart:math' as math;
import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// LightBeamOverlay
// ─────────────────────────────────────────────────────────────────────────────

/// 習慣達成時に画面全体に重ねる光パーティクルアニメーション。
///
/// [sourcePosition] : 習慣カード中心のグローバル座標
/// [targetPosition] : 額縁中心のグローバル座標
/// [onFrameReached] : パーティクルが額縁に到達したタイミングで呼ばれる
/// [onComplete]     : アニメーション完了後に呼ばれる（OverlayEntry 削除用）
class LightBeamOverlay extends StatefulWidget {
  const LightBeamOverlay({
    super.key,
    required this.sourcePosition,
    required this.targetPosition,
    required this.onFrameReached,
    required this.onComplete,
  });

  final Offset sourcePosition;
  final Offset targetPosition;
  final VoidCallback onFrameReached;
  final VoidCallback onComplete;

  @override
  State<LightBeamOverlay> createState() => _LightBeamOverlayState();
}

class _LightBeamOverlayState extends State<LightBeamOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final List<_Particle> _particles;
  final _rng = math.Random();
  bool _frameReachFired = false;
  bool _completeFired   = false;

  // パーティクルが額縁に「到達した」とみなす進捗率
  static const double _frameReachThreshold = 0.75;
  // アニメーション総時間
  static const int _durationMs = 750;
  // パーティクル数（多すぎると描画負荷増加）
  static const int _particleCount = 8;

  @override
  void initState() {
    super.initState();

    // パーティクル初期化（ランダム性を持たせてバラつきを演出）
    _particles = List.generate(_particleCount, (i) {
      return _Particle(
        startOffset: Offset(
          widget.sourcePosition.dx + (_rng.nextDouble() - 0.5) * 30,
          widget.sourcePosition.dy + (_rng.nextDouble() - 0.5) * 10,
        ),
        endOffset: Offset(
          widget.targetPosition.dx + (_rng.nextDouble() - 0.5) * 16,
          widget.targetPosition.dy + (_rng.nextDouble() - 0.5) * 8,
        ),
        // 最大 150ms のずれで順次出現
        delay: (i / _particleCount) * 0.20,
        radius: 3.0 + _rng.nextDouble() * 3.0,
        sineAmplitude: 7.0 + _rng.nextDouble() * 9.0,
        sineFrequency: 1.4 + _rng.nextDouble() * 1.0,
      );
    });

    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _durationMs),
    );

    _ctrl.addListener(_onTick);
    _ctrl.forward();
  }

  void _onTick() {
    // 額縁到達コールバック（1 回のみ）
    if (!_frameReachFired && _ctrl.value >= _frameReachThreshold) {
      _frameReachFired = true;
      widget.onFrameReached();
    }
    // 完了コールバック（1 回のみ）
    if (!_completeFired && _ctrl.status == AnimationStatus.completed) {
      _completeFired = true;
      widget.onComplete();
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onTick);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        painter: _LightParticlePainter(
          particles: _particles,
          progress: _ctrl.value,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// パーティクルデータクラス
// ─────────────────────────────────────────────────────────────────────────────

class _Particle {
  const _Particle({
    required this.startOffset,
    required this.endOffset,
    required this.delay,
    required this.radius,
    required this.sineAmplitude,
    required this.sineFrequency,
  });

  final Offset startOffset;
  final Offset endOffset;
  final double delay;          // 出現ディレイ（0.0〜0.20）
  final double radius;         // コア半径（px）
  final double sineAmplitude;  // 横揺れ幅（px）
  final double sineFrequency;  // 横揺れ周波数

  /// 進捗 t（0.0〜1.0）から現在の画面座標を計算する。
  /// - 遅延を差し引いた「実効進捗」で easeInCubic で加速
  /// - 横方向にサイン波の揺れを加え、ターゲット近くで収束させる
  Offset positionAt(double t) {
    final effectiveT = ((t - delay) / (1.0 - delay)).clamp(0.0, 1.0);
    if (effectiveT == 0.0) return startOffset;

    // easeInCubic: 出発時ゆっくり → 額縁へ加速
    final eased = const Cubic(0.55, 0.055, 0.675, 0.19).transform(effectiveT);

    final baseX = lerpDouble(startOffset.dx, endOffset.dx, eased)!;
    final baseY = lerpDouble(startOffset.dy, endOffset.dy, eased)!;

    // 横揺れ: 終点に近づくほど収束（1 - eased）
    final sway = math.sin(effectiveT * math.pi * sineFrequency)
        * sineAmplitude
        * (1.0 - eased);

    return Offset(baseX + sway, baseY);
  }

  /// 進捗 t でのアルファ値（0.0〜1.0）。
  /// フェードイン 15% → 維持 → フェードアウト 20%。
  double opacityAt(double t) {
    final effectiveT = ((t - delay) / (1.0 - delay)).clamp(0.0, 1.0);
    if (effectiveT < 0.15) return effectiveT / 0.15;
    if (effectiveT > 0.80) return (1.0 - effectiveT) / 0.20;
    return 1.0;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CustomPainter
// ─────────────────────────────────────────────────────────────────────────────

class _LightParticlePainter extends CustomPainter {
  const _LightParticlePainter({
    required this.particles,
    required this.progress,
  });

  final List<_Particle> particles;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      final pos     = p.positionAt(progress);
      final opacity = p.opacityAt(progress);
      if (opacity <= 0.01) continue;

      // ── 外側グロウ（ぼかし付き紫リング）──────────────────────────
      canvas.drawCircle(
        pos,
        p.radius * 2.8,
        Paint()
          ..color = AppTheme.primary.withValues(alpha: opacity * 0.22)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
      );

      // ── 中間白リング ─────────────────────────────────────────────
      canvas.drawCircle(
        pos,
        p.radius * 1.6,
        Paint()
          ..color = Colors.white.withValues(alpha: opacity * 0.45),
      );

      // ── 白コア ───────────────────────────────────────────────────
      canvas.drawCircle(
        pos,
        p.radius,
        Paint()
          ..color = Colors.white.withValues(alpha: opacity),
      );
    }
  }

  @override
  bool shouldRepaint(_LightParticlePainter old) => old.progress != progress;
}
