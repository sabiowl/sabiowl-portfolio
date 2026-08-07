import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

/// 【FEAT-295 Phase 1c】戦闘ログのテキスト表示 widget。
///
/// 直近 N 行（MVP は 3 行）を表示。`BattleState.logLines` を受け取って
/// 表示するだけのシンプルな視覚要素。
class BattleLogText extends StatelessWidget {
  const BattleLogText({
    super.key,
    required this.lines,
    this.maxLines = 3,
    this.color,
  });

  final List<String> lines;
  final int maxLines;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (lines.isEmpty) {
      return Text(
        l10n.battleLogEmptyHint,
        style: TextStyle(
          color: color ?? Colors.white38,
          fontSize: 11,
          fontStyle: FontStyle.italic,
        ),
      );
    }
    final shown = lines.length > maxLines
        ? lines.sublist(lines.length - maxLines)
        : lines;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: shown
          .map((line) => Text(
                line,
                style: TextStyle(
                  color: color ?? Colors.white70,
                  fontSize: 11,
                  height: 1.4,
                ),
              ))
          .toList(),
    );
  }
}
