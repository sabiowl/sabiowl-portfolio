import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../models/calendar_models.dart';

// ── カレンダー日次ビュー タイムライン予定行 ───────────────────────────────────
class DailyTimelineRow extends StatelessWidget {
  final DailyTimeline item;
  final bool          done;
  final VoidCallback? onTap; // null = 操作不可（7日超の過去日）

  const DailyTimelineRow({
    super.key,
    required this.item,
    required this.done,
    this.onTap,
  });

  // カテゴリ → アイコン（FEAT-147: 11カテゴリ + 旧カテゴリ後方互換）
  static IconData _categoryIcon(String cat) => switch (cat) {
    'study'    => Icons.menu_book,
    'business' => Icons.work_outline,
    'exercise' => Icons.directions_run,
    'fitness'  => Icons.fitness_center,
    'beauty'   => Icons.spa,
    'health'   => Icons.favorite_border,
    'mental'   => Icons.self_improvement,
    'creative' => Icons.palette_outlined,
    'social'   => Icons.people_outline,
    'rest'     => Icons.bedtime_outlined,
    // 旧カテゴリ後方互換
    'habit'    => Icons.repeat_outlined,
    'work'     => Icons.work_outline,
    _          => Icons.event_outlined,
  };

  // カテゴリ → 色（FEAT-147: 11カテゴリ + 旧カテゴリ後方互換）
  static Color _categoryColor(String cat) => switch (cat) {
    'study'    => const Color(0xFF60A5FA),
    'business' => const Color(0xFF5B9BD5),
    'exercise' => const Color(0xFFF87171),
    'fitness'  => const Color(0xFFFB923C),
    'beauty'   => const Color(0xFFF472B6),
    'health'   => const Color(0xFF34D399),
    'mental'   => const Color(0xFFA78BFA),
    'creative' => const Color(0xFFFFD60A),
    'social'   => const Color(0xFFEC6EA0),
    'rest'     => const Color(0xFF64748B),
    // 旧カテゴリ後方互換
    'habit'    => AppTheme.primary,
    'work'     => Colors.blueGrey,
    _          => Colors.white38,
  };

  @override
  Widget build(BuildContext context) {
    final color = _categoryColor(item.category);
    final icon  = _categoryIcon(item.category);

    // 時刻テキスト（"09:00–10:00" or "09:00" or null）
    String? timeText;
    if (item.startTime != null && item.endTime != null) {
      timeText = '${item.startTime}–${item.endTime}';
    } else if (item.startTime != null) {
      timeText = item.startTime;
    }

    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          // カテゴリアイコン
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              color:  color.withValues(alpha: 0.12),
              shape:  BoxShape.circle,
              border: Border.all(color: color.withValues(alpha: 0.35)),
            ),
            child: Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: 10),
          // タイトル + 時刻
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  style: TextStyle(
                    color:           done ? Colors.white24 : Colors.white70,
                    fontSize:        13,
                    decoration:      done
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                    decorationColor: Colors.white24,
                  ),
                  child: Text(item.title, maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                if (timeText != null)
                  Text(
                    timeText,
                    style: TextStyle(
                      color:    done ? Colors.white12 : Colors.white38,
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
          // 完了チェックアイコン（onTap != null のときのみ表示）
          if (onTap != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onTap,
              behavior: HitTestBehavior.opaque,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  done
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  key:   ValueKey(done),
                  size:  18,
                  color: done ? AppTheme.primary : Colors.white24,
                ),
              ),
            ),
          ],
          // else: 何も表示しない（非当日はチェックアイコンなし・スペーサーなし）
        ],
      ),
    );

    if (onTap == null) return content;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: content,
    );
  }
}
