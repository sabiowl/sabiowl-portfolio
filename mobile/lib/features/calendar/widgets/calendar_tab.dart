import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_loading_skeleton.dart';  // FEAT-218
import '../models/calendar_models.dart';
import '../providers/calendar_provider.dart';
import 'calendar_grid.dart';
import 'daily_task_section.dart';
import 'monthly_summary_card.dart';
import 'habit_streak_list.dart';

String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}'
    '-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

class CalendarTab extends ConsumerWidget {
  final int year;
  final int month;
  final DateTime? selectedDate;
  final void Function(DateTime) onDateSelected;

  const CalendarTab({
    super.key,
    required this.year,
    required this.month,
    required this.selectedDate,
    required this.onDateSelected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // P1-3: bootstrap で calendar + streak + daily を 1 リクエストで取得。
    // 旧来は 3 つの個別 provider を並行 watch していたが、初回ロード時に
    // 3 本の HTTP コールが走る冗長性を回避する。
    final dateStr = _dateStr(selectedDate ?? DateTime.now());
    final bootstrapAsync =
        ref.watch(calendarBootstrapProvider(year, month, dateStr));

    return bootstrapAsync.when(
      data: (bootstrap) => _buildContent(context, ref, bootstrap),
      loading: () => SabiWaitingPanel(message: l10n.calendarTabLoadingSabi_message),
      error: (e, _) => Center(
        // FEAT-186: 紳士的トーンへ統一
        child: Text(
          l10n.calendarTabErrorSabi_message,
          style: const TextStyle(color: Colors.white70),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    CalendarBootstrapData bootstrap,
  ) {
    final cal    = bootstrap.calendar;
    final streak = bootstrap.streak;
    final daily  = bootstrap.daily;
    final dateStr = _dateStr(selectedDate ?? DateTime.now());

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(calendarBootstrapProvider(year, month, dateStr));
      },
      child: ListView(
        // BUG-58: 上部余白を 16→8 に縮小してグリッド上の空白を詰める
        // ボトムナビバー（約56px）+ 余白 24px = 80px を確保して最終行の見切れを防ぐ
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 200),
        children: [
          // ── 月間サマリー (達成率 / 達成日数 / ストリーク) ───────────
          // 【ユーザー要望 2026-06-22】カレンダー画面上部に当月達成状況を
          // 表示。カレンダーグリッドの下から最上段に移動 (発見性向上)。
          // 【2026-06-27】ストリーク列タップで習慣別ストリーク詳細ポップアップを開く。
          // 旧 ListView 直置きの HabitStreakList はポップアップに統合 (重複回避)。
          MonthlySummaryCard(
            summary: cal.summary,
            onStreakTap: streak.habitStreaks.isEmpty
                ? null  // データなし時は tap 不能 (chevron も表示しない)
                : () => _showHabitStreakDialog(context, streak),
          ),
          const SizedBox(height: 16),

          CalendarGrid(
            key:            ValueKey('grid-${cal.year}-${cal.month}'),
            cal:            cal,
            selectedDate:   selectedDate,
            onDateSelected: onDateSelected,
          ),
          // ── 日別タスクセクション（CAL-01）─────────
          if (selectedDate != null) ...[
            // BUG-58: グリッドとタスクカード間の余白を 12→3 に縮小
            const SizedBox(height: 3),
            // P1-3: bootstrap 取得済みの daily を渡して二重フェッチ回避
            DailyTaskSection(date: selectedDate!, preloaded: daily),
          ],

          // 【ユーザー要望 2026-06-22】過去7日間グリッド (SevenDayGrid) を廃止。
          // 【ユーザー要望 2026-06-27】習慣別ストリーク (HabitStreakList) を画面下部
          // 直置きからストリーク tap ポップアップに移行。発見性は MonthlySummaryCard
          // 内の chevron で確保しつつ、画面下部のスクロール負荷を軽減する。
        ],
      ),
    );
  }

  /// 【2026-06-27】習慣別ストリーク詳細ポップアップを表示。
  ///
  /// ShellRoute 配下なので showDialog の `builder` 引数 `dialogContext` を使い、
  /// Navigator.pop はそれで行う (BUG-138 / FEAT-215 規律)。
  /// HabitStreakList が増えすぎても閲覧できるよう ConstrainedBox + SingleChildScrollView
  /// で縦スクロール可能にする。
  void _showHabitStreakDialog(BuildContext context, StreakData streak) {
    final l10n = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.of(dialogContext).size;
        return Dialog(
          backgroundColor: AppTheme.card,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: size.height * 0.72,  // 画面 72% を上限にしてスクロール
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── ヘッダー (タイトル + 閉じる) ──────────────────
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.calendarTabHabitStreakDialogTitle,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        tooltip: l10n.commonClose,
                        splashRadius: 20,
                        onPressed: () => Navigator.pop(dialogContext),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // ── スクロール領域 ───────────────────────────────
                  Flexible(
                    child: SingleChildScrollView(
                      child: HabitStreakList(streak: streak),
                    ),
                  ),
                  // ── 閉じる (主動作) ──────────────────────────────
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.primary,
                      ),
                      child: Text(l10n.commonClose),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
