import 'package:flutter/material.dart';

import '../constants/battle_constants.dart';

/// 【FEAT-295 Phase 1b】ダメージ数値表示。
///
/// `TweenAnimationBuilder` で y 方向 0 → -20px に滑り上がり、`AnimatedOpacity`
/// で 1 → 0 にフェードアウト。800ms（`BattleConstants.damagePopupDuration`）。
///
/// 使用パターン: `BattleOrchestrator` がアビリティ発火時に `Overlay.insert` で
/// 一時的に追加し、800ms 後に自動削除する設計。
class DamagePopup extends StatefulWidget {
  const DamagePopup({
    super.key,
    required this.value,
    this.isCritical = false,
    this.isHeal = false,
  });

  final int value;
  final bool isCritical;
  final bool isHeal;

  @override
  State<DamagePopup> createState() => _DamagePopupState();
}

class _DamagePopupState extends State<DamagePopup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: BattleConstants.damagePopupDuration,
    );
    _opacity = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.5, 1.0)),
    );
    _offset = Tween<Offset>(
      begin:  const Offset(0, 0),
      end:    const Offset(0, -0.6), // 約 -20px 相当（フォントサイズ × 0.6）
    ).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    // 【Pre-mortem #1】dispose 内で setState を呼ばない
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isHeal
        ? Colors.greenAccent
        : (widget.isCritical ? Colors.yellowAccent : Colors.white);
    final prefix = widget.isHeal ? '+' : '-';
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, __) => Opacity(
          opacity: _opacity.value,
          child: FractionalTranslation(
            translation: _offset.value,
            child: Text(
              '$prefix${widget.value}',
              style: TextStyle(
                color: color,
                fontSize: 28,
                fontWeight: FontWeight.w900,
                shadows: const [
                  Shadow(color: Colors.black87, blurRadius: 4, offset: Offset(1, 1)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
