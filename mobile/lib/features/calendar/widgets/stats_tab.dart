import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_icon.dart';
import '../../../shared/widgets/sabi_loading_skeleton.dart';  // FEAT-218
import '../models/calendar_models.dart';
import '../providers/calendar_provider.dart';

class StatsTab extends ConsumerWidget {
  final int year;
  final int month;
  const StatsTab({super.key, required this.year, required this.month});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final statsAsync = ref.watch(statsDataProvider(year, month));

    return statsAsync.when(
      data: (stats) => _buildContent(context, ref, stats),
      loading: () => SabiWaitingPanel(message: l10n.calendarStatsTabLoadingSabi_message),
      error: (e, _) => Center(
        // FEAT-186: 紳士的トーンへ統一
        child: Text(
          l10n.calendarStatsTabErrorSabi_message,
          style: const TextStyle(color: Colors.white70),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildContent(
      BuildContext context, WidgetRef ref, StatsData stats) {
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(statsDataProvider(year, month));
      },
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          16, 16, 16,
          16 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          // ── Sabi インサイトバブル ──────────────────
          _SabiInsightBubble(insight: stats.insight, stats: stats),

          // ── 先月比較 ───────────────────────────────
          _ComparisonCard(stats: stats),
          const SizedBox(height: 16),

          // ── インサイト（数値データ補完） ────────────
          _InsightCard(insight: stats.insight),
          const SizedBox(height: 16),

          // ── 習慣別達成率 ───────────────────────────
          _HabitRateSection(habitRates: stats.habitRates),
          const SizedBox(height: 16),

          // ── 曜日別ヒートマップ ──────────────────────
          _DowHeatmapCard(dowAvgs: stats.dowAvgs),
        ],
      ),
    );
  }
}

// ── 先月比較 ────────────────────────────────────────────────────
class _ComparisonCard extends StatelessWidget {
  final StatsData stats;
  const _ComparisonCard({required this.stats});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final prev = stats.prevMonth;
    final curr = stats.currMonth;
    if (prev == null || curr == null) return const SizedBox.shrink();

    final rateDiff = stats.rateDiff;
    final diffColor = rateDiff > 0
        ? AppTheme.expColor
        : rateDiff < 0
            ? Colors.red
            : Colors.white54;
    final diffIcon = rateDiff > 0
        ? Icons.arrow_upward
        : rateDiff < 0
            ? Icons.arrow_downward
            : Icons.remove;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppLocalizations.of(context)!.calendarStatsComparisonTitle,
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _monthBlock(
                    '${prev.year}/${prev.month}', prev.rate, Colors.white38, l10n),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  children: [
                    Icon(diffIcon, color: diffColor, size: 20),
                    Text(
                      '${rateDiff > 0 ? '+' : ''}$rateDiff%',
                      style: TextStyle(
                          color: diffColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 13),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _monthBlock(
                    '${curr.year}/${curr.month}', curr.rate, Colors.white, l10n),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _monthBlock(String label, int rate, Color color, AppLocalizations l10n) => Column(
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
          const SizedBox(height: 4),
          Text('$rate%',
              style: TextStyle(
                  color: color,
                  fontSize: 28,
                  fontWeight: FontWeight.bold)),
          Text(l10n.calendarStatsCompletionRateLabel,
              style: const TextStyle(color: Colors.white38, fontSize: 10)),
        ],
      );
}

// ── インサイト ──────────────────────────────────────────────────
class _InsightCard extends StatelessWidget {
  final InsightData insight;
  const _InsightCard({required this.insight});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final items = <Map<String, dynamic>>[];
    if (insight.bestHabitName != null) {
      items.add({
        'icon': Icons.emoji_events,
        'color': AppTheme.gold,
        'label': l10n.calendarStatsBestHabitLabel,
        'value': insight.bestHabitName!,
        'sub': l10n.calendarStatsHabitRateAchievement(insight.bestHabitRate),
      });
    }
    if (insight.worstHabitName != null) {
      items.add({
        'icon': Icons.trending_down,
        'color': Colors.orange,
        'label': l10n.calendarStatsWorstHabitLabel,
        'value': insight.worstHabitName!,
        'sub': l10n.calendarStatsHabitRateAchievement(insight.worstHabitRate),
      });
    }
    if (insight.weakDowLabel != null) {
      items.add({
        'icon': Icons.calendar_today,
        'color': Colors.blue,
        'label': l10n.calendarStatsWeakDowLabel,
        'value': l10n.calendarStatsWeakDowValue(insight.weakDowLabel!),
        'sub': l10n.calendarStatsWeakDowRateLabel(insight.weakDowRate),
      });
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.calendarStatsInsightTitle,
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1)),
          const SizedBox(height: 12),
          ...items.map((item) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: (item['color'] as Color).withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(item['icon'] as IconData,
                          color: item['color'] as Color, size: 18),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item['label'] as String,
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 10)),
                          Text(item['value'] as String,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                    Text(item['sub'] as String,
                        style: TextStyle(
                            color: item['color'] as Color, fontSize: 12)),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}

// ── 習慣別達成率 ─────────────────────────────────────────────────
class _HabitRateSection extends StatelessWidget {
  final List<HabitRate> habitRates;
  const _HabitRateSection({required this.habitRates});

