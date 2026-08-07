import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../world_animated_layer_base.dart';

/// 【新規 (2026-06-25)】ホタルパーティクルシステム (L5)。
///
/// [Gemini 指示]:
///   - 数匹を背景に飛ばす (5 匹採用)
///   - 「止まる → 少し移動 → 止まる」を繰り返す (state machine)
///   - 移動は sin 波でゆっくり揺れる
///   - 明るさは 0.5-1.0 で点滅
///   - 同じタイミングで点滅させない (個別位相 seed)
///
/// 実装:
///   - 単一 `Ticker` で全ホタルを駆動 (`AnimationController` 5 個生成回避)
///   - 各ホタルは `_FireflyState` に「idle (3-5s) / drift (2-3s)」フェーズ
///   - 点滅は `sin(elapsed/period + phase)` で個別位相
class FireflyParticleSystem extends WorldAnimatedLayerBase {
  const FireflyParticleSystem({super.key});

  @override
  State<FireflyParticleSystem> createState() => _FireflyParticleSystemState();
}

class _FireflyParticleSystemState
    extends WorldAnimatedLayerBaseState<FireflyParticleSystem> {
  static const int _kFireflyCount = 5;

  late final List<_Firefly> _fireflies;
  late final Ticker _ticker;
  final ValueNotifier<int> _frameNotifier = ValueNotifier<int>(0);
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    final rng = Random(42);
    _fireflies = List.generate(_kFireflyCount, (i) {
      // 初期配置: 背景全域 (alignment -0.8..+0.8、Y は -0.1..+0.5)
      final x = (rng.nextDouble() * 1.6) - 0.8;
      final y = (rng.nextDouble() * 0.6) - 0.1;
      return _Firefly(
        x: x,
        y: y,
        // 点滅位相を個別に分散 (同期回避)
        blinkPhase: rng.nextDouble() * pi * 2,
        // 点滅周期 (1.5-3.0 秒)
        blinkPeriodMs: 1500 + rng.nextInt(1500),
        // 開始フェーズ: idle、duration 3-5s
        phase: _FireflyPhase.idle,
        phaseDurationMs: 3000 + rng.nextInt(2000),
        rng: Random(rng.nextInt(1 << 30)),
      );
    });
    _ticker = createTicker(_onTick);
    _ticker.start();
  }

  @override
  void pauseAnimations() {
    if (_ticker.isActive) _ticker.stop();
  }

  @override
  void resumeAnimations() {
    if (!_ticker.isActive && mounted) _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frameNotifier.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dtMs = (elapsed - _lastTick).inMilliseconds;
    _lastTick = elapsed;
    if (dtMs <= 0) return;
    for (final f in _fireflies) {
      f.update(dtMs, elapsed.inMilliseconds);
    }
    _frameNotifier.value = _frameNotifier.value + 1;
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _FirefliesPainter(
        fireflies: _fireflies,
        repaint: _frameNotifier,
      ),
      size: Size.infinite,
    );
  }
}

/// ホタルのフェーズ。
enum _FireflyPhase {
  /// 止まっている状態 (動かない、明滅は継続)。
  idle,

  /// ゆっくり sin 波で揺れて移動する状態。
  drift,
}

class _Firefly {
  _Firefly({
    required this.x,
    required this.y,
    required this.blinkPhase,
    required this.blinkPeriodMs,
    required this.phase,
    required this.phaseDurationMs,
    required this.rng,
  })  : _phaseElapsedMs = 0,
        _baseX = x,
        _baseY = y,
        _driftTargetDX = 0,
        _driftTargetDY = 0;

  /// 現在の位置 (alignment -1..+1)。
  double x;
  double y;

  /// 点滅位相 seed (個別ずらし用)。
  final double blinkPhase;

  /// 点滅周期 (ms)。
  final int blinkPeriodMs;

  /// 現在のフェーズ。
  _FireflyPhase phase;

  /// このフェーズの予定継続時間 (ms)。
  int phaseDurationMs;

  /// このフェーズの経過時間 (ms)。
  double _phaseElapsedMs;

  /// drift 開始時の基準位置 (戻り点として使用しない、参考)。
  double _baseX;
  double _baseY;

  /// drift 中の目標方向 (sin 波の振幅方向、alignment 単位)。
  double _driftTargetDX;
  double _driftTargetDY;

  /// 個別 RNG (フェーズ再開時に乱数決定)。
  final Random rng;

  void update(int dtMs, int totalElapsedMs) {
    _phaseElapsedMs += dtMs;

    if (_phaseElapsedMs >= phaseDurationMs) {
      // フェーズ切替
      if (phase == _FireflyPhase.idle) {
        // idle → drift: 移動方向と振幅を決定 (2-3 秒)
        phase = _FireflyPhase.drift;
        phaseDurationMs = 2000 + rng.nextInt(1000);
        _baseX = x;
        _baseY = y;
        _driftTargetDX = (rng.nextDouble() - 0.5) * 0.12;
        _driftTargetDY = (rng.nextDouble() - 0.5) * 0.06;
      } else {
        // drift → idle: 3-5 秒静止
        phase = _FireflyPhase.idle;
        phaseDurationMs = 3000 + rng.nextInt(2000);
      }
      _phaseElapsedMs = 0;
    }

    if (phase == _FireflyPhase.drift) {
      // sin 波でゆっくり揺れる移動
      final progress = _phaseElapsedMs / phaseDurationMs;
      // 0..1 を sin(0..pi) でなめらかに 0→1→0 に
      final t = sin(progress * pi);
      x = _baseX + _driftTargetDX * t;
      y = _baseY + _driftTargetDY * t;
    }
  }

  /// 現在の明るさ (0.5-1.0、点滅)。
  double brightnessAt(int totalElapsedMs) {
    // sin で 0.5-1.0 を循環、位相 seed で個別ずらし
    final phaseSec = totalElapsedMs / blinkPeriodMs;
    final v = sin(phaseSec * pi * 2 + blinkPhase);
    return 0.75 + v * 0.25;  // 0.5..1.0
  }
}

class _FirefliesPainter extends CustomPainter {
  _FirefliesPainter({
    required this.fireflies,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<_Firefly> fireflies;

  static final Paint _paint = Paint()..isAntiAlias = true;
  static final Paint _glowPaint = Paint()..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final elapsed = DateTime.now().millisecondsSinceEpoch;
    for (final f in fireflies) {
      final cx = (f.x + 1) * 0.5 * w;
      final cy = (f.y + 1) * 0.5 * h;
      final brightness = f.brightnessAt(elapsed).clamp(0.5, 1.0);
      // 外側 glow (ぼかし代わり)
      _glowPaint.color =
          const Color(0xFFAAFF44).withValues(alpha: brightness * 0.35);
      canvas.drawCircle(Offset(cx, cy), 5, _glowPaint);
      // 中心点 (本体)
      _paint.color =
          const Color(0xFFAAFF44).withValues(alpha: brightness * 0.95);
      canvas.drawCircle(Offset(cx, cy), 2, _paint);
    }
  }

  @override
  bool shouldRepaint(covariant _FirefliesPainter old) => true;
}
