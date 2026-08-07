import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../l10n/app_localizations.dart';

/// 【FEAT-204】過去 30 日の累積完了数を折れ線で表示するチャート。
///
/// 【FEAT-404 (2026-06-01)】「今週 (直近 7 日) vs 先週 (その前 7 日)」の 2 本ライン
/// 対比チャートに置換 (案 Y 採択、PM 判断 2026-06-01)。
/// 「先週分と比較できるようにしたい」ユーザー要望に直結、x 軸 = 曜日 (月-日) で
/// 両週を曜日揃えで重ね描き + 上部に凡例 (● 今週 / ● 先週)。
///
/// 長期累積 (過去 30 日) は別途カレンダー画面の `CumulativeProgressChart` で確認可能。
/// データソース: `GET /api/stats/30d/` の `days[].count` (日次完了数、累積前)。
/// 14 日分を Flutter 側で「今週 7 日」「先週 7 日」に分割 + 各週独立で累積化。
class StackingChart extends StatelessWidget {
  const StackingChart({
    super.key,
    required this.data,
  });

  /// 30 日分のデータ。各要素に `date` (ISO 文字列) と `count` (int、日次達成数) を期待。
  /// 末尾 14 日 (今週 7 + 先週 7) を使用、それ未満なら持っている分だけ表示。
  final List<Map<String, dynamic>> data;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 曜日ラベル (月始まり)。x 軸の `index` で参照。
    final weekdayLabels = [
      l10n.sharedWeekdayMon,
      l10n.sharedWeekdayTue,
      l10n.sharedWeekdayWed,
      l10n.sharedWeekdayThu,
      l10n.sharedWeekdayFri,
      l10n.sharedWeekdaySat,
      l10n.sharedWeekdaySun,
    ];

