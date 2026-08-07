import 'package:flutter/material.dart';

import '../models/battle_state.dart' show DamageEvent;

/// 【FEAT-385 (2026-05-29)】戦闘 Floating Damage 数値表示 widget。
///
/// 攻撃時にダメージ数値が sprite 上部にポップアップ、上に流れながらフェードアウト。
/// `BattleState.enemyDamageEvent` / `playerDamageEvent` が `null != _prev` で
/// 変化したタイミングで `FloatingDamageText(key: ValueKey(event.timestamp))` を
/// Stack 配置することで、連続攻撃でも別 widget instance として再描画される。
///
/// 演出:
///   - duration: 800ms
///   - 0-100ms: 下から上にバウンスで出現 (Curves.elasticOut)
///   - 100-700ms: 上に -24px 移動 (Curves.easeOut)
///   - 500-800ms: フェードアウト (opacity 1.0 → 0.0)
///   - Critical 時: フォント大 (22 vs 16) + 色 (orange vs red) + 太字
class FloatingDamageText extends StatefulWidget {
  const FloatingDamageText({
    super.key,
    required this.event,
    this.isUltimate = false,
  });

  final DamageEvent event;

  /// 【新規 (2026-06-26)】必殺技ヒット時の強化表示モード。
  /// true のときフォント大 (32 vs 16/22) + 黄金色 + 太字 + 長めのフェード。
  final bool isUltimate;

  @override
  State<FloatingDamageText> createState() => _FloatingDamageTextState();
}

class _FloatingDamageTextState extends State<FloatingDamageText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _yMove;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    // 出現スケール (0.0 → 1.2 → 1.0、エラスティック)
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.2)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 30,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.2, end: 1.0),
        weight: 70,
      ),
    ]).animate(_ctrl);
    // y 方向 (上に -24px、最初の 100ms は 0、その後一定速度)
    _yMove = Tween<double>(begin: 0.0, end: -24.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
    // opacity (500ms 以降にフェードアウト、500/800 = 0.625)
    _opacity = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 62),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 38),
    ]).animate(_ctrl);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isCritical = widget.event.isCritical;
    final isUltimate = widget.isUltimate;
    // 【新規 (2026-06-26)】3 段階強化:
    //   ultimate: 32 px 黄金色 (撃墜エフェクトの中心)
    //   critical: 22 px オレンジ
    //   通常:     16 px 赤
    final double fontSize;
    final Color color;
    if (isUltimate) {
      fontSize = 32;
      color = const Color(0xFFFFD700);  // 黄金 (撃墜の王道色)
    } else if (isCritical) {
      fontSize = 22;
      color = Colors.orange;
    } else {
      fontSize = 16;
      color = Colors.redAccent;
    }
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) {
          return Opacity(
            opacity: _opacity.value,
            child: Transform.translate(
              offset: Offset(0, _yMove.value),
              child: Transform.scale(
                scale: _scale.value,
                child: Text(
                  '-${widget.event.amount}',
                  style: TextStyle(
                    fontSize: fontSize,
                    color: color,
                    fontWeight: FontWeight.bold,
                    height: 1.0,
                    shadows: const [
                      Shadow(
                        color: Colors.black,
                        blurRadius: 4,
                        offset: Offset(1, 1),
                      ),
                      Shadow(
                        color: Colors.black,
                        blurRadius: 4,
                        offset: Offset(-1, -1),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
