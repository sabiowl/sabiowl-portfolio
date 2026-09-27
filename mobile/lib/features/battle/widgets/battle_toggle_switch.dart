import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// 【FEAT-528 (2026-08-22)】オートバトルの ON/OFF を表す小さなトグルの見た目。
///
/// 元はギルド画面の `_ToggleSwitch`（private）だったが、バトル設定モーダルでも
/// **同じ見た目**を使う必要が出たので切り出した。
///
/// 🔴 **コピーではなく共有にした理由**: 2 箇所に同じ 30 行を置くと、
/// 片方の色や寸法を直したときにもう片方が取り残される。バーとモーダルは
/// **同じ画面から 1 タップで行き来できる**ので、ズレると即座に目に付く。
///
/// 表示専用。タップの受け口は持たない（親の `InkWell` / `GestureDetector` が担う）。
class BattleToggleSwitch extends StatelessWidget {
  const BattleToggleSwitch({super.key, required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 40,
      height: 22,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        color: value
            ? AppTheme.primary.withValues(alpha: 0.85)
            : Colors.white.withValues(alpha: 0.2),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 200),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.all(2.5),
          width: 17,
          height: 17,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
