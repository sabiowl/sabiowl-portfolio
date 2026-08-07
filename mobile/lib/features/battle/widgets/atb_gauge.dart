import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// 【FEAT-295 Phase 1b】個別 ATB ゲージ（横長バー、ラベル付き）。
///
/// 全画面 BattlePage で使用。MiniBattleArena 用には別途 `MiniAtbGauge` を用意
/// （高さ・ラベルの有無が異なるため別実装）。
///
/// 【FEAT-297 §1.2.1】Backend tick (100ms = 10fps) で離散的に更新される値を、
/// `AnimationController` で 100ms 補間して **視覚的に 60fps の滑らかさ** で
/// 表示する（FF5 / FF6 風の流れる ATB ゲージ）。Backend tick 自体は変えず
/// FEAT-224〜227 バッテリー対策の退行なし。
///
/// `RepaintBoundary` でホーム他レイヤーから隔離（Pre-mortem #4 バッテリー対策）。
class AtbGauge extends StatefulWidget {
  const AtbGauge({
    super.key,
    required this.value,
    required this.label,
    this.color,
    this.height = 8.0,
  });

  /// 0.0 〜 1.0。Backend tick (100ms) で更新される目標値。
  final double value;

  /// 左に表示するラベル（'勇者' / 'ゴブリン' 等）。
  final String label;

  /// 充填部分の色。null なら AppTheme.primary。
  final Color? color;

  final double height;

  @override
  State<AtbGauge> createState() => _AtbGaugeState();
}

class _AtbGaugeState extends State<AtbGauge>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _anim = Tween<double>(begin: widget.value, end: widget.value)
        .animate(_controller);
    _controller.value = 1.0;
  }

  @override
  void didUpdateWidget(AtbGauge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
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
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(
              widget.label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: AnimatedBuilder(
              animation: _anim,
              builder: (_, __) {
                final clamped = _anim.value.clamp(0.0, 1.0);
                return ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Stack(
                    children: [
                      Container(
                        height: widget.height,
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                      FractionallySizedBox(
                        widthFactor: clamped,
                        child: Container(
                          height: widget.height,
                          color: fillColor,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
