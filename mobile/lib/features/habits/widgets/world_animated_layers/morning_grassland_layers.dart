import 'dart:math';
import 'package:flutter/material.dart';
import 'world_animated_layer_base.dart';

/// 🌅 朝焼けの草原: 3 羽の小鳥 silhouette が右上から左上へ滑空 (10s ループ)。
class MorningGrasslandLayers extends WorldAnimatedLayerBase {
  const MorningGrasslandLayers({super.key});
  @override
  State<MorningGrasslandLayers> createState() => _MorningGrasslandLayersState();
}

class _MorningGrasslandLayersState
    extends WorldAnimatedLayerBaseState<MorningGrasslandLayers> {
  final List<AnimationController> _ctrls = [];
  final List<Animation<double>> _anims = [];

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < 3; i++) {
      final ctrl = AnimationController(
        vsync: this,
        duration: Duration(milliseconds: 9000 + i * 1200),
      );
      final anim = Tween<double>(begin: 0, end: 1).animate(
        CurvedAnimation(parent: ctrl, curve: Curves.linear),
      );
      _ctrls.add(ctrl);
      _anims.add(anim);
      // 各鳥に位相差を与えて自然な群れに見せる
      Future.delayed(Duration(milliseconds: i * 2500), () {
        if (mounted) ctrl.repeat();
      });
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void pauseAnimations() {
    for (final c in _ctrls) {
      c.stop();
    }
  }

  @override
  void resumeAnimations() {
    for (final c in _ctrls) {
      if (mounted) c.repeat();
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (int i = 0; i < 3; i++)
            AnimatedBuilder(
              animation: _anims[i],
              builder: (_, __) {
                final t = _anims[i].value;
                // 右上端 (1.1) → 左上端 (-1.1) を線形移動
                final x = 1.1 - t * 2.4;
                // 各鳥で y 位置に差をつける
                final y = -0.55 + i * 0.08;
                return Align(
                  alignment: Alignment(x, y),
                  child: _BirdSilhouette(size: 6.0 + i * 1.5),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// 1 羽の小鳥 silhouette (2 本の弧で表現)。
class _BirdSilhouette extends StatelessWidget {
  const _BirdSilhouette({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size * 2.5, size),
      painter: _BirdPainter(),
    );
  }
}

class _BirdPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final cx = size.width / 2;
    final cy = size.height / 2;
    // 左翼
    canvas.drawArc(
      Rect.fromCenter(center: Offset(cx - size.width * 0.3, cy), width: size.width * 0.55, height: size.height * 0.9),
      pi, pi, false, paint,
    );
    // 右翼
    canvas.drawArc(
      Rect.fromCenter(center: Offset(cx + size.width * 0.3, cy), width: size.width * 0.55, height: size.height * 0.9),
      0, pi, false, paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
