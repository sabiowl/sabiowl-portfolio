import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../models/calendar_models.dart';
import '../providers/calendar_provider.dart';
import '../../habits/providers/apply_completion_result.dart';
import '../../habits/providers/habits_provider.dart';
// 【FEAT-220】Calendar provider 統合: timelineEventsProvider を invalidate 対象に追加
import '../../timeline/providers/timeline_provider.dart'
    show timelineServiceProvider, timelineEventsProvider;
import 'daily_timeline_row.dart';

Color _dueDateColor(DateTime dueDate, DateTime selectedDate) {
  if (dueDate.isBefore(selectedDate)) return Colors.redAccent;
  if (dueDate.isAtSameMomentAs(selectedDate)) return Colors.orange;
  return Colors.white38;
}

// ── 日別タスクセクション（CAL-01）────────────────────────────────
class DailyTaskSection extends ConsumerWidget {
  final DateTime date;

  /// 【FEAT-235】上位（CalendarTab 等）が bootstrap で取得済みの DailyData を渡す。
  /// FEAT-220 で `dailyDataProvider` を deprecated 化し、FEAT-235 で完全削除した
  /// ため、本 widget は preloaded を **必須** で受け取る前提で動作する。
  final DailyData preloaded;

  const DailyTaskSection({
    super.key,
    required this.date,
    required this.preloaded,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 【FEAT-235】preloaded は必須なので fallback 経路は削除済み。
    // 旧 `dailyDataProvider` watch + `SabiWaitingPanel` / `SabiErrorChip` の
    // loading/error 表示も削除（preloaded で確定値を渡される前提）。
    return DailyTaskCard(daily: preloaded);
  }
}

class DailyTaskCard extends ConsumerStatefulWidget {
  final DailyData daily;
  const DailyTaskCard({super.key, required this.daily});

  @override
  ConsumerState<DailyTaskCard> createState() => _DailyTaskCardState();
}

class _DailyTaskCardState extends ConsumerState<DailyTaskCard> {
  // 楽観的 UI 更新: タップ直後にローカルで done 状態を先行表示
  final _optimisticallyDone   = <int>{};  // done にしたもの
  final _optimisticallyUndone = <int>{};  // undo したもの

  // ── 習慣 楽観的 UI ──────────────────────────────────────────────────────
  final _optimisticallyDoneHabits   = <int>{};
  final _optimisticallyUndoneHabits = <int>{};

  // ── タイムライン楽観的 UI ────────────────────────────────────────────────
  final _optimisticallyCompletedTimeline   = <int>{};
  final _optimisticallyUncompletedTimeline = <int>{};

  // ── 習慣 楽観的状態判定 ──────────────────────────────────────────────────
  bool _isHabitDone(DailyHabit habit) {
    if (_optimisticallyUndoneHabits.contains(habit.id)) return false;
    if (_optimisticallyDoneHabits.contains(habit.id))   return true;
    return habit.done;
  }

  // 【2026-07-02 dead code cleanup】旧 _toggleHabit メソッド (31 行) 削除。
  // 呼び出し元ゼロで dead code 化していた (前回レビュー 6/29 から継続指摘)。
  // 習慣のトグルは home_page 側の UI 経由に一本化されており、daily_task_section
  // での二重経路は既に廃止済。_isHabitDone は _optimistically*Habits 経路の
  // 状態確認で使われる可能性があるため残置。

  bool _isTimelineDone(DailyTimeline item) {
    if (_optimisticallyUncompletedTimeline.contains(item.id)) return false;
    if (_optimisticallyCompletedTimeline.contains(item.id))   return true;
    return item.isCompleted;
  }

