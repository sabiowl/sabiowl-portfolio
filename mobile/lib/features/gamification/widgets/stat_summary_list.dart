import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';

import '../../../core/theme/app_theme.dart';
import '../models/gamification_models.dart';
import 'stat_hexagon_chart.dart';

/// 【2026-06-27】6 ステータスを「短縮名 + 累計 EXP + (絶対 %)」の縦リストで
/// 表示する widget。`StatHexagonChart` の左隣に並べて使う想定 (stats_page)。
///
/// 表示例:
///   運動  425  (85%)
///   学習  460  (92%)
///   健康  980  (98%)
///   ...
///
/// - 名前は `StatHexagonChart.labelFor` で短縮 (運動 / 学習 / ...) し、チャート
///   ラベルと表記揺れを起こさない。
/// - 累計 EXP は `CharacterStatComputed.cumulativeExp` (Flutter 側計算)。
/// - % は `progressPercent` (Lv 50 = 100% 基準) で、チャートの正規化と一致。
/// - 表示順は `StatHexagonChart` と同じ固定順 (運動 → 学習 → 健康 → 精神 →
///   創造 → 貢献) で並べ、リスト行とチャート頂点を 1:1 で読み比べられる設計。
class StatSummaryList extends StatelessWidget {
  final List<CharacterStat> stats;

  /// チャートと同じ固定表示順。
  static const _displayOrder = <String>[
    '運動力', '学習力', '健康力', '精神力', '創造力', '貢献力',
  ];

  const StatSummaryList({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    if (stats.isEmpty) return const SizedBox.shrink();
    final ordered = _orderedStats();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: ordered.map((s) => _StatRow(stat: s)).toList(),
    );
  }

  List<CharacterStat> _orderedStats() {
    final byName = {for (final s in stats) s.name: s};
    return [
      for (final name in _displayOrder)
        byName[name] ??
            CharacterStat(
              id: -1, name: name, level: 0, currentExp: 0, maxExp: 1,
            ),
    ];
  }
}

class _StatRow extends StatelessWidget {
  final CharacterStat stat;
  const _StatRow({required this.stat});

  @override
  Widget build(BuildContext context) {
    final short = StatHexagonChart.labelFor(AppLocalizations.of(context)!, stat.name);
    final value = stat.cumulativeExp;
    final percent = stat.progressPercent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        children: [
          // ── 短縮ラベル「運動」(固定幅で 6 行が左揃え) ─────────
          SizedBox(
            width: 32,
            child: Text(
              short,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 4),
          // ── 累計 EXP (右寄せで桁を揃える) ─────────────────────
          Expanded(
            child: Text(
              '$value',
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 6),
          // ── % 値 (チャート頂点の % と同期) ────────────────────
          SizedBox(
            width: 44,
            child: Text(
              '($percent%)',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: AppTheme.primary.withValues(alpha: 0.95),
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
