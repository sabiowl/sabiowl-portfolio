import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';

class ExpBar extends StatefulWidget {
  final double progress; // 0.0 ~ 1.0
  final int level;
  final int exp;
  final int expToNext;
  final double height;

  const ExpBar({
    super.key,
    required this.progress,
    required this.level,
    required this.exp,
    required this.expToNext,
    this.height = 8,
  });

  @override
  State<ExpBar> createState() => _ExpBarState();
}

class _ExpBarState extends State<ExpBar> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _barAnimation;
  int _displayLevel = 0;
  bool _isLevelingUp = false;

  static const _normalDuration = Duration(milliseconds: 600);
  static const _fillDuration   = Duration(milliseconds: 400);
  static const _refillDuration = Duration(milliseconds: 700);

  @override
  void initState() {
    super.initState();
    _displayLevel = widget.level;
    _controller = AnimationController(vsync: this, duration: _normalDuration);
    // 初回表示: 0 から現在値へ
    _barAnimation = Tween<double>(begin: 0, end: widget.progress).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward();
  }

  @override
  void didUpdateWidget(ExpBar oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 値に変化がなければ何もしない
    if (oldWidget.progress == widget.progress &&
        oldWidget.level == widget.level) {
      return;
    }

    // レベルアップ演出中は新しいアニメーションを上乗せしない
    if (_isLevelingUp) {
      return;
    }

    if (widget.level > oldWidget.level) {
      _runLevelUpAnimation(_barAnimation.value);
    } else {
      _controller.duration = _normalDuration;
      _barAnimation = Tween<double>(
        begin: _barAnimation.value,
        end: widget.progress,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
      _controller.forward(from: 0);
    }
  }

  Future<void> _runLevelUpAnimation(double currentBarValue) async {
    _isLevelingUp = true;

    // Stage 1: 現在値 → 100%（バーを満たす）
    _controller.duration = _fillDuration;
    _barAnimation = Tween<double>(begin: currentBarValue, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );
    await _controller.forward(from: 0);
    if (!mounted) {
      _isLevelingUp = false;
      return;
    }

    // 少し間を置く
    await Future.delayed(const Duration(milliseconds: 120));
    if (!mounted) {
      _isLevelingUp = false;
      return;
    }

    // Stage 2: レベル番号を更新して 0% → 新しい値
    setState(() => _displayLevel = widget.level);
    _controller.duration = _refillDuration;
    _barAnimation = Tween<double>(begin: 0.0, end: widget.progress).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward(from: 0);

    _isLevelingUp = false;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.3),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: Text(
                'Lv.$_displayLevel',
                key: ValueKey(_displayLevel),
                style: const TextStyle(
                  color: AppTheme.gold,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
            Text(
              '${widget.exp} / ${widget.expToNext} EXP',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 11,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        AnimatedBuilder(
          animation: _barAnimation,
          builder: (context, _) => ClipRRect(
            borderRadius: BorderRadius.circular(widget.height / 2),
            child: LinearProgressIndicator(
              value: _barAnimation.value,
              minHeight: widget.height,
              backgroundColor: Colors.white.withValues(alpha: 0.1),
              valueColor:
                  const AlwaysStoppedAnimation<Color>(AppTheme.expColor),
            ),
          ),
        ),
      ],
    );
  }
}
