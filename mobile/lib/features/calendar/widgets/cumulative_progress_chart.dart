import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_error_chip.dart';
import '../../../shared/widgets/sabi_icon.dart';  // 【FEAT-415 (2026-06-01)】sabi_unified.png 統一
import '../../../shared/widgets/sabi_loading_skeleton.dart';   // FEAT-230
import '../providers/calendar_provider.dart';

/// P2-3: 30 日累積達成カウント折れ線グラフ。
///
/// プロダクト哲学「積み上げ」の可視化。過去 30 日の習慣達成数を
/// 累積（cumulative sum）で表示し、右肩上がりの曲線で「積み上がっている」
/// 感覚を視覚化する。データは既存 `/api/calendar/heatmap/`（91 日分）から
/// 直近 30 日を切り出して計算。
///
/// 表示要素:
///   - カードコンテナ（紳士的・落ち着いた配色）
///   - 折れ線（プライマリ色・グラデーション塗り）
///   - 今日の累積合計値（右上）
///   - 30 日前 / 今日 ラベル（X 軸両端）
class CumulativeProgressChart extends ConsumerWidget {
  const CumulativeProgressChart({super.key});

  static const int _kWindowDays = 30;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final heatmapAsync = ref.watch(calendarHeatmapProvider);

    return heatmapAsync.when(
      loading: () => const _ChartSkeleton(),
      error: (_, __) => SabiErrorChip(
        message: l10n.calendarCumulativeErrorSabi_message,
      ),
      data: (heatmap) {
        // 直近 30 日を切り出し
        final allDays = heatmap.days;
        if (allDays.isEmpty) {
          return const _EmptyState();
        }
        final from = allDays.length > _kWindowDays
            ? allDays.length - _kWindowDays
            : 0;
        final window = allDays.sublist(from);

        // 累積カウントを計算
        var cumulative = 0;
        final spots = <FlSpot>[];
        for (var i = 0; i < window.length; i++) {
          cumulative += window[i].completed;
          spots.add(FlSpot(i.toDouble(), cumulative.toDouble()));
        }

        if (cumulative == 0) {
          return const _EmptyState();
        }

        // 【FEAT-417 (2026-06-10)】前 30 日 (= 60 日前 〜 31 日前) の累積を計算。
        // 91 日分のヒートマップデータがあるが、データが 60 日未満なら比較データなし
        // (= 新規ユーザー扱い) として前期比バッジは非表示。
        var prevCumulative = 0;
        if (allDays.length >= _kWindowDays * 2) {
          final prevStart = allDays.length - (_kWindowDays * 2);
          final prevEnd = allDays.length - _kWindowDays;
          for (final d in allDays.sublist(prevStart, prevEnd)) {
            prevCumulative += d.completed;
          }
        }

        return _ChartCard(
          spots: spots,
          totalCumulative: cumulative,
          prevCumulative: prevCumulative,
          windowLength: window.length,
        );
      },
    );
  }
}

// ── Card コンテナ ─────────────────────────────────────────────────
class _ChartCard extends StatelessWidget {
  final List<FlSpot> spots;
  final int totalCumulative;
  final int prevCumulative;  // 【FEAT-417 (2026-06-10)】前 30 日累積。0 なら比較データなし。
  final int windowLength;

