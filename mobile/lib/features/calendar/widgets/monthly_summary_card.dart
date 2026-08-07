import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../models/calendar_models.dart';

String _calcGrade(int completionRate) {
  if (completionRate >= 90) return 'S';
  if (completionRate >= 75) return 'A';
  if (completionRate >= 60) return 'B';
  if (completionRate >= 40) return 'C';
  return 'D';
}

Color _gradeColor(String grade) {
  switch (grade) {
    case 'S': return AppTheme.gold;
    case 'A': return AppTheme.primary;
    case 'B': return AppTheme.expColor;
    case 'C': return const Color(0xFFFF9800);
    default:  return Colors.white38;
  }
}

// ── 月間サマリーカード ──────────────────────────────────────────
class MonthlySummaryCard extends StatelessWidget {
  final CalendarSummary summary;
  /// 【2026-06-27】ストリーク項目タップ時の callback。
  /// 設定されていればストリーク列に下線 + chevron で「タップ可能」を示す。
  /// 押下で習慣別ストリーク詳細ポップアップを表示する想定 (caller 側で実装)。
  final VoidCallback? onStreakTap;
  const MonthlySummaryCard({
    super.key,
    required this.summary,
    this.onStreakTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final grade = _calcGrade(summary.completionRate);
    final gradeCol = _gradeColor(grade);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          // 達成率 + グレード
          Expanded(
            child: Column(
              children: [
                Text(l10n.calendarMonthlySummaryRateLabel,
                    style: const TextStyle(color: Colors.white38, fontSize: 10),
                    textAlign: TextAlign.center),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${summary.completionRate}%',
                      style: const TextStyle(
                          color: AppTheme.expColor,
                          fontSize: 20,
                          fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: gradeCol.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: gradeCol.withValues(alpha: 0.6)),
                      ),
                      child: Text(
                        grade,
                        style: TextStyle(
                          color: gradeCol,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _divider(),
          _item(l10n.calendarMonthlySummaryAchievedDaysLabel, l10n.calendarMonthlySummaryDaysValue(summary.daysWithAny), AppTheme.primary),
          _divider(),
          _streakItem(l10n.calendarMonthlySummaryStreakLabel, l10n.calendarMonthlySummaryDaysValue(summary.currentStreak), Colors.orange),
        ],
      ),
    );
  }

  Widget _item(String label, String value, Color color) => Expanded(
        child: Column(
          children: [
            Text(label,
                style: const TextStyle(color: Colors.white38, fontSize: 10),
                textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(
                    color: color,
                    fontSize: 20,
                    fontWeight: FontWeight.bold),
                textAlign: TextAlign.center),
          ],
        ),
      );

  /// 【2026-06-27】ストリーク専用列 — onStreakTap が設定されていれば
  /// タップ可能な見た目 (chevron 表示) で習慣別ストリークポップアップを開く。
  Widget _streakItem(String label, String value, Color color) {
    final tappable = onStreakTap != null;
    final content = Column(
      children: [
        // タップ可能であることを chevron で示唆 (ラベル + 右矢印を 1 行に)
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(color: Colors.white38, fontSize: 10),
                textAlign: TextAlign.center),
            if (tappable) ...[
              const SizedBox(width: 2),
              Icon(Icons.chevron_right,
                  size: 12, color: Colors.white.withValues(alpha: 0.45)),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                color: color, fontSize: 20, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center),
      ],
    );
    return Expanded(
      child: tappable
          ? InkWell(
              onTap: onStreakTap,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: content,
              ),
            )
          : content,
    );
  }

  Widget _divider() =>
      Container(width: 1, height: 40, color: Colors.white.withValues(alpha: 0.1));
}
