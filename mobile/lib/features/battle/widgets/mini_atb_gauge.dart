import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// 【FEAT-297 Phase 1】ATB ゲージのミニ版（ラベルなし、高さ 3px）。
///
/// 既存 `AtbGauge` の縮小版。WorldFrameSection 内 MiniBattleArena で使い、
/// HP バーのさらに下に表示する。視覚的に「HP の下に充填バー」が並ぶことで
/// 戦闘の緊張感を保ちつつ省スペース化する。
///
/// 【FEAT-297 §1.2.1】Backend tick は 100ms (10fps) で離散的だが、UI 側で
/// `AnimationController` で 100ms 補間 → 視覚的に滑らかな 60fps に見える。
/// Backend tick は変えず、UI 表現のみ滑らか化することで FEAT-224〜227
/// バッテリー対策には退行なし。
///
/// `RepaintBoundary` でホーム他レイヤーから隔離（Pre-mortem #5 バッテリー対策）。
class MiniAtbGauge extends StatefulWidget {
  const MiniAtbGauge({
    super.key,
    required this.value,
    this.color,
  });

  /// 0.0 〜 1.0。Backend tick (100ms) で更新される目標値。
  final double value;

  /// 充填部分の色。null なら AppTheme.primary。
  final Color? color;

  @override
  State<MiniAtbGauge> createState() => _MiniAtbGaugeState();
}

class _MiniAtbGaugeState extends State<MiniAtbGauge>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100), // Backend tick と同じ
    );
    _anim = Tween<double>(begin: widget.value, end: widget.value)
        .animate(_controller);
    _controller.value = 1.0; // 初期値で即時表示
  }

  @override
  void didUpdateWidget(MiniAtbGauge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      // 現在表示中の補間値を起点に次の目標値へ。アニメ中断時もスムーズ。
      final from = _anim.value;
      _anim = Tween<double>(begin: from, end: widget.value)
          .animate(_controller);
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    // 【Pre-mortem #1】dispose 内で setState 呼ばない、Controller dispose のみ
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fillColor = widget.color ?? AppTheme.primary;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _anim,
        builder: (_, __) {
          final clamped = _anim.value.clamp(0.0, 1.0);
          return ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Stack(
              children: [
                Container(
                  height: 3,
                  color: Colors.white.withValues(alpha: 0.10),
                ),
                FractionallySizedBox(
                  widthFactor: clamped,
                  child: Container(
                    height: 3,
                    color: fillColor,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
