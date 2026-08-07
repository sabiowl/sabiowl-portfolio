import 'package:flutter/material.dart';

import '../models/combatant.dart';

/// 【FEAT-297 Phase 1】戦闘ユニットの HP を細い帯で表示するミニ HP バー。
///
/// 既存 BattlePage の `_HpBar` の縮小版。WorldFrameSection 内の MiniBattleArena
/// で使い、48×48 sprite の下に細く配置する。フォントサイズ 10、minHeight 4 で
/// 読みやすさと省スペースのバランスを取る。
class MiniHpBar extends StatelessWidget {
  const MiniHpBar({
    super.key,
    required this.combatant,
    required this.color,
  });

  final Combatant combatant;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final pct = combatant.maxHp == 0
        ? 0.0
        : (combatant.currentHp / combatant.maxHp).clamp(0.0, 1.0);
    return RepaintBoundary(
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: Stack(
                children: [
                  Container(height: 4, color: Colors.white12),
                  FractionallySizedBox(
                    widthFactor: pct,
                    child: Container(height: 4, color: color),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '${combatant.currentHp}/${combatant.maxHp}',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 9,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
