import 'package:flutter/material.dart';

/// 【FEAT-305】受付リリアの吹き出し UI。左側に △ しっぽを持つ角丸四角。
///
/// 設計（指示書 §2.6）:
///   - 背景: 白半透明 (0.95)、本文はダーク
///   - 左中央に三角形のしっぽ、リリア sprite の方向を示す
///   - 親が高さを決め、テキストは中央 1〜3 行で収まる想定
class SpeechBubble extends StatelessWidget {
  const SpeechBubble({super.key, required this.message});

  /// 表示するセリフ全文（プレースホルダ置換済）。
  final String message;

  static const double _tailWidth = 10.0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // ── しっぽ (左中央、△ 形状) ─────────────────────────────
        // 左寄せの △ をリリア側に向ける。CustomPaint で軽量実装。
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: SizedBox(
            width: _tailWidth,
            child: CustomPaint(
              painter: _SpeechBubbleTailPainter(
                color: Colors.white.withValues(alpha: 0.95),
              ),
            ),
          ),
        ),
        // ── 本体 ────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.only(left: _tailWidth),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.20),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.black87,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }
}

/// △ しっぽ専用の軽量 CustomPainter。左端の中央高に頂点が来る三角形を描く。
class _SpeechBubbleTailPainter extends CustomPainter {
  _SpeechBubbleTailPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path()
      // 三角形: 左中央 → 右上 → 右下 を結ぶ
      ..moveTo(0, size.height / 2)
      ..lineTo(size.width, size.height / 2 - 8)
      ..lineTo(size.width, size.height / 2 + 8)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SpeechBubbleTailPainter old) =>
      old.color != color;
}
