import 'package:flutter/material.dart';

/// カードの縁に沿ってプログレスアークを描画する。
///
/// [progress] 0.0〜1.0。タップダウンから 500ms で一周する。
/// グロー効果（MaskFilter.blur）で光が滲んで見える。
class CardBorderProgressPainter extends CustomPainter {
  final double progress;
  final Color  color;
  final double borderRadius;

  const CardBorderProgressPainter({
    required this.progress,
    required this.color,
    required this.borderRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final paint = Paint()
      ..color       = color.withValues(alpha: 0.85)
      ..strokeWidth = 2.5
      ..style       = PaintingStyle.stroke
      ..strokeCap   = StrokeCap.round
      ..maskFilter  = const MaskFilter.blur(BlurStyle.normal, 3);

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(borderRadius),
    );

    final path    = Path()..addRRect(rect);
    final metrics = path.computeMetrics();
    for (final metric in metrics) {
      final extractPath = metric.extractPath(0, metric.length * progress);
      canvas.drawPath(extractPath, paint);
    }
  }

  @override
  bool shouldRepaint(CardBorderProgressPainter old) =>
      old.progress != progress || old.color != color;
}
