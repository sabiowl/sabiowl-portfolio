import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../timeline/models/timeline_models.dart' show kTimelineCardColors;
import '../models/calendar_models.dart';

// ── カレンダーグリッド ──────────────────────────────────────────
class CalendarGrid extends StatelessWidget {
  final CalendarData cal;
  final DateTime? selectedDate;
  final void Function(DateTime) onDateSelected;

  const CalendarGrid({
    super.key,
    required this.cal,
    required this.selectedDate,
    required this.onDateSelected,
  });

  @override
  Widget build(BuildContext context) {
    final l10n        = AppLocalizations.of(context)!;
    final dayMap      = cal.dayMap;
    final firstDay    = DateTime(cal.year, cal.month, 1);
    final startOffset = firstDay.weekday % 7; // weekday: 1=月→7=日 → %7 で 0=日
    final daysInMonth = DateUtils.getDaysInMonth(cal.year, cal.month);
    final totalCells  = startOffset + daysInMonth;
    final weekCount   = (totalCells / 7).ceil();

    final dowLabels = [
      l10n.calendarGridDowSun,
      l10n.calendarGridDowMon,
      l10n.calendarGridDowTue,
      l10n.calendarGridDowWed,
      l10n.calendarGridDowThu,
      l10n.calendarGridDowFri,
      l10n.calendarGridDowSat,
    ];

    // 週ごとの Row を組み立て、行間に罫線を挟む
    final weekRows = <Widget>[];
    for (var week = 0; week < weekCount; week++) {
      // 週の区切り線（先頭週の前は不要）
      if (week > 0) {
        weekRows.add(Divider(
          height: 1,
          thickness: 0.5,
          color: Colors.white.withValues(alpha: 0.08),
        ));
      }

      // 7列分のセルを生成
      final cells = List.generate(7, (col) {
        final idx = week * 7 + col;
        // 当月範囲外のセルは空白
        if (idx < startOffset || idx >= totalCells) {
          return const Expanded(child: SizedBox());
        }
        final dayNum     = idx - startOffset + 1;
        final date       = DateTime(cal.year, cal.month, dayNum);
        final data       = dayMap[date];
        final isSelected = selectedDate != null &&
            selectedDate!.year  == date.year  &&
            selectedDate!.month == date.month &&
            selectedDate!.day   == date.day;

        return Expanded(
          child: AspectRatio(
            aspectRatio: 0.58, // セルサイズを拡張0.62→0.58
            child: GestureDetector(
              onTap: () => onDateSelected(date),
              child: DayCell(
                dayNum:            dayNum,
                data:              data,
                isSelected:        isSelected,
                todosPending:      data?.todosPending      ?? 0,
                todosHighPriority: data?.todosHighPriority ?? false,
              ),
            ),
          ),
        );
      });

      weekRows.add(Row(children: cells));
    }

    return Column(
      children: [
        // 曜日ヘッダー
        Row(
          children: dowLabels
              .map((l) => Expanded(
                    child: Center(
                      child: Text(l,
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.white.withValues(alpha: 0.4),
                              fontWeight: FontWeight.bold)),
                    ),
                  ))
              .toList(),
        ),
        // ヘッダー直下の罫線
        Divider(
          height: 8,
          thickness: 0.5,
          color: Colors.white.withValues(alpha: 0.08),
        ),
        // 週ごとの行（罫線挟み）
        ...weekRows,
      ],
    );
  }
}

class DayCell extends StatelessWidget {
  final int dayNum;
  final CalendarDay? data;
  final bool isSelected;
  final int  todosPending;
  final bool todosHighPriority;

  const DayCell({
    super.key,
    required this.dayNum,
    required this.data,
    required this.isSelected,
    this.todosPending     = 0,
    this.todosHighPriority = false,
  });

