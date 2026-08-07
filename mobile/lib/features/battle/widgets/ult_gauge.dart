import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// 【FEAT-300】必殺技ゲージ（縦 N 分割タワー型）。
///
/// Gemini `battle_system_2.md` §1.2「必殺技ボタン横の垂直 4 分割ゲージ」の
/// ゲージ部分を MVP に切り出した可視化要素。手動ボタン発動は v1.1+ 持ち越し。
///
/// 内部状態 `BattleState.chargedSpecialCount` (0〜ultCost) を読んで、
/// 下から順に「点灯マス」として表現する。`Tactic.conserveUltimate` 中に
/// プレイヤーが「いま 2/3 貯まった」が視覚的に分かるようになる。
///
/// 満タン時のみ全マスが穏やかにパルスする（alpha 0.7↔1.0、1.5s 周期）。
/// 未満タン時はアニメ完全停止（Pre-mortem #4 バッテリー対策）。
///
/// `RepaintBoundary` でホーム他レイヤーから隔離。
class UltGauge extends StatefulWidget {
  const UltGauge({
    super.key,
    required this.chargedCount,
    required this.ultCost,
    this.compact = false,
    this.color,
  });

  /// 現在の蓄積数（0 〜 ultCost）。
  final int chargedCount;

  /// 満タン到達に必要な数。1〜4 想定。ジョブ駆動（`Combatant.ultCost`）。
  final int ultCost;

  /// true: MiniBattleArena 用の小型版（24×6px）。
  /// false: BattlePage 用の大型版（80×14px）。
  final bool compact;

  /// 点灯マスの色。null なら `AppTheme.gold`（必殺＝特別感）。
  final Color? color;

  @override
  State<UltGauge> createState() => _UltGaugeState();
}

class _UltGaugeState extends State<UltGauge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  bool get _isFull =>
      widget.ultCost > 0 && widget.chargedCount >= widget.ultCost;

  @override
  void initState() {
    super.initState();
    if (_isFull) _pulseCtrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant UltGauge oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasFull =
        oldWidget.ultCost > 0 && oldWidget.chargedCount >= oldWidget.ultCost;
    if (_isFull && !wasFull) {
      _pulseCtrl.repeat(reverse: true);
    } else if (!_isFull && wasFull) {
      _pulseCtrl.stop();
      _pulseCtrl.value = 0.0;
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.ultCost <= 0) return const SizedBox.shrink();

    final cells = widget.ultCost;
    final lit = widget.chargedCount.clamp(0, cells);
    final color = widget.color ?? AppTheme.gold;
    final width = widget.compact ? 6.0 : 14.0;
    final height = widget.compact ? 24.0 : 80.0;
    final gap = widget.compact ? 1.0 : 2.0;

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _pulseCtrl,
        builder: (_, __) {
          final pulseAlpha = _isFull ? (0.7 + 0.3 * _pulseCtrl.value) : 1.0;
          return SizedBox(
            width: width,
            height: height,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(cells, (i) {
                // 描画順は上から、点灯判定は下から（i=0 = 一番下のマス）
                final cellIndexFromBottom = cells - 1 - i;
                final isLit = cellIndexFromBottom < lit;
                final cellHeight =
                    (height - gap * (cells - 1)) / cells;
                return Padding(
                  padding: EdgeInsets.only(bottom: i == cells - 1 ? 0 : gap),
                  child: Container(
                    width: width,
                    height: cellHeight,
                    decoration: BoxDecoration(
                      color: isLit
                          ? color.withValues(alpha: pulseAlpha)
                          : Colors.white.withValues(alpha: 0.10),
                      borderRadius:
                          BorderRadius.circular(widget.compact ? 1.5 : 3),
                      border: isLit
                          ? Border.all(
                              color: color.withValues(alpha: 0.5),
                              width: 0.5,
                            )
                          : null,
                    ),
                  ),
                );
              }),
            ),
          );
        },
      ),
    );
  }
}
