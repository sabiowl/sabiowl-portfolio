import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../world_animated_layer_base.dart';

/// 【新規 (2026-06-25)】火の粉パーティクルシステム (L4)。
///
/// [Gemini 指示]:
///   - 1〜3 個/秒生成 (= 平均生成間隔 333-1000ms ランダム)
///   - 焚火位置から生成
///   - 少し左右へ揺れる
///   - 上方向へ移動
///   - 1.5〜2.5 秒で消える (徐々に透明化)
///   - サイズ 1〜3px ランダム
///
/// 実装:
///   - `Ticker` (60fps) で全パーティクルの位置/透明度を更新
///   - 生成は次回生成時刻 (前回 + 333-1000ms ランダム) を超えたとき発火
///   - `ValueNotifier<int>` を `CustomPainter.repaint` に渡すことで
///     `setState` 経路を回避し、`RepaintBoundary` 内に再描画を閉じ込める
class SparkParticleSystem extends WorldAnimatedLayerBase {
  const SparkParticleSystem({super.key});

  @override
  State<SparkParticleSystem> createState() => _SparkParticleSystemState();
}

class _SparkParticleSystemState
    extends WorldAnimatedLayerBaseState<SparkParticleSystem> {
  // ── 焚火生成位置 (FireWidget._kFirePosition と同期、TUNABLE) ──────────
  // 【更新 (2026-07-18 #10)】炎中心を y=0.95 に下方シフトしたため、火の粉
  // 起点 (sprite 上端) も y=0.62 相当に下方シフト。
  static const Alignment _kFireOrigin = Alignment(0.19, 0.35);

  // ── ランダム性 ───────────────────────────────────────────────────────
  final Random _rng = Random(7);

  // ── パーティクル一覧 ─────────────────────────────────────────────────
  final List<_Spark> _sparks = [];

  // ── Ticker + repaint trigger ────────────────────────────────────────
  late final Ticker _ticker;
  final ValueNotifier<int> _frameNotifier = ValueNotifier<int>(0);
  Duration _lastTick = Duration.zero;
  Duration _nextSpawn = Duration.zero;

  @override
  void initState() {
    super.initState();
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
    _sparks.clear();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dtMs = (elapsed - _lastTick).inMilliseconds;
    _lastTick = elapsed;
    if (dtMs <= 0) return;
    final dt = dtMs / 1000.0;

    // ── パーティクル生成判定 ────────────────────────────────────────
    if (elapsed >= _nextSpawn) {
      _spawn();
      // 次の生成間隔 333-1000ms (= 1-3 個/秒)
      final intervalMs = 333 + _rng.nextInt(667);
      _nextSpawn = elapsed + Duration(milliseconds: intervalMs);
    }

    // ── 既存パーティクル更新 + 死亡判定 ──────────────────────────
    _sparks.removeWhere((s) => s.update(dt));

    // ── 再描画トリガー (setState を呼ばずに CustomPaint だけ repaint) ──
    _frameNotifier.value = _frameNotifier.value + 1;
  }

  void _spawn() {
    _sparks.add(_Spark(
      // 開始位置: 焚火 alignment ± 微小バラツキ
      ax: _kFireOrigin.x + (_rng.nextDouble() - 0.5) * 0.05,
      ay: _kFireOrigin.y - 0.02,  // 焚火の少し上から
      // 速度: 上方向 + 左右微小揺れ (alignment 単位/秒)
      vx: (_rng.nextDouble() - 0.5) * 0.08,
      vy: -(0.10 + _rng.nextDouble() * 0.10),
      // サイズ 1-3 px
      sizePx: 1.0 + _rng.nextDouble() * 2.0,
      // 寿命 1500-2500 ms
      lifetimeMs: 1500 + _rng.nextInt(1000),
      // 左右揺れの位相 seed
      swayPhase: _rng.nextDouble() * pi * 2,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SparksPainter(
        sparks: _sparks,
        repaint: _frameNotifier,
      ),
      size: Size.infinite,
    );
  }
}

class _Spark {
  _Spark({
    required this.ax,
    required this.ay,
    required this.vx,
    required this.vy,
    required this.sizePx,
    required this.lifetimeMs,
    required this.swayPhase,
  });

  /// 位置 (Alignment x/y、-1..+1 系)。
  double ax;
  double ay;
  /// 速度 (alignment 単位/秒)。
  double vx;
  final double vy;
  /// 表示サイズ (px)。
  final double sizePx;
  /// 寿命 (ms)。
  final int lifetimeMs;
  /// 経過時間 (ms)。
  double ageMs = 0;
  /// 左右揺れの位相 seed。
  final double swayPhase;

  /// 現在の透明度 (1.0 → 0.0、線形フェード)。
  double get opacity =>
      (1.0 - ageMs / lifetimeMs).clamp(0.0, 1.0);

  /// 更新 (true = 死亡で除去要請)。
  bool update(double dt) {
    ageMs += dt * 1000;
    if (ageMs >= lifetimeMs) return true;
    // 上昇 + sin 波で微小左右揺れ
    ax += vx * dt;
    ay += vy * dt;
    // 揺れの追加 (時間で sin)
    ax += sin(ageMs / 200.0 + swayPhase) * 0.003;
    return false;
  }
}

class _SparksPainter extends CustomPainter {
  _SparksPainter({
    required this.sparks,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<_Spark> sparks;

  static final Paint _paint = Paint()
    ..color = const Color(0xFFFFCC66)
    ..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    if (sparks.isEmpty) return;
    final w = size.width;
    final h = size.height;
    for (final s in sparks) {
      // alignment -1..+1 を pixel 座標に変換
      final cx = (s.ax + 1) * 0.5 * w;
      final cy = (s.ay + 1) * 0.5 * h;
      _paint.color = const Color(0xFFFFCC66).withValues(alpha: s.opacity);
      canvas.drawCircle(Offset(cx, cy), s.sizePx, _paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SparksPainter old) => true;
}
