import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../providers/timeline_provider.dart';

/// 週間カレンダーストリップ（横スワイプで週移動）
///
/// - 左右スワイプで 1 週間単位にページングする（PageView）。
/// - 今日が表示されていない週では "今日" ピルボタンを表示する。
/// - [weekAnchorDateProvider] の外部変更（カレンダーピッカー等）にも追従する。
class TimelineDateStrip extends ConsumerStatefulWidget {
  const TimelineDateStrip({super.key});

  @override
  ConsumerState<TimelineDateStrip> createState() => _TimelineDateStripState();
}

class _TimelineDateStripState extends ConsumerState<TimelineDateStrip> {
  // 十分大きい初期ページ（今日を基準の 0 に相当）
  static const _kInitialPage = 10000;

  late final PageController _pageCtrl;
  late final DateTime _today;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _today = DateTime(now.year, now.month, now.day);

    // 現在のアンカーから初期ページを計算（カレンダーピッカー後に再表示する場合に対応）
    final currentAnchor = ref.read(weekAnchorDateProvider);
    final diffDays      = currentAnchor.difference(_today).inDays;
    final initialPage   = _kInitialPage + (diffDays / 7).round();
    _pageCtrl = PageController(initialPage: initialPage);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  // ── ヘルパー ──────────────────────────────────────────────────────────────

  /// ページインデックス → アンカー日付
  DateTime _anchorForPage(int page) =>
      _today.add(Duration(days: (page - _kInitialPage) * 7));

  /// アンカー日付 → ページインデックス
  int _pageForAnchor(DateTime anchor) {
    final diff = anchor.difference(_today).inDays;
    return _kInitialPage + (diff / 7).round();
  }

  /// アンカーを中央とした 7 日間
  List<DateTime> _weekFor(DateTime anchor) =>
      List.generate(7, (i) => anchor.add(Duration(days: i - 3)));

  /// 今日がこの週に含まれているか
  bool _isTodayInWeek(DateTime anchor) {
    return _weekFor(anchor).any((d) =>
        d.year == _today.year &&
        d.month == _today.month &&
        d.day == _today.day);
  }

  // ── ビルド ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final anchor       = ref.watch(weekAnchorDateProvider);
    final selectedDate = ref.watch(selectedDateProvider);

    // 外部からアンカーが変更されたとき（カレンダーピッカー・"今日" ボタン）
    // に対応して PageView をアニメーション移動する。
    ref.listen<DateTime>(weekAnchorDateProvider, (_, next) {
      if (!_pageCtrl.hasClients) return;
      final targetPage  = _pageForAnchor(next);
      final currentPage = _pageCtrl.page?.round() ?? _kInitialPage;
      if (targetPage != currentPage) {
        _pageCtrl.animateToPage(
          targetPage,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── ヘッダー行: 月/年 + 今日ピル ─────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 12, 8),
          child: Row(
            children: [
              Text(
                AppLocalizations.of(context)!.timelineDateStripMonthYear(
                    selectedDate.month, selectedDate.year),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              // 今日が表示されていないときだけ "今日" ピルを表示
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _isTodayInWeek(anchor)
                    ? const SizedBox.shrink()
                    : GestureDetector(
                        key: const ValueKey('today_pill'),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          ref.read(weekAnchorDateProvider.notifier).state =
                              _today;
                          ref.read(selectedDateProvider.notifier).state =
                              _today;
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color:
                                    AppTheme.primary.withValues(alpha: 0.4)),
                          ),
                          child: Text(
                            AppLocalizations.of(context)!.timelineDateStripTodayLabel,
                            style: const TextStyle(
                              color:      AppTheme.primary,
                              fontSize:   11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),

        // ── PageView（横スワイプで週移動） ────────────────────────────────
        SizedBox(
          height: 68,
          child: PageView.builder(
            controller: _pageCtrl,
            onPageChanged: (page) {
              final newAnchor = _anchorForPage(page);
              ref.read(weekAnchorDateProvider.notifier).state = newAnchor;

              // 選択日が新しい週に含まれない場合はアンカー日（中央）に移動
              final isSelInWeek = _weekFor(newAnchor).any((d) =>
                  d.year  == selectedDate.year &&
                  d.month == selectedDate.month &&
                  d.day   == selectedDate.day);
              if (!isSelInWeek) {
                ref.read(selectedDateProvider.notifier).state = newAnchor;
              }
            },
            itemBuilder: (context, page) {
              final pageAnchor = _anchorForPage(page);
              final week       = _weekFor(pageAnchor);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: week.map((date) {
                    final isSel = date.day   == selectedDate.day &&
                        date.month == selectedDate.month &&
                        date.year  == selectedDate.year;
                    final isTod = date.day   == _today.day &&
                        date.month == _today.month &&
                        date.year  == _today.year;
                    return Expanded(
                      child: _DayCell(
                        date:       date,
                        isSelected: isSel,
                        isToday:    isTod,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          ref.read(selectedDateProvider.notifier).state = date;
                        },
                      ),
                    );
                  }).toList(),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ── 日付セル ─────────────────────────────────────────────────────────────────

class _DayCell extends ConsumerWidget {
  const _DayCell({
    required this.date,
    required this.isSelected,
    required this.isToday,
    required this.onTap,
  });

  final DateTime date;
  final bool isSelected;
  final bool isToday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final weekdayLabels = [
      l10n.timelineDateStripWeekdayMon,
      l10n.timelineDateStripWeekdayTue,
      l10n.timelineDateStripWeekdayWed,
      l10n.timelineDateStripWeekdayThu,
      l10n.timelineDateStripWeekdayFri,
      l10n.timelineDateStripWeekdaySat,
      l10n.timelineDateStripWeekdaySun,
    ];
    final eventsAsync = ref.watch(timelineEventsProvider(date));

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primary.withValues(alpha: 0.25)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: isSelected
              ? Border.all(color: AppTheme.primary.withValues(alpha: 0.6))
              : Border.all(color: Colors.transparent),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 曜日ラベル
            Text(
              weekdayLabels[date.weekday - 1],
              style: TextStyle(
                color: isSelected ? AppTheme.primary : Colors.white38,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            // 日付数字
            Text(
              '${date.day}',
              style: TextStyle(
                color: isToday
                    ? Colors.white
                    : (isSelected ? Colors.white : Colors.white60),
                fontSize: 16,
                fontWeight: isSelected || isToday
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
            const SizedBox(height: 4),
            // ドットインジケーター
            eventsAsync.when(
              data:    (events) => _DotIndicator(events: events),
              loading: () => const SizedBox(height: 6),
              error:   (_, __) => const SizedBox(height: 6),
            ),
          ],
        ),
      ),
    );
  }
}

// ── ドットインジケーター ──────────────────────────────────────────────────────

class _DotIndicator extends StatelessWidget {
  const _DotIndicator({required this.events});
  final List<TimelineEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) return const SizedBox(height: 6, width: 6);

    final allDone  = events.every((e) => e.isCompleted);
    final noneDone = events.every((e) => !e.isCompleted);

    final color = allDone
        ? const Color(0xFF4CAF93) // 全完了 → teal
        : noneDone
            ? AppTheme.primary    // 未着手 → primary
            : Colors.amber;       // 途中   → amber

    return Container(
      width:  6,
      height: 6,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}
