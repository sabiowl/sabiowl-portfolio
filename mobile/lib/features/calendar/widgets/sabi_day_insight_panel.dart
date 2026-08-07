import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../models/calendar_models.dart';

// ── Sabi 日別インサイトパネル（_DailyTaskSection内のSabi吹き出し用に保持）────────
class SabiDayInsightPanel extends StatelessWidget {
  const SabiDayInsightPanel({super.key, required this.day});
  final CalendarDay day;

  String _generateMessage(AppLocalizations l10n) {
    final d = l10n.calendarSabiInsightDateFormat(day.date.month, day.date.day);

    if (day.total == 0) {
      // 【chore】CLAUDE.md 紳士的トーン準拠（旧「〜だ」断定形を「〜ですね」に統一）
      return l10n.calendarSabiInsightNoHabitsSabi_message(d);
    }
    if (day.pct == 100) {
      return l10n.calendarSabiInsightAllCompletedSabi_message(d);
    }
    if (day.pct == 0) {
      return l10n.calendarSabiInsightNoneCompletedSabi_message(d);
    }

    final hasLegendary =
        day.habits.any((h) => h.difficulty == 'legendary' && h.done);
    if (hasLegendary) {
      return l10n.calendarSabiInsightLegendaryDoneSabi_message(d);
    }

    if (day.pct >= 75) {
      return l10n.calendarSabiInsightMostlyCompletedSabi_message(d, day.completed);
    }
    if (day.pct >= 50) {
      return l10n.calendarSabiInsightHalfCompletedSabi_message(d);
    }
    return l10n.calendarSabiInsightLittleCompletedSabi_message(d);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border:
                  Border.all(color: AppTheme.primary.withValues(alpha: 0.25)),
            ),
            child: const Center(
              child: Text('🪶', style: TextStyle(fontSize: 18)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.07),
                border: Border.all(
                    color: AppTheme.primary.withValues(alpha: 0.18)),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(14),
                ),
              ),
              child: Text(
                _generateMessage(l10n),
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.8),
                  height: 1.6,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
