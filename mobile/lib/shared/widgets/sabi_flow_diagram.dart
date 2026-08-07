// 【FEAT-512 (2026-07-30)】空状態チュートリアル用 flow 図パーツ。
// memo_flow_diagram.dart を shared に昇格 + SabiFlow* に rename。
// 5 feature (Habit / Guild / Gacha / Challenge / Stats) の inline 空状態 tutorial
// で共通利用する。
//
// 構成部品:
//   - SabiFlowBox: ノードボックス (角丸、AppTheme.card 背景)
//   - SabiFlowArrow: ▼ 縦連結矢印
//   - SabiFlowLeaf: 末端 circular chip
//   - SabiFlowBranchPainter: T 字分岐 connector の CustomPainter
//
// Sabi 哲学 (穏やか、静か、押し付けない) 準拠、AppTheme.primary 40-60% alpha 統一。
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

class SabiFlowBox extends StatelessWidget {
  final String icon;
  final String label;
  const SabiFlowBox({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 160),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.card.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.4),
          width: 1.2,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(icon, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 10),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class SabiFlowArrow extends StatelessWidget {
  const SabiFlowArrow({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Icon(
        Icons.arrow_downward,
        size: 16,
        color: AppTheme.primary.withValues(alpha: 0.55),
      ),
    );
  }
}

class SabiFlowLeaf extends StatelessWidget {
  final String icon;
  final String label;
  const SabiFlowLeaf({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: AppTheme.card.withValues(alpha: 0.6),
            shape: BoxShape.circle,
            border: Border.all(
              color: AppTheme.primary.withValues(alpha: 0.4),
              width: 1.2,
            ),
          ),
          child: Center(
            child: Text(icon, style: const TextStyle(fontSize: 20)),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.85),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

/// T 字分岐: 上端中央から垂直に下ろし → 水平に左右へ → 3 分岐先の上端へ降ろす。
class SabiFlowBranchPainter extends CustomPainter {
  const SabiFlowBranchPainter();

  static const _lineColor = Color(0x8C7C6AF7); // AppTheme.primary alpha 0.55

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _lineColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final w = size.width;
    final h = size.height;
    final cx = w / 2;

    canvas.drawLine(Offset(cx, 0), Offset(cx, h * 0.5), paint);

    final leftX  = w / 6;
    final rightX = w * 5 / 6;
    canvas.drawLine(Offset(leftX, h * 0.5), Offset(rightX, h * 0.5), paint);

    canvas.drawLine(Offset(leftX,  h * 0.5), Offset(leftX,  h), paint);
    canvas.drawLine(Offset(cx,     h * 0.5), Offset(cx,     h), paint);
    canvas.drawLine(Offset(rightX, h * 0.5), Offset(rightX, h), paint);
  }

  @override
  bool shouldRepaint(covariant SabiFlowBranchPainter oldDelegate) => false;
}
