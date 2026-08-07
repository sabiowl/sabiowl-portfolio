import 'dart:math';

import 'package:flutter/material.dart';

import '../world_animated_layer_base.dart';

/// 【新規 (2026-06-25)】焚火の光ウィジェット (L3)。
///
/// [Gemini 指示] 3 種類の光を非同期にランダム揺らぎで重ねる:
///   1. 中央光: 焚火位置を中心にした暖色 RadialGradient (Opacity 0.80-1.00)
///   2. テント反射光: 入口 + 右側布のみ (Opacity 0.75-1.00、別位相)
///   3. 地面反射光: 焚火周辺の地面 (別位相、独立揺らぎ)
///
/// 各光は周期 150-350ms のランダム間隔で Opacity を 0.80-1.00 (テント /
/// 地面は 0.75-1.00) 間で補間。完全な周期運動にはしない (各々独立 seed)。
///
/// 実装: 3 つの `AnimationController` を独立周期で循環。
/// `addStatusListener` で `forward 完了` のたびに次の duration / target を
/// ランダムに再設定し、`Tween` を差し替える方式。
class FireLightWidget extends WorldAnimatedLayerBase {
  const FireLightWidget({super.key});

  @override
  State<FireLightWidget> createState() => _FireLightWidgetState();
}

class _FireLightWidgetState
    extends WorldAnimatedLayerBaseState<FireLightWidget> {
  // ── 焚火位置 (FireWidget._kFirePosition と同期、TUNABLE) ──────────────
  // 【更新 (2026-07-18 #10)】FireWidget._kFirePosition と同期して 0.80 → 0.95。
  static const Alignment _kFireCenter = Alignment(0.19, 0.68);

  // ── テント反射光: 入口 + 右側布の 2 領域 (TUNABLE) ────────────────────
  // 【TODO (2026-07-18)】bg PNG 差替え時に tent 位置が変わっている可能性あり。
  // 旧 bg (x_pct ≈ 0.32, y_pct ≈ 0.70) 用の値のまま保持。実機で目視確認して
  // 必要なら再調整する。
  static const Alignment _kTentEntrance = Alignment(-0.40, 0.40);
  static const Alignment _kTentRightCloth = Alignment(-0.24, 0.30);

  // ── 地面反射光: 焚火直下 (薪 + その下の地面) ──────────────────────────
  // 【更新 (2026-07-18 #2)】焚火 y=0.80 に合わせて地面反射も下方向へ、下端付近。
  static const Alignment _kGroundCenter = Alignment(0.05, 0.98);

  // ── 3 つの独立揺らぎ controller ──────────────────────────────────────
  late final _RandomFlicker _centerFlicker;
  late final _RandomFlicker _tentFlicker;
  late final _RandomFlicker _groundFlicker;

  @override
  void initState() {
    super.initState();
    _centerFlicker = _RandomFlicker(
      vsync: this,
      minOpacity: 0.80,
      maxOpacity: 1.00,
      minPeriodMs: 150,
      maxPeriodMs: 350,
      seed: 11,
    );
    _tentFlicker = _RandomFlicker(
      vsync: this,
      minOpacity: 0.75,
      maxOpacity: 1.00,
      minPeriodMs: 200,
      maxPeriodMs: 400,
      seed: 27,
    );
    _groundFlicker = _RandomFlicker(
      vsync: this,
      minOpacity: 0.70,
      maxOpacity: 1.00,
      minPeriodMs: 220,
      maxPeriodMs: 420,
      seed: 53,
    );
  }

  @override
  void pauseAnimations() {
    _centerFlicker.pause();
    _tentFlicker.pause();
    _groundFlicker.pause();
  }

  @override
  void resumeAnimations() {
    _centerFlicker.resume();
    _tentFlicker.resume();
    _groundFlicker.resume();
  }

  @override
  void dispose() {
    _centerFlicker.dispose();
    _tentFlicker.dispose();
    _groundFlicker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // ── 中央光 (焚火周辺の暖色グラデーション) ──────────────────────
        // 【修正 v4 (2026-06-25)】sprite 60×75 + 周囲の暗闇を照らす広さで
        // 150×120 採用。焚火 sprite を包んで自然に周辺へ減衰する。
        // 【更新 (2026-07-18 #3)】sprite 55×92 拡大に追随して 100×80 → 130×110
        // にサイズ更新。alpha は減光済 (0xAA) をキープ。
        AnimatedBuilder(
          animation: _centerFlicker,
          builder: (_, __) => Align(
            alignment: _kFireCenter,
            child: Opacity(
              opacity: _centerFlicker.value,
              child: CustomPaint(
                size: const Size(130, 110),
                painter: const _RadialGlowPainter(
                  innerColor: Color(0xAAFFAA44),  // 暖色オレンジ (中心)
                  outerColor: Color(0x00FF6622),  // 透明
                ),
              ),
            ),
          ),
        ),
        // ── テント反射光: 入口 ──────────────────────────────────────
        AnimatedBuilder(
          animation: _tentFlicker,
          builder: (_, __) => Align(
            alignment: _kTentEntrance,
            child: Opacity(
              opacity: _tentFlicker.value,
              child: CustomPaint(
                size: const Size(40, 28),
                painter: const _RadialGlowPainter(
                  innerColor: Color(0x66FFAA66),
                  outerColor: Color(0x00FFAA66),
                ),
              ),
            ),
          ),
        ),
        // ── テント反射光: 右側布 ────────────────────────────────────
        AnimatedBuilder(
          animation: _tentFlicker,
          builder: (_, __) => Align(
            alignment: _kTentRightCloth,
            child: Opacity(
              opacity: _tentFlicker.value * 0.85,  // 入口より控えめ
              child: CustomPaint(
                size: const Size(28, 24),
                painter: const _RadialGlowPainter(
                  innerColor: Color(0x55FFBB77),
                  outerColor: Color(0x00FFBB77),
                ),
              ),
            ),
          ),
        ),
        // ── 地面反射光 ─────────────────────────────────────────────
        // 【更新 (2026-07-18)】焚火 40×54 縮小 + y=0.80 下配置に追随して
        // サイズ縮小 (140×40 → 90×26)。
        AnimatedBuilder(
          animation: _groundFlicker,
          builder: (_, __) => Align(
            alignment: _kGroundCenter,
            child: Opacity(
              opacity: _groundFlicker.value * 0.6,  // 地面はやや弱め
              child: CustomPaint(
                size: const Size(90, 26),
                painter: const _RadialGlowPainter(
                  innerColor: Color(0x44FF9933),
                  outerColor: Color(0x00FF9933),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// ランダム周期 + ランダム振幅で 0.0..1.0 を循環するヘルパー。
///
/// `AnimationController.forward` 完了のたびに次の `duration` と `target` を
/// 再設定することで「完全な周期運動にしない」要件を満たす。
class _RandomFlicker extends ChangeNotifier {
  _RandomFlicker({
    required TickerProvider vsync,
    required this.minOpacity,
    required this.maxOpacity,
    required this.minPeriodMs,
    required this.maxPeriodMs,
    required int seed,
  }) : _rng = Random(seed) {
    _ctrl = AnimationController(vsync: vsync);
    _value = _rng.nextDouble() * (maxOpacity - minOpacity) + minOpacity;
    _ctrl.addListener(_onTick);
    _ctrl.addStatusListener(_onStatus);
    _scheduleNext();
  }

  final double minOpacity;
  final double maxOpacity;
  final int minPeriodMs;
  final int maxPeriodMs;
  final Random _rng;

  late final AnimationController _ctrl;
  double _value = 1.0;
  double _startValue = 1.0;
  double _targetValue = 1.0;
  bool _paused = false;
  bool _disposed = false;

  double get value => _value;

  void _scheduleNext() {
    if (_disposed || _paused) return;
    _startValue = _value;
    _targetValue =
        minOpacity + _rng.nextDouble() * (maxOpacity - minOpacity);
    _ctrl.duration = Duration(
      milliseconds: minPeriodMs + _rng.nextInt(maxPeriodMs - minPeriodMs),
    );
    _ctrl.forward(from: 0.0);
  }

  void _onTick() {
    _value = _startValue + (_targetValue - _startValue) * _ctrl.value;
    notifyListeners();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _scheduleNext();
    }
  }

  void pause() {
    _paused = true;
    _ctrl.stop();
  }

  void resume() {
    if (_paused && !_disposed) {
      _paused = false;
      _scheduleNext();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ctrl.removeListener(_onTick);
    _ctrl.removeStatusListener(_onStatus);
    _ctrl.dispose();
    super.dispose();
  }
}

class _RadialGlowPainter extends CustomPainter {
  const _RadialGlowPainter({
    required this.innerColor,
    required this.outerColor,
  });

  final Color innerColor;
  final Color outerColor;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width.clamp(size.height, double.infinity) / 2;
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [innerColor, outerColor],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));
    canvas.drawOval(Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant _RadialGlowPainter old) =>
      old.innerColor != innerColor || old.outerColor != outerColor;
}
