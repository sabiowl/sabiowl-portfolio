import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../models/calendar_models.dart';

// ── 習慣別ストリーク ────────────────────────────────────────────
class HabitStreakList extends StatelessWidget {
  final StreakData streak;
  const HabitStreakList({super.key, required this.streak});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (streak.habitStreaks.isEmpty) return const SizedBox.shrink();
    // 【2026-06-27】呼び出し側 (calendar_tab.dart のポップアップ) がヘッダーで
    // 「習慣別ストリーク」を表示するようになったため、内部のセクションタイトルは
    // 重複回避のため撤去。本 widget はリスト本体のみを描画する。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...streak.habitStreaks.map((h) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(h.name,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13)),
                  ),
                  Row(
                    children: [
                      const Icon(Icons.local_fire_department,
                          size: 14, color: Colors.orange),
                      const SizedBox(width: 3),
                      Text(l10n.calendarHabitStreakCurrentDays(h.streak),
                          style: const TextStyle(
                              color: Colors.orange,
                              fontSize: 12,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(width: 10),
                      Text(l10n.calendarHabitStreakBestDays(h.bestStreak),
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11)),
                    ],
                  ),
                ],
              ),
            )),
      ],
    );
  }
}