  Future<void> _toggleTimeline(DailyTimeline item) async {
    final l10n = AppLocalizations.of(context)!;
    final isDone = _isTimelineDone(item);
    // 楽観的更新
    setState(() {
      if (isDone) {
        _optimisticallyCompletedTimeline.remove(item.id);
        _optimisticallyUncompletedTimeline.add(item.id);
      } else {
        _optimisticallyUncompletedTimeline.remove(item.id);
        _optimisticallyCompletedTimeline.add(item.id);
      }
    });
    HapticFeedback.lightImpact();

    try {
      if (!isDone) {
        // 完了: 専用エンドポイント
        final reward = await ref
            .read(timelineServiceProvider)
            .completeEventWithReward(item.id);
        // 【BUG-150 (2026-08-29)】レスポンス → provider の配線は共有関数 1 箇所。
        // 🔴 旧実装はトーストとフレンドギフトの 2 つしか拾っておらず、
        // **ログインボーナスとかけらを落としていた** —— どちらも Backend では
        // 配布済みなので、カレンダーから初回達成した日は二度と出なかった。
        applyTimelineReward(ref.read, reward);
        // 【FEAT-419 (2026-06-10)】予定時刻 ±15 分以内ボーナスの SnackBar 通知
        if (mounted) {
          final message = reward.onTimeBonusAwarded
              ? l10n.timelineEventCardOnTimeBonusSnackbarSabi_message(reward.onTimeBonusCoin)
              : l10n.timelineEventCardCompletedSnackbarSabi_message;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        // 未完了に戻す: 専用 uncomplete エンドポイント（BUG-B）
        await ref
            .read(timelineServiceProvider)
            .uncompleteEvent(item.id);
      }
      // 【FEAT-220】Calendar provider 統合: bootstrap + timelineEvents に統一
      ref.invalidate(calendarBootstrapProvider);
      ref.invalidate(timelineEventsProvider);
    } catch (_) {
      // 楽観的更新を元に戻す
      setState(() {
        _optimisticallyCompletedTimeline.remove(item.id);
        _optimisticallyUncompletedTimeline.remove(item.id);
      });
    }
  }

  bool _isTodoDone(DailyTodo todo) {
    if (_optimisticallyUndone.contains(todo.id)) return false;
    if (_optimisticallyDone.contains(todo.id))   return true;
    return todo.done;
  }

  Future<void> _toggleTodo(DailyTodo todo) async {
    // 【BUG-150】await をまたぐので l10n は先に capture する (FEAT-489 Phase 2E)。
    final l10n = AppLocalizations.of(context)!;
    final isDone = _isTodoDone(todo);
    setState(() {
      if (isDone) {
        _optimisticallyDone.remove(todo.id);
        _optimisticallyUndone.add(todo.id);
      } else {
        _optimisticallyUndone.remove(todo.id);
        _optimisticallyDone.add(todo.id);
      }
    });
    HapticFeedback.lightImpact();     // FEAT-144: 追加

    try {
      if (isDone) {
        // BUG-56: habitsNotifierProvider は autoDispose のためカレンダータブにいる
        // 間に dispose されており、notifier 経由で呼ぶと state が空 → habit not found
        // で StateError が catch に飲み込まれて「サイレント失敗」していた。
        // habitsServiceProvider 経由ならプロバイダー状態に依存せず動作する。
        await ref.read(habitsServiceProvider).decrementCount(todo.id);
      } else {
        // BUG-56: 同上。サービス直呼びで完了 → EXP / レベルアップ通知も明示的に発火
        final prevLevel =
            ref.read(playerNotifierProvider).valueOrNull?.level ?? 0;
        final result = await ref
            .read(habitsServiceProvider)
            .incrementCount(todo.id, prevLevel: prevLevel);
        // 【BUG-150 (2026-08-29)】同上。旧実装はトーストとレベルアップの
        // 2 つしか拾っておらず、**ログインボーナス / かけら / 月次チケット /
        // フレンドギフト / 結晶 / 復帰 / 自動シールド / streak 系を全部
        // 落としていた**。habitsServiceProvider の直呼び自体は BUG-56 の
        // 回避策として正しいので、配線だけを共有関数に寄せる。
        await applyHabitLogResult(ref.read, result, l10n: l10n);
      }
      // 【FEAT-220】Calendar provider 統合: bootstrap + timelineEvents に統一
      ref.invalidate(calendarBootstrapProvider);
      ref.invalidate(timelineEventsProvider);
      // EXP / レベル表示の更新（サービス直呼びでは notifier 内 _refreshRelated が走らないため明示的に invalidate）
      ref.invalidate(playerNotifierProvider);
      ref.invalidate(habitsSummaryProvider);
    } catch (_) {
      // 楽観的更新を元に戻す
      setState(() {
        _optimisticallyDone.remove(todo.id);
        _optimisticallyUndone.remove(todo.id);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final daily = widget.daily;
    final d     = daily.date;
    final now   = DateTime.now();
    final todayD = DateTime(now.year, now.month, now.day);
    final diffDays = d.difference(todayD).inDays;

    final dateLabel = diffDays == 0
        ? l10n.calendarDailyTaskTodayLabel(d.month, d.day)
        : diffDays == 1
            ? l10n.calendarDailyTaskTomorrowLabel(d.month, d.day)
            : diffDays == -1
                ? l10n.calendarDailyTaskYesterdayLabel(d.month, d.day)
                : l10n.calendarDailyTaskDateLabel(d.month, d.day);

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
          // ヘッダー
          Row(
            children: [
              Text(
                dateLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              if (daily.isFuture) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(l10n.calendarDailyTaskScheduledBadge,
                      style: const TextStyle(color: Colors.white38, fontSize: 10)),
                ),
              ],
              const Spacer(),
              // ── ホーム遷移ボタン ─────────────────────────────────
              GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  ref
                      .read(calendarJumpDateProvider.notifier)
                      .state = widget.daily.date;
                  context.go(AppRoutes.home);
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppTheme.primary.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.open_in_new,
                        size: 11,
                        color: AppTheme.primary.withValues(alpha: 0.8),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        l10n.calendarDailyTaskGoHomeButton,
                        style: TextStyle(
                          color: AppTheme.primary.withValues(alpha: 0.8),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          // タイムラインセクション（BUG-17: ローカル / 外部カレンダーを分離表示）
          ...() {
            final localTimeline    = daily.timeline.where((t) => !t.isExternal).toList();
            final externalTimeline = daily.timeline.where((t) =>  t.isExternal).toList();
            // FEAT-144: ローカルタイムラインと今日のToDoは操作可能

            return <Widget>[
              // ── ローカルタイムライン ────────────────────────────────
              if (localTimeline.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(l10n.calendarDailyTaskTimelineSection,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 10, letterSpacing: 1)),
                const SizedBox(height: 6),
                ...localTimeline.map((item) {
                  final done = _isTimelineDone(item);
                  return DailyTimelineRow(
                    item:  item,
                    done:  done,
                    onTap: daily.isToday ? () => _toggleTimeline(item) : null, // FEAT-149: 当日のみ操作可能
                  );
                }),
              ],

              // ── 外部カレンダー（Google / Apple 等）─────────────────
              if (externalTimeline.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(l10n.calendarDailyTaskExternalCalendarSection,
                    style: const TextStyle(
                        color: Colors.lightBlueAccent,
                        fontSize: 10,
                        letterSpacing: 1)),
                const SizedBox(height: 6),
                // 外部イベントは同期コンテンツのため操作不可（読み取り専用）
                ...externalTimeline.map((item) {
                  final done = _isTimelineDone(item);
                  return DailyTimelineRow(
                    item:  item,
                    done:  done,
                    onTap: null,
                  );
                }),
              ],
            ];
          }(),
          // ToDo リスト（チェックボックス + アニメーション）
          if (daily.todos.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(l10n.calendarDailyTaskTodoSection,
                style: const TextStyle(
                    color: Colors.white38, fontSize: 10, letterSpacing: 1)),
            const SizedBox(height: 6),
            ...daily.todos.map((t) {
              final done = _isTodoDone(t);
              // BUG-54: 旧実装は daily.date.isAtSameMomentAs(todayD) で比較していたが、
              // DateTime.tryParse('YYYY-MM-DD') が UTC 解釈、todayD はローカル時刻のため
              // JST では 9 時間ずれて常に false → タップできなかった。
              // サーバ側 is_today フラグを使うことで TZ 差を無視して正確に判定する。
              final canToggleTodo = daily.isToday;
              return TodoRow(
                todo:  t,
                done:  done,
                date:  daily.date,
                onTap: canToggleTodo ? () => _toggleTodo(t) : null,
              );
            }),
          ],
          // 習慣リスト
          if (daily.habits.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(l10n.calendarDailyTaskHabitSection,
                style: const TextStyle(
                    color: Colors.white38, fontSize: 10, letterSpacing: 1)),
            const SizedBox(height: 6),
            ...daily.habits.map((h) {
              final done = _isHabitDone(h);
              return TaskRow(
                icon: done
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                iconColor: Colors.white24,
                name:     h.name,
                done:     done,
                category: h.category,
                onTap:    null,
              );
            }),
          ],
          if (daily.habits.isEmpty && daily.todos.isEmpty && daily.timeline.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                l10n.calendarDailyTaskEmptyState,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

class TaskRow extends StatelessWidget {
  final IconData      icon;
  final Color         iconColor;
  final String        name;
  final bool          done;
  final String        category;
  final Widget?       trailing;
  final VoidCallback? onTap; // null の場合はタップ不可

  const TaskRow({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.name,
    required this.done,
    required this.category,
    this.trailing,
    this.onTap,
  });

  // 【FEAT-307】FEAT-213 真実値 11 値全カバー。'メンタル' → '精神' /
  // '作業' → '仕事' / '交流' → '社交' は migration 0066 で死語化済。
  // 5/23 P0 積み残し解消で残り 7 カテゴリ (仕事/体力/美容/創造/社交/休息/その他) も追加。
  // 未知のカテゴリは default アームで安全にフォールバック (旧データ互換)。
  static IconData _categoryIcon(String cat) => switch (cat) {
    '運動'   => Icons.directions_run,
    '学習'   => Icons.menu_book,
    '仕事'   => Icons.work_outline,
    '体力'   => Icons.fitness_center,
    '美容'   => Icons.face_retouching_natural,
    '健康'   => Icons.favorite_border,
    '精神'   => Icons.self_improvement,
    '創造'   => Icons.brush_outlined,
    '社交'   => Icons.people_outline,
    '休息'   => Icons.bedtime_outlined,
    'その他' => Icons.label_outline,
    _        => Icons.repeat_outlined,
  };

  static Color _categoryColor(String cat) => switch (cat) {
    '運動'   => const Color(0xFFF87171),
    '学習'   => const Color(0xFF60A5FA),
    '仕事'   => const Color(0xFF5B9BD5),
    '体力'   => const Color(0xFFFF8A65),
    '美容'   => const Color(0xFFEC6EA0),
    '健康'   => const Color(0xFF34D399),
    '精神'   => const Color(0xFFA78BFA),
    '創造'   => const Color(0xFFFFB74D),
    '社交'   => const Color(0xFFEC6EA0),
    '休息'   => const Color(0xFF80CBC4),
    'その他' => const Color(0xFF78909C),
    _        => Colors.white38,
  };

  @override
  Widget build(BuildContext context) {
    final catColor = _categoryColor(category);
    final catIcon  = _categoryIcon(category);

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          // カテゴリ丸アイコン（DailyTimelineRow と同じサイズ・スタイル）
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              color:  catColor.withValues(alpha: 0.12),
              shape:  BoxShape.circle,
              border: Border.all(color: catColor.withValues(alpha: 0.35)),
            ),
            child: Icon(catIcon, size: 14, color: catColor),
          ),
          const SizedBox(width: 10),
          // 習慣名（Expanded）
          Expanded(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: TextStyle(
                color:           done ? Colors.white24 : Colors.white70,
                fontSize:        13,
                decoration:      done
                    ? TextDecoration.lineThrough
                    : TextDecoration.none,
                decorationColor: Colors.white24,
              ),
              child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
          // trailing（PriorityDot 等）
          if (trailing != null) ...[
            const SizedBox(width: 6),
            trailing!,
          ],
          // チェックアイコン（右端・onTap != null のときのみ表示）
          if (onTap != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onTap,
              behavior: HitTestBehavior.opaque,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  icon,
                  key:   ValueKey(icon),
                  size:  18,
                  color: iconColor,
                ),
              ),
            ),
          ],
          // else: 何も表示しない（習慣は常に onTap == null のためアイコンなし）
        ],
      ),
    );

    if (onTap == null) return row;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: row,
    );
  }
}

/// 完了アニメーション付き Todo 行
class TodoRow extends StatelessWidget {
  final DailyTodo     todo;
  final bool          done;
  final DateTime      date;   // dueDateColor 計算用
  final VoidCallback? onTap;