  @override
  Widget build(BuildContext context) {
    if (habitRates.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(AppLocalizations.of(context)!.calendarStatsHabitRateTitle,
            style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1)),
        const SizedBox(height: 8),
        ...habitRates.map((h) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(h.name,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13),
                            overflow: TextOverflow.ellipsis),
                      ),
                      Text('${h.rate}%',
                          style: TextStyle(
                              color: _rateColor(h.rate),
                              fontWeight: FontWeight.bold,
                              fontSize: 13)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: h.rate / 100,
                      minHeight: 5,
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      valueColor: AlwaysStoppedAnimation<Color>(_rateColor(h.rate)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(AppLocalizations.of(context)!.calendarStatsHabitPeriodLabel(h.completed, h.pastDays),
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 10)),
                ],
              ),
            )),
      ],
    );
  }

  Color _rateColor(int rate) {
    if (rate >= 80) return AppTheme.expColor;
    if (rate >= 50) return AppTheme.primary;
    if (rate >= 30) return Colors.orange;
    return Colors.red.withValues(alpha: 0.8);
  }
}

// ── 曜日別ヒートマップ ──────────────────────────────────────────
class _DowHeatmapCard extends StatelessWidget {
  final List<DowAvg> dowAvgs;
  const _DowHeatmapCard({required this.dowAvgs});

  @override
  Widget build(BuildContext context) {
    if (dowAvgs.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppLocalizations.of(context)!.calendarStatsDowHeatmapTitle,
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1)),
          const SizedBox(height: 12),
          Row(
            children: dowAvgs.map((d) {
              final rate = d.rate;
              final color = rate == null
                  ? Colors.white12
                  : rate >= 80
                      ? AppTheme.expColor
                      : rate >= 50
                          ? AppTheme.primary
                          : rate >= 30
                              ? Colors.orange
                              : Colors.red.withValues(alpha: 0.7);

              return Expanded(
                child: Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      height: 48,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: rate == null ? 0.15 : 0.8),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          rate != null ? '$rate' : '-',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(d.label,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 10)),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

// ── Sabi インサイトバブル ────────────────────────────────────────
class _SabiInsightBubble extends StatelessWidget {
  const _SabiInsightBubble(
      {required this.insight, required this.stats});
  final InsightData insight;
  final StatsData stats;

  /// セリフ内容に連動した Sabi 表情を返す。
  /// _generateMessage() と同じ条件で分岐し、最初にヒットした表情を採用する。
  SabiEmotion _resolveEmotion() {
    // 最もよく続いている習慣が 90% 以上 → 誇らしく深く語る
    if (insight.bestHabitName != null && insight.bestHabitRate >= 90) {
      return SabiEmotion.proud;
    }
    // 60–89% → 軽い称賛
    if (insight.bestHabitName != null && insight.bestHabitRate >= 60) {
      return SabiEmotion.happy;
    }
    // 苦手曜日あり → 助言・豆知識モード
    if (insight.weakDowLabel != null && insight.weakDowRate < 60) {
      return SabiEmotion.wise;
    }
    // ワースト習慣が 40% 未満 → 正直に伝える（awkward）
    if (insight.worstHabitName != null && insight.worstHabitRate < 40) {
      return SabiEmotion.awkward;
    }
    // データなし・観察中
    return SabiEmotion.normal;
  }

  String _generateMessage(AppLocalizations l10n) {
    final messages = <String>[];

    if (insight.bestHabitName != null && insight.bestHabitRate > 0) {
      if (insight.bestHabitRate >= 90) {
        messages.add(l10n.calendarStatsBestHabit90Sabi_message(
            insight.bestHabitName!, insight.bestHabitRate));
      } else if (insight.bestHabitRate >= 60) {
        messages.add(l10n.calendarStatsBestHabit60Sabi_message(
            insight.bestHabitName!, insight.bestHabitRate));
      }
    }

    if (insight.weakDowLabel != null && insight.weakDowRate < 60) {
      messages.add(l10n.calendarStatsWeakDowSabi_message(
          insight.weakDowLabel!, insight.weakDowRate));
    }

    if (insight.worstHabitName != null && insight.worstHabitRate < 40) {
      messages.add(l10n.calendarStatsWorstHabitSabi_message(
          insight.worstHabitName!, insight.worstHabitRate));
    }

    if (messages.isEmpty) {
      return l10n.calendarStatsNoDataSabi_message;
    }
    return messages.take(2).join('\n\n');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SabiIconAnimated(
            emotion: _resolveEmotion(),
            size: 48,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 吹き出し三角
                Positioned(
                  top: 14,
                  left: -6,
                  child: Transform.rotate(
                    angle: 45 * 3.14159 / 180,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.08),
                        border: Border(
                          left: BorderSide(
                              color:
                                  AppTheme.primary.withValues(alpha: 0.2)),
                          bottom: BorderSide(
                              color:
                                  AppTheme.primary.withValues(alpha: 0.2)),
                        ),
                      ),
                    ),
                  ),
                ),
                // バブル本体
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.08),
                    border: Border.all(
                        color: AppTheme.primary.withValues(alpha: 0.2)),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4),
                      topRight: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                      bottomRight: Radius.circular(16),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'SABI',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: Color(0xCB7F77DD),
                          letterSpacing: 3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _generateMessage(l10n),
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.85),
                          height: 1.65,
                        ),
                      ),
                    ],
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