  @override
  Widget build(BuildContext context) {
    final isFuture  = data?.isFuture  ?? true;
    final isToday   = data?.isToday   ?? false;
    final isRestDay = data?.isRestDay ?? false;
    final pct       = data?.pct ?? 0;

    // 選択中はprimaryで塗りつぶす（CAL-01）
    Color fillColor;
    if (isSelected) {
      fillColor = AppTheme.primary;
    } else if (isRestDay) {
      fillColor = Colors.indigo.withValues(alpha: 0.30);
    } else if (!isFuture && data != null && data!.total > 0) {
      fillColor = switch (pct) {
        100 => AppTheme.expColor.withValues(alpha: 0.85),
        75  => AppTheme.expColor.withValues(alpha: 0.55),
        50  => AppTheme.primary.withValues(alpha: 0.5),
        25  => AppTheme.primary.withValues(alpha: 0.25),
        _   => Colors.white.withValues(alpha: 0.05),
      };
    } else {
      fillColor = Colors.transparent;
    }

    final border = isSelected
        ? Border.all(color: Colors.white, width: 1.5)
        : isToday
            ? Border.all(color: Colors.white54, width: 1.5)
            : isRestDay
                ? Border.all(color: Colors.indigo.withValues(alpha: 0.7), width: 1)
                : null;

    // FEAT-108: 月次グリッドにはタイムライン予定のみ表示。
    // 習慣達成状況は日付サークルの塗り（pct ベースの色）で引き続き確認できる。
    // 未来日も予定があればチップを出す（タイムラインは予定リスト性質のため）。
    final events       = data?.timelineEvents ?? const <CalendarTimelineEvent>[];
    final eventsToShow = events.take(2).toList();
    final eventOverflow = events.length - eventsToShow.length;

    return Container(
      // 選択時: セル全体を枠で囲む
      decoration: isSelected
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppTheme.primary,
                width: 1.5,
              ),
              color: AppTheme.primary.withValues(alpha: 0.08),
            )
          : null,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
        // 日付サークル（上部に配置）
        const SizedBox(height: 4),
        Center(
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color:  fillColor,
              shape:  BoxShape.circle,
              border: border,
            ),
            child: Center(
              child: isRestDay && !isToday
                  ? const Text('🌙', style: TextStyle(fontSize: 8))
                  : Text(
                      '$dayNum',
                      style: TextStyle(
                        fontSize: 10,
                        color: isSelected
                            ? Colors.white
                            : isFuture
                                ? Colors.white24
                                : isToday
                                    ? Colors.white
                                    : Colors.white70,
                        fontWeight: isSelected || isToday
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
          ),
          ),
        ),
        const SizedBox(height: 2),
        // FEAT-108: タイムライン予定チップ（最大 2 件）
        ...eventsToShow.map((e) => TimelineEventChip(event: e)),
        // オーバーフロー表示
        if (eventOverflow > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              '+$eventOverflow',
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 8,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
          ),
      ],
      ),
    );
  }
}

/// 達成率 + Todo 優先度の複合ドット表示（CAL-01）
class DotRow extends StatelessWidget {
  final int  pct;
  final int  todosPending;
  final bool todosHighPriority;

  const DotRow({
    super.key,
    required this.pct,
    this.todosPending     = 0,
    this.todosHighPriority = false,
  });

  @override
  Widget build(BuildContext context) {
    // 習慣達成ドット（最大 2 個）
    final habitColor = pct >= 75
        ? AppTheme.expColor
        : pct >= 50
            ? AppTheme.primary
            : Colors.white38;
    final habitCount = pct >= 75 ? 2 : pct >= 25 ? 1 : 0;

    // Todo ドット（高優先度 → 赤、それ以外 → オレンジ、1 個）
    final todoColor = todosPending > 0
        ? (todosHighPriority ? Colors.redAccent : Colors.orange)
        : null;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ...List.generate(
          habitCount,
          (_) => Container(
            width: 3, height: 3,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(color: habitColor, shape: BoxShape.circle),
          ),
        ),
        if (todoColor != null)
          Container(
            width: 3, height: 3,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(color: todoColor, shape: BoxShape.circle),
          ),
      ],
    );
  }
}

/// カレンダーグリッドセル内のタイムライン予定チップ（FEAT-108）
class TimelineEventChip extends StatelessWidget {
  final CalendarTimelineEvent event;
  const TimelineEventChip({super.key, required this.event});

  // カテゴリ → チップ色（kTimelineCardColors と統一して TimelineDashboard と整合）
  static Color _categoryColor(String category) {
    return kTimelineCardColors[category] ?? const Color(0xFF78909C);
  }

  @override
  Widget build(BuildContext context) {
    final baseColor = _categoryColor(event.category);
    final bgColor   = event.isCompleted
        ? baseColor.withValues(alpha: 0.80)
        : baseColor.withValues(alpha: 0.30);
    final textColor = event.isCompleted ? Colors.white : Colors.white60;

    // タイトルは最大 5 文字 + 省略記号
    final label = event.title.length > 5
        ? '${event.title.substring(0, 5)}…'
        : event.title;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      decoration: BoxDecoration(
        color:        bgColor,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(
          color:      textColor,
          fontSize:   8,
          height:     1.1,
          fontWeight: event.isCompleted ? FontWeight.bold : FontWeight.normal,
        ),
        overflow: TextOverflow.clip,
        maxLines: 1,
      ),
    );
  }
}
