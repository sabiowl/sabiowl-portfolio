import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
// timeline_models.dart は timeline_provider.dart から re-export されるため直接 import 不要
import '../providers/timeline_provider.dart';
import '../widgets/timeline_date_strip.dart';
import '../widgets/timeline_body.dart';
import '../widgets/timeline_empty_state.dart';
import '../widgets/timeline_loading_skeleton.dart';
import '../sheets/calendar_picker_sheet.dart';
import '../../../core/services/notification_service.dart';
import 'add_event_page.dart' show showAddEventModal;
import '../../calendar/providers/calendar_provider.dart';
import '../../habits/providers/habits_provider.dart';  // 【FEAT-273】playerNotifierProvider

// ── タイムラインページ ────────────────────────────────────────────────────────

/// タイムラインダッシュボード
///
/// ホーム画面の SabiMessagePanel 直下に配置される。
/// ┌─────────────────────────────────┐
/// │  セクションヘッダー（＋追加ボタン）│
/// │  TimelineDateStrip              │  ← 週カレンダー
/// │  TimelineBody（追加行付き）      │  ← 垂直タイムライン
/// └─────────────────────────────────┘
class TimelineDashboard extends ConsumerStatefulWidget {
  const TimelineDashboard({super.key});

  @override
  ConsumerState<TimelineDashboard> createState() => _TimelineDashboardState();
}

class _TimelineDashboardState extends ConsumerState<TimelineDashboard> {
  Timer? _timer;
  // 【FEAT-227】毎分 setState でツリー全体（_TimelineSectionHeader / TimelineDateStrip /
  // TimelineBody）を再 build していたのを、ValueNotifier 化して TimelineBody 内部の
  // 現在時刻インジケーター行のみ再描画するように変更。
  final ValueNotifier<DateTime> _now = ValueNotifier(DateTime.now());

  @override
  void initState() {
    super.initState();
    // 毎分 ValueNotifier だけ更新（祖先ツリーの再 build は発生しない）
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      _now.value = DateTime.now();
    });
    // ── カレンダー「ホームへ」遷移後の初期値チェック ──────────────────────
    // ShellRoute（非 StatefulShellRoute）ではタブ切替のたびにウィジェットが
    // 再生成される。ref.listen は「登録後の変化」しか検知しないため、
    // provider がセット済みの状態で生成された場合に発火しない。
    // そのため initState で現在値を明示的に読み取り、非 null なら適用する。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final jumpDate = ref.read(calendarJumpDateProvider);
      if (jumpDate != null) {
        final normalized =
            DateTime(jumpDate.year, jumpDate.month, jumpDate.day);
        ref.read(selectedDateProvider.notifier).state   = normalized;
        ref.read(weekAnchorDateProvider.notifier).state = normalized;
        // 消費済みにリセット（二重ジャンプ防止）
        ref.read(calendarJumpDateProvider.notifier).state = null;
        return; // 自動作成は今日以外の日付では不要
      }
      // 今日のデフォルトテンプレートを初回のみ自動作成
      final now   = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final selected = ref.read(selectedDateProvider);
      // 選択日が今日のときだけ自動作成
      if (selected == today) {
        ref.read(timelineAutoCreateProvider(today).future).catchError((_) {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _now.dispose();
    super.dispose();
  }

  // FEAT-174: BottomSheet → 全画面ページへ変更
  void _showDefaultsSheet(BuildContext context) {
    context.push(AppRoutes.timelineDefaults);
  }

  void _showCalendarPickerModal(BuildContext context) {
    showModalBottomSheet<void>(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      builder: (_) => const CalendarPickerSheet(),
    );
  }

  void _showAddEventSheet(BuildContext context) {
    final selectedDate = ref.read(selectedDateProvider);
    showAddEventModal(context, selectedDate);
  }

  // FEAT-159: EditEventSheet（ボトムシート）→ EditEventPage（全画面）に変更
  void _showEditEventSheet(BuildContext context, TimelineEvent event) {
    // 【FEAT-426】Google カレンダー由来のイベントは Backend PK を持たないため
    // 編集画面（PATCH/DELETE 前提）には遷移できない。
    if (event.isGoogleOrigin) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.timelineDashboardGoogleEventEditSnackbarSabi_message,
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    context.push(AppRoutes.editEvent, extra: event);
  }

  @override
  Widget build(BuildContext context) {
    // FEAT-188: タイムラインはサーバー側ゲスト基盤で完全動作するため、
    // 旧 GuestLinkPromptCard 分岐は撤廃。ゲストでも実データで操作できる。

    // カレンダー画面の「ホームへ」ボタンで日付ジャンプ要求を受け取る
    ref.listen<DateTime?>(calendarJumpDateProvider, (_, jumpDate) {
      if (jumpDate == null) return;
      // postFrameCallback で描画後に状態を更新（build 中の setState 回避）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final normalized = DateTime(jumpDate.year, jumpDate.month, jumpDate.day);
        ref.read(selectedDateProvider.notifier).state   = normalized;
        ref.read(weekAnchorDateProvider.notifier).state = normalized;
        // 消費済みにリセット（二重ジャンプ防止）
        ref.read(calendarJumpDateProvider.notifier).state = null;
      });
    });

    final selectedDate = ref.watch(selectedDateProvider);
    final eventsAsync  = ref.watch(timelineEventsProvider(selectedDate));

    // ── 今日のイベントが更新されたらローカル通知を再スケジュール ──────
    // 【FEAT-273】設定 ON のユーザーには +15 分未完了リマインダーも追加スケジュール
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    ref.listen(timelineEventsProvider(today), (_, next) {
      next.whenData((events) {
        final player = ref.read(playerNotifierProvider).valueOrNull;
        NotificationService.scheduleTodayTimelineNotifications(
          events,
          includeUncompletedReminder:
              player?.timelineUncompletedReminderEnabled ?? false,
        );
      });
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // セクションヘッダー（追加ボタン + 設定歯車 + カレンダー）
        _TimelineSectionHeader(
          onAdd:      () => _showAddEventSheet(context),
          onSettings: () => _showDefaultsSheet(context),
          onCalendar: () => _showCalendarPickerModal(context),
        ),

        // 週カレンダーストリップ
        const TimelineDateStrip(),

        // タイムライン本体
        eventsAsync.when(
          loading: () => const TimelineLoadingSkeleton(),
          error:   (_, __) => TimelineEmptyState(
            onAdd: () => _showAddEventSheet(context),
          ),
          data: (events) => events.isEmpty
              ? TimelineEmptyState(onAdd: () => _showAddEventSheet(context))
              : TimelineBody(
                  events:           events,
                  now:              _now,
                  selectedDate:     selectedDate,
                  onAdd:            () => _showAddEventSheet(context),
                  onEventLongPress: (e) => _showEditEventSheet(context, e),
                ),
        ),
      ],
    );
  }
}