  const TodoRow({
    super.key,
    required this.todo,
    required this.done,
    required this.date,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final priorityColor = switch (todo.priority) {
      'high'   => Colors.redAccent,
      'medium' => Colors.orange,
      'low'    => Colors.lightBlueAccent,
      _        => Colors.transparent,
    };

    final content = Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            // 優先度ライン（左端）
            Container(
              width: 3, height: 32,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                color:        priorityColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // チェックボックス（onTap != null のときのみ表示）
            if (onTap != null) ...[
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  done ? Icons.check_box : Icons.check_box_outline_blank,
                  key:   ValueKey(done),
                  size:  18,
                  color: done ? AppTheme.primary : Colors.white38,
                ),
              ),
              const SizedBox(width: 10),
            ],
            // タスク名（打ち消し線アニメーション）
            Expanded(
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  color:           done ? Colors.white24 : Colors.white70,
                  fontSize:        13,
                  decoration:      done
                      ? TextDecoration.lineThrough
                      : TextDecoration.none,
                  decorationColor: Colors.white24,
                ),
                child: Text(todo.name,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
            ),
            const SizedBox(width: 8),
            // 期限日表示
            if (todo.dueDate != null)
              Text(
                '${todo.dueDate!.month}/${todo.dueDate!.day}',
                style: TextStyle(
                  color:    _dueDateColor(todo.dueDate!, date),
                  fontSize: 10,
                ),
              ),
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

class PriorityDot extends StatelessWidget {
  final String priority;
  const PriorityDot({super.key, required this.priority});

  @override
  Widget build(BuildContext context) {
    final color = switch (priority) {
      'high' => Colors.redAccent,
      'low'  => Colors.blueGrey,
      _      => Colors.orange,
    };
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