  const _ChartCard({
    required this.spots,
    required this.totalCumulative,
    required this.prevCumulative,
    required this.windowLength,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.15),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── タイトル行 ─────────────────────────────────────────
          Row(
            children: [
              Text(
                l10n.calendarCumulativeChartTitle,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.92),
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
              const Spacer(),
              // 累積合計の小バッジ + 前 30 日比 (FEAT-417)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      l10n.calendarCumulativeTotalBadge(totalCumulative),
                      style: TextStyle(
                        color: AppTheme.primaryLight,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  // 【FEAT-417 (2026-06-10)】前 30 日比 (絶対差) を小型バッジ下に表示。
                  // 前期 0 件 (= 新規ユーザー or データ不足) は混乱を避けて非表示。
                  if (prevCumulative > 0) ...[
                    const SizedBox(height: 4),
                    _PrevPeriodDiff(diff: totalCumulative - prevCumulative),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.calendarCumulativeSubtitleSabi_message,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 11,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),

          // ── グラフ本体 ───────────────────────────────────────
          SizedBox(
            height: 140,
            child: _CumulativeLineChart(spots: spots),
          ),
          const SizedBox(height: 4),

          // ── X 軸ラベル（両端） ────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l10n.calendarCumulativeXAxisStart(windowLength),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 10,
                ),
              ),
              Text(
                l10n.calendarCumulativeXAxisEnd,
                style: TextStyle(
                  color: AppTheme.primaryLight.withValues(alpha: 0.8),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── 折れ線グラフ本体 ─────────────────────────────────────────────
class _CumulativeLineChart extends StatelessWidget {
  final List<FlSpot> spots;

  const _CumulativeLineChart({required this.spots});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (spots.isEmpty) return const SizedBox.shrink();

    final maxY = spots.last.y;
    // Y 軸上端を少し上にして余白を作る
    final chartMaxY = maxY * 1.15 + 1;

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: (spots.length - 1).toDouble(),
        minY: 0,
        maxY: chartMaxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: chartMaxY / 4,
          getDrawingHorizontalLine: (_) => FlLine(
            color: Colors.white.withValues(alpha: 0.05),
            strokeWidth: 1,
          ),
        ),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: LineTouchData(
          handleBuiltInTouches: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppTheme.sheetBackground,
            tooltipRoundedRadius: 8,
            tooltipPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                return LineTooltipItem(
                  l10n.calendarCumulativeTooltip(spot.y.toInt()),
                  const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                );
              }).toList();
            },
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            preventCurveOverShooting: true,
            curveSmoothness: 0.25,
            gradient: LinearGradient(
              colors: [
                AppTheme.primary,
                AppTheme.primaryLight,
              ],
            ),
            barWidth: 2.5,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppTheme.primary.withValues(alpha: 0.28),
                  AppTheme.primary.withValues(alpha: 0.02),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 前 30 日比表示 (FEAT-417、2026-06-10) ────────────────────────
// 「累計 N 回」バッジの直下に、前 30 日 (= 60 日前 〜 31 日前) との
// 絶対差を矢印付きで表示する。色 / アイコン規約は stats_tab.dart の
// _ComparisonCard と統一 (好転 = expColor、悪化 = red、横ばい = white54)。
class _PrevPeriodDiff extends StatelessWidget {
  final int diff;
  const _PrevPeriodDiff({required this.diff});

  @override
  Widget build(BuildContext context) {
    final color = diff > 0
        ? AppTheme.expColor
        : diff < 0
            ? Colors.red.withValues(alpha: 0.85)
            : Colors.white54;
    final icon = diff > 0
        ? Icons.arrow_upward
        : diff < 0
            ? Icons.arrow_downward
            : Icons.remove;
    final sign = diff > 0 ? '+' : '';
    final l10n = AppLocalizations.of(context)!;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 11),
        const SizedBox(width: 2),
        Text(
          l10n.calendarCumulativePrevPeriodDiff('$sign$diff'),
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

// ── 空状態（達成 0 件） ───────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          // 【FEAT-415 (2026-06-01)】絵文字 🪶 → sabi_unified.png に統一。
          // SabiEmotion.pity (寄り添い) = 「まだ始まっていなくても大丈夫」の意味。
          const SabiIcon(emotion: SabiEmotion.pity, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.calendarCumulativeEmptyTitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.calendarCumulativeEmptyBodySabi_message,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── ローディングスケルトン ─────────────────────────────────────────
class _ChartSkeleton extends StatelessWidget {
  const _ChartSkeleton();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 【FEAT-230】チャート領域内でも世界観の温度を統一。
    // SabiWaitingPanel の高さ（≒200px）に合わせてカード高さは制約しない。
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: SabiWaitingPanel(message: l10n.calendarCumulativeLoadingSabi_message),
    );
  }
}