// ── セクションヘッダー ─────────────────────────────────────────────────────────

class _TimelineSectionHeader extends StatelessWidget {
  const _TimelineSectionHeader({
    required this.onAdd,
    required this.onSettings,
    required this.onCalendar,
  });

  final VoidCallback onAdd;
  final VoidCallback onSettings;
  final VoidCallback onCalendar;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
      child: Row(
        children: [
          const Icon(
            Icons.timeline_outlined,
            size:  16,
            color: Colors.white54,
          ),
          const SizedBox(width: 8),
          Text(
            AppLocalizations.of(context)!.timelineSectionHeaderLabel,
            style: const TextStyle(
              color:         Colors.white54,
              fontSize:      13,
              fontWeight:    FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          // 【FEAT-513 v1.1 hotfix 2026-07-31】旧「⚔️ N/3」battle_charges ミニ表示
          // (20260729 gameplay-review §2-1 案 B) は撤去。同じ情報が WorldFrame 直下
          // の「あと N 回の達成でオートバトルが始まりますよ 🪶」インジケーターに
          // 表示されるため、重複表示 (user 報告 2026-07-31) を解消。
          const Spacer(),
          // ── カレンダーアイコンボタン ──────────────────────────
          IconButton(
            icon: const Icon(
              Icons.calendar_month_outlined,
              size:  18,
              color: Colors.white24,
            ),
            tooltip:     AppLocalizations.of(context)!.timelineSectionHeaderCalendarTooltip,
            padding:     EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () {
              HapticFeedback.lightImpact();
              onCalendar();
            },
          ),
          // ── 設定歯車ボタン ────────────────────────────────────
          IconButton(
            icon: const Icon(
              Icons.settings_outlined,
              size:  18,
              color: Colors.white24,
            ),
            tooltip:     AppLocalizations.of(context)!.timelineSectionHeaderSettingsTooltip,
            padding:     EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () {
              HapticFeedback.lightImpact();
              onSettings();
            },
          ),
          const SizedBox(width: 4),
          // ── ピル型追加ボタン ──────────────────────────────────
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              onAdd();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color:        AppTheme.primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.add, size: 13, color: AppTheme.primary),
                  const SizedBox(width: 4),
                  Text(
                    AppLocalizations.of(context)!.timelineSectionHeaderAddButton,
                    style: const TextStyle(
                      color:      AppTheme.primary,
                      fontSize:   12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

