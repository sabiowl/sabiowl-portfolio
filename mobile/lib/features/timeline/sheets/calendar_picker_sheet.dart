import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';
import '../../../../core/router/app_router.dart';  // 【2026-06-29】kNavBarHeight
import '../../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../providers/timeline_provider.dart';

/// カレンダーから日付を選択するボトムシート。
///
/// 選択された日付を [selectedDateProvider] と [weekAnchorDateProvider] に反映し、
/// 自動的に閉じる。
class CalendarPickerSheet extends ConsumerStatefulWidget {
  const CalendarPickerSheet({super.key});

  @override
  ConsumerState<CalendarPickerSheet> createState() =>
      _CalendarPickerSheetState();
}

class _CalendarPickerSheetState extends ConsumerState<CalendarPickerSheet> {
  late DateTime _focusedDay;
  late DateTime _selectedDay;

  @override
  void initState() {
    super.initState();
    _selectedDay = ref.read(selectedDateProvider);
    _focusedDay  = _selectedDay;
  }

  void _onDaySelected(DateTime selected, DateTime focused) {
    final now      = DateTime.now();
    final today    = DateTime(now.year, now.month, now.day);
    final selNorm  = DateTime(selected.year, selected.month, selected.day);

    // 選択日を含む週のアンカーを計算（今日を基準に 7 日単位で最近接）
    final diffDays    = selNorm.difference(today).inDays;
    final anchorDiff  = (diffDays / 7).round() * 7;
    final newAnchor   = today.add(Duration(days: anchorDiff));

    ref.read(selectedDateProvider.notifier).state    = selNorm;
    ref.read(weekAnchorDateProvider.notifier).state  = newAnchor;
    Navigator.of(context).pop();
  }

  // 【2026-06-29】年間ジャンプ機能を一時無効化。
  // 症状: ヘッダー タップ → 年選択ダイアログ → 年選択で setState during build
  // + BOTTOM OVERFLOWED BY 99817 PIXELS の赤画面。
  // hotfix v1/v2 (addPostFrameCallback / Future.delayed(300ms)) では根絶できず、
  // TableCalendar 内部の PageView.jumpToPage と onPageChanged の同期発火が build
  // フェーズと衝突する経路が完全に潰しきれないため、年間ジャンプ機能自体を撤回。
  // 復活時は git history (2026-06-29 の関連コミット) から _showYearPicker /
  // _YearCell / onHeaderTapped を取り戻せる。将来対応案は table_calendar パッケージ
  // のバージョン更新か、TableCalendar を CalendarDatePicker 系に置き換える方向。

  @override
  Widget build(BuildContext context) {
    // 【2026-06-29】カレンダー下段が BottomNav に埋もれる問題の修正。
    // showModalBottomSheet は Overlay に挿入されるため、_ScaffoldWithBottomNav の
    // MediaQuery override (bottom += kNavBarHeight) が届かない。ここで明示的に
    // kNavBarHeight (60) + iOS SafeArea (~34) + 既存余白 24 の合計を下 padding に
    // 加算し、最下段の週 (12-18 等) がタップできる領域を確保する。
    final systemBottom = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E2E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(bottom: 24 + kNavBarHeight + systemBottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ハンドルバー
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 4),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color:        Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // タイトル
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              AppLocalizations.of(context)!.timelineCalendarPickerSheetTitle,
              style: TextStyle(
                color:      Colors.white,
                fontSize:   16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          // カレンダー
          TableCalendar(
            firstDay:  DateTime(2020),
            lastDay:   DateTime(2030),
            focusedDay: _focusedDay,
            selectedDayPredicate: (day) => isSameDay(day, _selectedDay),
            onDaySelected: (selected, focused) {
              setState(() {
                _selectedDay = selected;
                _focusedDay  = focused;
              });
              _onDaySelected(selected, focused);
            },
            onPageChanged: (focused) {
              setState(() => _focusedDay = focused);
            },
            // 【2026-06-29】年間ジャンプ (onHeaderTapped 経由の年選択ダイアログ) は
            // TableCalendar 内部の PageView.jumpToPage と setState during build の
            // 衝突が解消できないため一時無効化。復活は git history から。

            // ── スタイル ──────────────────────────────────────────────────
            calendarStyle: CalendarStyle(
              // 選択日
              selectedDecoration: const BoxDecoration(
                color:  AppTheme.primary,
                shape:  BoxShape.circle,
              ),
              selectedTextStyle: const TextStyle(
                color:      Colors.white,
                fontWeight: FontWeight.bold,
              ),
              // 今日
              todayDecoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.35),
                shape: BoxShape.circle,
              ),
              todayTextStyle: const TextStyle(
                color:      Colors.white,
                fontWeight: FontWeight.bold,
              ),
              // 通常日
              defaultTextStyle:
                  const TextStyle(color: Colors.white70),
              weekendTextStyle:
                  const TextStyle(color: Colors.white54),
              outsideTextStyle:
                  const TextStyle(color: Colors.white24),
              // セル背景
              cellMargin: const EdgeInsets.all(4),
            ),

            headerStyle: HeaderStyle(
              formatButtonVisible:   false,
              titleCentered:         true,
              leftChevronIcon: const Icon(
                  Icons.chevron_left, color: Colors.white54),
              rightChevronIcon: const Icon(
                  Icons.chevron_right, color: Colors.white54),
              // 【2026-06-29】年間ジャンプ機能撤回に伴い、旧「タップ可能感」の下線装飾は削除。
              titleTextStyle: const TextStyle(
                color:      Colors.white,
                fontSize:   15,
                fontWeight: FontWeight.w600,
              ),
              decoration: const BoxDecoration(
                color: Color(0xFF252535),
              ),
            ),

            daysOfWeekStyle: const DaysOfWeekStyle(
              weekdayStyle: TextStyle(
                color:      Colors.white38,
                fontSize:   12,
                fontWeight: FontWeight.w600,
              ),
              weekendStyle: TextStyle(
                color:      Colors.white24,
                fontSize:   12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

