import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../models/calendar_models.dart';

// DayDetailCard は DailyTaskSection（CAL-01）に統合されたため現在未使用。
// ignore: unused_element
class DayDetailCard extends StatelessWidget {
  final CalendarDay day;
  const DayDetailCard({super.key, required this.day});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text(
                    l10n.calendarDailyTaskDateLabel(day.date.month, day.date.day),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13),
                  ),
                  if (day.isRestDay) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.indigo.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.indigo.withValues(alpha: 0.6)),
                      ),
                      child: Text(
                        l10n.calendarDayDetailRestDayBadge,
                        style: const TextStyle(color: Colors.white70, fontSize: 10),
                      ),
                    ),
                  ],
                ],
              ),
              Text(
                l10n.calendarDayDetailCompletionLabel(day.completed, day.total),
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
              ),
            ],
          ),
          if (day.exp > 0) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.expColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.expColor.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('⚡', style: TextStyle(fontSize: 14)),
                  const SizedBox(width: 4),
                  Text(
                    '+${day.exp} EXP',
                    style: const TextStyle(
                      color: AppTheme.expColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (day.habits.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...day.habits.map((h) {
              // ── 難易度スタイル定義 ──────────────────────
              final (diffColor, diffSize, diffPrefix) = switch (h.difficulty) {
                'legendary' => (const Color(0xFFFFB300), 15.0, '🌟 '),
                'hard'      => (AppTheme.primary,         14.0, '🔥 '),
                'normal'    => (Colors.white70,           13.0, ''),
                _           => (Colors.white38,           12.0, ''),  // easy
              };
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(
                      h.done ? Icons.check_circle : Icons.radio_button_unchecked,
                      size: 16,
                      color: h.done
                          ? (h.difficulty == 'legendary'
                              ? const Color(0xFFFFB300)
                              : AppTheme.expColor)
                          : Colors.white24,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$diffPrefix${h.name}',
                        style: TextStyle(
                          color: h.done ? diffColor : Colors.white38,
                          fontSize: diffSize,
                          fontWeight: h.difficulty == 'legendary'
                              ? FontWeight.bold
                              : FontWeight.normal,
                          decoration:
                              h.done ? TextDecoration.lineThrough : null,
                        ),
                      ),
                    ),
                    if (h.count > 1)
                      Text('×${h.count}',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11)),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}