    if (data.isEmpty) {
      // 空状態は CLAUDE.md サビ口調準拠の紳士的トーンに統一
      return SizedBox(
        height: 200,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              l10n.sharedStackingChartEmptyMessage,
              style: const TextStyle(color: Colors.white54, fontSize: 13, height: 1.6),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    // 【FEAT-404】末尾 14 日を切り出し、「先週 7 日」「今週 7 日」に分割。
    // データが 14 日未満の場合は持っている分だけ使用 (空配列なら _EmptyState は通過済)。
    final tail = data.length > 14 ? data.sublist(data.length - 14) : data;
    // tail 末尾を今週とする、先頭側が先週。tail が 14 未満なら先週側が短くなる。
    final int thisWeekStart = tail.length > 7 ? tail.length - 7 : 0;
    final lastWeekData = tail.sublist(0, thisWeekStart);
    final thisWeekData = tail.sublist(thisWeekStart);

    // 各週独立で累積化 (週内の積み上げ感を週単位で比較する設計)。
    final thisWeekSpots = _toCumulativeSpots(thisWeekData);
    final lastWeekSpots = _toCumulativeSpots(lastWeekData);

    // Y 軸上限: 両週の最大累積値の 1.1 倍 (最小 4)。
    final double thisLastY = thisWeekSpots.isEmpty ? 0 : thisWeekSpots.last.y;
    final double lastLastY = lastWeekSpots.isEmpty ? 0 : lastWeekSpots.last.y;
    final double maxAccum = thisLastY > lastLastY ? thisLastY : lastLastY;
    final maxY = maxAccum < 1 ? 4.0 : maxAccum * 1.1;

    // 【FEAT-405 (2026-06-01)】Y 軸ラベルとグリッド線の interval を統一して
    // 数字の重なりを防ぐ。fl_chart は interval 未指定だと自動算出するが、
    // horizontalInterval (= maxY/4) と一致せず「15」「10」が近接して重なる
    // 現象が発生していた (ユーザー報告 2026-06-01)。
    // nice number (1/2/5/10/20/50...) に丸めて視認性も確保する。
    final yAxisInterval = _niceInterval(maxY / 4);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 凡例 (上部、今週 = 紫 / 先週 = 薄灰) ─────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              _LegendDot(color: AppTheme.primary, label: l10n.sharedStackingChartLegendThisWeek),
              const SizedBox(width: 12),
              _LegendDot(
                color: Colors.white.withValues(alpha: 0.45),
                label: l10n.sharedStackingChartLegendLastWeek,
              ),
            ],
          ),
        ),
        SizedBox(
          height: 220,
          child: Padding(
            // 【FEAT-221】右パディング 24 で横軸末尾ラベルの突き出しを吸収。
            padding: const EdgeInsets.fromLTRB(12, 12, 24, 8),
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: 6,  // 月-日の 7 日 (0-6 index)
                minY: 0,
                maxY: maxY,
                gridData: FlGridData(
                  show:               true,
                  drawVerticalLine:   false,
                  // 【FEAT-405】leftTitles.interval と統一して数字とグリッド線を揃える。
                  horizontalInterval: yAxisInterval,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color:       Colors.white.withValues(alpha: 0.06),
                    strokeWidth: 1,
                  ),
                ),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles:   true,
                      reservedSize: 44,
                      // 【FEAT-405】interval を明示 + nice number で重なり解消。
                      interval:     yAxisInterval,
                      getTitlesWidget: (value, meta) {
                        // 【FEAT-405】天井 (maxY) ぴったりのラベルは間引いて
                        // 「最大ラベルが描画領域上端に張り付く」現象を回避。
                        if (value >= maxY - 0.01) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Text(
                            value.toInt().toString(),
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 10),
                          ),
                        );
                      },
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles:   true,
                      reservedSize: 28,
                      interval:     1,
                      getTitlesWidget: (value, meta) {
                        final i = value.toInt();
                        if (i < 0 || i >= weekdayLabels.length) {
                          return const SizedBox.shrink();
                        }
                        return Text(
                          weekdayLabels[i],
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 10),
                        );
                      },
                    ),
                  ),
                  topTitles:   const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                ),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  // ── 先週ライン (薄灰、背景側) ─────────────────────
                  if (lastWeekSpots.isNotEmpty)
                    LineChartBarData(
                      spots:    lastWeekSpots,
                      isCurved: true,
                      color:    Colors.white.withValues(alpha: 0.45),
                      barWidth: 2.0,
                      dashArray: const [4, 3],  // 点線で「過去」を視覚化
                      dotData:  const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show:  true,
                        color: Colors.white.withValues(alpha: 0.04),
                      ),
                    ),
                  // ── 今週ライン (紫、前景側) ───────────────────────
                  if (thisWeekSpots.isNotEmpty)
                    LineChartBarData(
                      spots:    thisWeekSpots,
                      isCurved: true,
                      color:    AppTheme.primary,
                      barWidth: 2.5,
                      dotData:  const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show:  true,
                        color: AppTheme.primary.withValues(alpha: 0.15),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 日次データを「週内累積」の `FlSpot` リストに変換する。
  /// 各週独立で 0 起点 → 週内の積み上げペースを横並びで比較できる。
  static List<FlSpot> _toCumulativeSpots(List<Map<String, dynamic>> week) {
    if (week.isEmpty) return const [];
    final spots = <FlSpot>[];
    var cumulative = 0;
    for (var i = 0; i < week.length; i++) {
      cumulative += ((week[i]['count'] as num?) ?? 0).toInt();
      spots.add(FlSpot(i.toDouble(), cumulative.toDouble()));
    }
    return spots;
  }

  /// 【FEAT-405】Y 軸 interval の nice number (1, 2, 5, 10, 20, 50, 100...)。
  /// 数字ラベルがキリの良い値で並ぶことで視認性向上 + グリッド線と整合。
  static double _niceInterval(double rough) {
    if (rough <= 1) return 1;
    if (rough <= 2) return 2;
    if (rough <= 5) return 5;
    if (rough <= 10) return 10;
    if (rough <= 20) return 20;
    if (rough <= 50) return 50;
    if (rough <= 100) return 100;
    return (rough / 100).ceil() * 100.0;
  }
}

/// 【FEAT-404】凡例ドット (色 + ラベル)。
class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.85),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// 【FEAT-204】現在ストリーク + 次のマイルストーン達成までの日数を表示するチップ。
///
/// 「あと N 日で X 日達成です」というメッセージで毎日のモチベーション維持を促す。
class MilestoneChip extends StatelessWidget {
  const MilestoneChip({
    super.key,
    required this.currentStreak,
    required this.nextMilestone,
    required this.daysRemaining,
  });

  final int currentStreak;
  final int nextMilestone;
  final int daysRemaining;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // CLAUDE.md サビ口調準拠（達成時の静かな肯定 + 進行中の穏やかな鼓舞）
    final message = daysRemaining == 0
        ? l10n.sharedMilestoneChipAchieved(nextMilestone)
        : l10n.sharedMilestoneChipProgress(daysRemaining, nextMilestone);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color:        AppTheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.local_fire_department,
            size:  18,
            color: AppTheme.primary.withValues(alpha: 0.85),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.sharedMilestoneChipStreakLabel(currentStreak, message),
              style: const TextStyle(
                color:    Colors.white,
                fontSize: 12,
                height:   1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
