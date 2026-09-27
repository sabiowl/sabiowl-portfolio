import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_error_chip.dart';
import '../models/habit.dart';
import '../pages/add_todo_page.dart' show showAddTodoModal;
import '../providers/habits_provider.dart';

/// ホーム画面の ToDo セクション。
/// 「習慣リスト」の直上に配置し、アクティブな ToDo を表示する。
///
/// 表示ルール:
///   - 未完了の Todo（habit_type='todo'）を全件表示
///   - ソート: 過去の due_date（持ち越し）が先頭、当日が次、未設定が最後
///   - 完了した ToDo はこのセクションから消える（TodoDoneListView で別途確認可能）
class TodoSection extends ConsumerWidget {
  const TodoSection({super.key});

  void _openQuickAdd(BuildContext context) {
    HapticFeedback.lightImpact();
    showAddTodoModal(context);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final habitsAsync = ref.watch(habitsNotifierProvider);
    final l10n = AppLocalizations.of(context)!;

    return habitsAsync.when(
      loading: () => const SizedBox.shrink(),
      // P0-2: エラー握りつぶし全廃 — 通信失敗を「データなし」と区別させる
      error: (_, __) => SabiErrorChip(
        message: l10n.habitTodoSectionLoadError,
      ),
      data: (habits) {
        // 全 Todo（完了・未完了の両方）
        final allTodos   = habits.where((h) => h.isTodo).toList();
        // 未完了と完了済みを分離
        final pending    = allTodos.where((h) => !h.isCompletedToday).toList();
        final done       = allTodos.where((h) =>  h.isCompletedToday).toList();
        // バッジ表示用
        final doneCount  = done.length;
        final totalCount = allTodos.length;

        final today = DateTime.now();
        final todayDate = DateTime(today.year, today.month, today.day);

        // ソート（未完了のみ）: 過去 due_date（持ち越し）→ 当日 → due_date なし
        pending.sort((a, b) {
          final aDate = a.dueDate != null
              ? DateTime(a.dueDate!.year, a.dueDate!.month, a.dueDate!.day)
              : null;
          final bDate = b.dueDate != null
              ? DateTime(b.dueDate!.year, b.dueDate!.month, b.dueDate!.day)
              : null;

          // 過去日付を先頭に
          if (aDate != null && aDate.isBefore(todayDate) &&
              (bDate == null || !bDate.isBefore(todayDate))) return -1;
          if (bDate != null && bDate.isBefore(todayDate) &&
              (aDate == null || !aDate.isBefore(todayDate))) return 1;
          // 日付あり > 日付なし
          if (aDate != null && bDate == null) return -1;
          if (bDate != null && aDate == null) return 1;
          // 両方日付あり: 古い順
          if (aDate != null && bDate != null) return aDate.compareTo(bDate);
          return a.id.compareTo(b.id);
        });

        // 完了済みを末尾に結合（バッジの done/total と画面上の件数を一致させる）
        final todos = [...pending, ...done];

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── セクションヘッダー ──────────────────────────────
              Row(
                children: [
                  Text(
                    l10n.habitTodoSectionHeader,
                    style: const TextStyle(
                      color:      Colors.white70,
                      fontSize:   13,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  if (allTodos.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    _TodoProgressBadge(
                      done:  doneCount,
                      total: totalCount,
                    ),
                  ],
                  const Spacer(),
                  // ＋ クイック追加ボタン
                  GestureDetector(
                    onTap: () => _openQuickAdd(context),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: AppTheme.primary.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.add, size: 13, color: AppTheme.primary),
                          const SizedBox(width: 3),
                          Text(
                            l10n.habitTodoAddButton,
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

              const SizedBox(height: 6),

              // ── ToDo リスト or 空のプロンプト ──────────────────
              if (allTodos.isEmpty)
                _TodoEmptyPrompt(onAdd: () => _openQuickAdd(context))
              else if (pending.isEmpty && done.isNotEmpty) ...[
                // 全件完了時: 達成メッセージ + 完了済み一覧
                const _TodoAllDonePrompt(),
                ...done.map((todo) => _TodoItem(todo: todo)),
              ] else
                ...todos.map((todo) => _TodoItem(todo: todo)),

              // ── 完了済みリンク ──────────────────────────────────
              const _TodoDoneLinkRow(),
            ],
          ),
        );
      },
    );
  }
}

// ── 空の状態プロンプト ─────────────────────────────────────────────────────────

class _TodoEmptyPrompt extends StatelessWidget {
  final VoidCallback onAdd;
  const _TodoEmptyPrompt({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onAdd,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.check_box_outline_blank,
              size: 18,
              color: Colors.white.withValues(alpha: 0.25),
            ),
            const SizedBox(width: 10),
            Text(
              AppLocalizations.of(context)!.habitTodoEmptyPrompt,
              style: TextStyle(
                color:    Colors.white.withValues(alpha: 0.3),
                fontSize: 13,
              ),
            ),
            const Spacer(),
            Icon(
              Icons.add,
              size: 16,
              color: Colors.white.withValues(alpha: 0.2),
            ),
          ],
        ),
      ),
    );
  }
}

// ── ToDo アイテム行 ────────────────────────────────────────────────────────────

class _TodoItem extends ConsumerStatefulWidget {
  final Habit todo;
  const _TodoItem({required this.todo});

  @override
  ConsumerState<_TodoItem> createState() => _TodoItemState();
}

class _TodoItemState extends ConsumerState<_TodoItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pressController;
  bool _pressed            = false;
  bool _longPressActivated = false;
  /// 【FEAT-533 §8-3 (2026-08-25)】送信中フラグ。`habit_card.dart` の
  /// `_actionInFlight` と同型で、守る対象も同じ `HabitsNotifier._inFlight[habitId]`。
  bool _sending            = false;

  // ヒントバッジ（初回〜3回）
  bool _showHint = false;
  static const _kHintKey      = 'todo_item_hint_count';
  static const _kHintMaxCount = 3;

  @override
  void initState() {
    super.initState();
    _pressController = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 500),
    );
    _scheduleHint();
  }

  @override
  void dispose() {
    _pressController.dispose();
    super.dispose();
  }

  // 初回〜3回目のみ「長押しで編集」ヒントを数秒表示する
  Future<void> _scheduleHint() async {
    final prefs = await SharedPreferences.getInstance();
    final count = prefs.getInt(_kHintKey) ?? 0;
    if (count >= _kHintMaxCount) return;
    await prefs.setInt(_kHintKey, count + 1);
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    setState(() => _showHint = true);
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    setState(() => _showHint = false);
  }

  // ── ジェスチャーハンドラー ─────────────────────────────────────────────

  void _onTapDown(TapDownDetails _) {
    _longPressActivated = false;
    _pressController.forward(from: 0.0);
    setState(() => _pressed = true);
  }

  void _onTapUp(TapUpDetails _) {
    if (!_longPressActivated) {
      _handleTap();
    }
    _resetPressState();
  }

  /// ToDo カードのタップ処理。
  ///
  /// 【FEAT-533 §8-3 (2026-08-25)】以前は `HapticFeedback.lightImpact()` を鳴らしてから
  /// `incrementCount` / `decrementCount` を **await せずに**投げていた。両者は
  /// `HabitsNotifier._inFlight[habitId]` guard で往復中の 2 回目以降を早期 return する
  /// (throw しない) ので、**振動は鳴るのに何も起きない**。FEAT-532 が
  /// `habit_card.dart` で直したのとまったく同じ嘘が、**同じホーム画面の隣のカード**で
  /// 鳴っていた。
  ///
  /// ⚠️ ToDo カードには spinner を出さない。押下スケール演出 (`_pressController`) が
  /// 既に「押した」を返しており、そこにスピナーを足すとカードの見た目が跳ねる。
  /// **ここで直すのは「鳴らさない」ことだけ**で、それが嘘をやめる最小の形である。
  ///
  /// ⚠️ 解放は必ず `finally`。`_inFlight` はこの解放漏れで BUG-71 になった。
  Future<void> _handleTap() async {
    if (_sending) return;
    setState(() => _sending = true);

    HapticFeedback.lightImpact();

    final notifier = ref.read(habitsNotifierProvider.notifier);
    // widget.todo.isCompletedToday を直接参照（build()の isDone は final のため）
    final undo = widget.todo.isCompletedToday;
    final l10n = AppLocalizations.of(context);

    try {
      if (undo) {
        // 完了済み → タップで取り消し（minus）
        await notifier.decrementCount(widget.todo.id);
      } else {
        // 未完了 → タップで完了（plus）
        await notifier.incrementCount(widget.todo.id, l10n: l10n);
      }
    } catch (_) {
      // 【FEAT-533 追補 §9-5 (2026-08-26)】通信失敗をユーザーに伝える。
      //
      // 🔴 ここには「エラー通知は notifier 側が行う」と書いてあったが**事実ではない**。
      // `HabitsNotifier.incrementCount` の catch は rollback +
      // `pendingPlayerReward = null` + `playerNotifier.refresh()` + `rethrow` の 4 行で、
      // **ユーザーに向けたメッセージは 1 つも出していない**。結果、同じホーム画面で
      // 習慣カードは「通信が滞ってしまったようです 🪶」を出すのに、
      // **ToDo カードだけが無言で元に戻る**という差が生まれていた。
      //
      // 🔵 これは FEAT-533 の退行ではない。変更前は `await` していなかったので例外は
      // 未処理の非同期エラーになり、やはり何も出ていなかった。FEAT-533 は
      // **元からあった沈黙を可視化しただけ**である。
      //
      // 文言は `habit_card` と同じ既存キーを再利用する (新規 ARB 不要)。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.habitCardNetworkErrorSabi_message,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            backgroundColor: const Color(0xFF2A2A3E),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _onTapCancel() => _resetPressState();

  void _onLongPress() {
    _longPressActivated = true;
    HapticFeedback.mediumImpact();
    setState(() => _showHint = false);
    _openEdit();
    _resetPressState();
  }

  void _onLongPressCancel() => _resetPressState();

  void _resetPressState() {
    _pressController.reverse();
    if (mounted) setState(() => _pressed = false);
  }

  void _openEdit() {
    context.push(AppRoutes.editTodo, extra: widget.todo);
  }

  @override
  Widget build(BuildContext context) {
    final l10n      = AppLocalizations.of(context)!;
    final todo      = widget.todo;
    final isDone    = todo.isCompletedToday;
    final today     = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final isOverdue = todo.dueDate != null &&
        DateTime(todo.dueDate!.year, todo.dueDate!.month, todo.dueDate!.day)
            .isBefore(todayDate);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        // 完了済みでもタップ（取り消し）・長押し編集を有効にする
        onTapDown:         _onTapDown,
        onTapUp:           _onTapUp,
        onTapCancel:       _onTapCancel,
        onLongPress:       _onLongPress,
        onLongPressCancel: _onLongPressCancel,
        child: AnimatedScale(
          scale:    _pressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 100),
          curve:    Curves.easeOut,
          child: Stack(
            children: [
              // ① カード本体
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isDone
                      ? Colors.white.withValues(alpha: 0.04)
                      : AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDone
                        ? Colors.white.withValues(alpha: 0.06)
                        : isOverdue
                            ? Colors.orange.withValues(alpha: 0.4)
                            : Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: Row(
                  children: [
                    // ① タイトル（FEAT-176: 先頭に移動）
                    Expanded(
                      child: Text(
                        todo.name,
                        style: TextStyle(
                          color:      isDone
                              ? Colors.white.withValues(alpha: 0.35)
                              : Colors.white,
                          fontSize:   14,
                          decoration: isDone
                              ? TextDecoration.lineThrough
                              : TextDecoration.none,
                          decorationColor: Colors.white38,
                        ),
                      ),
                    ),

                    // ② 持ち越しバッジ（変更なし）
                    if (isOverdue && !isDone) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          l10n.habitTodoOverdueBadge,
                          style: const TextStyle(
                            color:    Colors.orange,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],

                    // ③ 優先度バッジ（高・低のみ、中は非表示、変更なし）
                    if (!isDone && todo.priority != 'medium') ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: _priorityColor(todo.priority).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          _priorityLabel(l10n, todo.priority),
                          style: TextStyle(
                            color:    _priorityColor(todo.priority),
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],

                    // ④ EXP バッジ（未完了時のみ、変更なし）
                    if (!isDone) ...[
                      const SizedBox(width: 6),
                      Text(
                        '+${_expForDifficulty(todo.difficulty)} EXP',
                        style: TextStyle(
                          color:    AppTheme.expColor.withValues(alpha: 0.6),
                          fontSize: 10,
                        ),
                      ),
                    ],

                    // ⑤ 完了アイコン（FEAT-176: 右端に移動 / FEAT-173: タイムライン形式）
                    const SizedBox(width: 8),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, animation) =>
                          ScaleTransition(scale: animation, child: child),
                      child: isDone
                          ? Icon(
                              Icons.check_circle,
                              key:   const ValueKey(true),
                              size:  18,
                              color: AppTheme.primary.withValues(alpha: 0.85),
                            )
                          : Icon(
                              Icons.radio_button_unchecked,
                              key:   const ValueKey(false),
                              size:  18,
                              color: Colors.white.withValues(alpha: 0.35),
                            ),
                    ),
                  ],
                ),
              ),

              // ② 長押しプログレスボーダーオーバーレイ
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _pressController,
                  builder:   (_, __) => CustomPaint(
                    painter: _TodoBorderProgressPainter(
                      progress:     _pressController.value,
                      borderRadius: 12,
                    ),
                  ),
                ),
              ),

              // ③ ヒントバッジ（初回〜3回: 「長押しで編集」を一時表示）
              if (_showHint)
                Positioned(
                  right:  8,
                  top:    0,
                  bottom: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color:        AppTheme.primary.withValues(alpha: 0.90),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        l10n.habitTodoLongPressHint,
                        style: const TextStyle(
                          color:      Colors.white,
                          fontSize:   10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── ヘルパー関数 ─────────────────────────────────────────────────────────────

String _priorityLabel(AppLocalizations l10n, String priority) => switch (priority) {
  'high' => l10n.habitTodoPriorityHigh,
  'low'  => l10n.habitTodoPriorityLow,
  _      => l10n.habitTodoPriorityMid,
};

Color _priorityColor(String priority) => switch (priority) {
  'high' => Colors.redAccent,
  'low'  => Colors.blueGrey,
  _      => Colors.amber,
};

int _expForDifficulty(String difficulty) => switch (difficulty) {
  'easy'      => 20,
  'normal'    => 30,
  'hard'      => 40,
  'legendary' => 60,
  _           => 30,
};

// ── 進捗バッジ ────────────────────────────────────────────────────────────────

/// 今日だけの約束セクションの進捗バッジ（完了数/総数）
class _TodoProgressBadge extends StatelessWidget {
  final int done;
  final int total;
  const _TodoProgressBadge({required this.done, required this.total});

  @override
  Widget build(BuildContext context) {
    final isAllDone = done >= total;
    final isAnyDone = done > 0;

    final badgeColor = isAllDone
        ? AppTheme.gold       // 全完了 → ゴールド
        : isAnyDone
            ? Colors.amber    // 一部完了 → アンバー
            : AppTheme.primary; // 未着手 → プライマリ紫

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: badgeColor.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isAllDone)
            Padding(
              padding: const EdgeInsets.only(right: 3),
              child: Icon(
                Icons.star_rounded,
                size:  10,
                color: badgeColor,
              ),
            ),
          Text(
            '$done/$total',
            style: TextStyle(
              color:      badgeColor,
              fontSize:   11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

// ── 長押しプログレスボーダー ─────────────────────────────────────────────────────

/// ToDo カードの長押しプログレスボーダー。
/// timeline_event_card.dart の _EventBorderProgressPainter と同一ロジック。
/// カテゴリカラーの代わりに AppTheme.primary（紫）+ MaskFilter.blur でグロー描画。
class _TodoBorderProgressPainter extends CustomPainter {
  const _TodoBorderProgressPainter({
    required this.progress,
    required this.borderRadius,
  });

  final double progress;
  final double borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final paint = Paint()
      ..color       = AppTheme.primary.withValues(alpha: 0.85)
      ..strokeWidth = 2.5
      ..style       = PaintingStyle.stroke
      ..strokeCap   = StrokeCap.round
      ..maskFilter  = const MaskFilter.blur(BlurStyle.normal, 3);

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(borderRadius),
    );
    final path = Path()..addRRect(rect);
    for (final metric in path.computeMetrics()) {
      canvas.drawPath(metric.extractPath(0, metric.length * progress), paint);
    }
  }

  @override
  bool shouldRepaint(_TodoBorderProgressPainter old) =>
      old.progress != progress;
}

// ── 全完了メッセージ ─────────────────────────────────────────────────────────

/// 全てのToDoが完了したときに表示する達成メッセージバー
class _TodoAllDonePrompt extends StatelessWidget {
  const _TodoAllDonePrompt();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: AppTheme.gold.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.gold.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.star_rounded,
            size:  16,
            color: AppTheme.gold.withValues(alpha: 0.8),
          ),
          const SizedBox(width: 8),
          Text(
            AppLocalizations.of(context)!.habitTodoAllDoneSabi_message,
            style: TextStyle(
              color:      AppTheme.gold.withValues(alpha: 0.8),
              fontSize:   13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ── 完了済み ToDo リンク ──────────────────────────────────────────────────────

class _TodoDoneLinkRow extends ConsumerWidget {
  const _TodoDoneLinkRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 【FEAT-277】タップしやすさ向上のためフォント/アイコン/padding を拡大。
    // 旧: fontSize 11 / iconSize 14 / padding (4,2) → タップ範囲が狭い
    // 新: fontSize 13 / iconSize 16 / padding (8,6) → 自然なタップ範囲、
    //     ホーム画面の「+追加」ボタン (fontSize 12) と同等の存在感に。
    //     色は white24 を維持し、目立ち過ぎず控えめなアフォーダンスを保つ。
    return TextButton.icon(
      onPressed: () => context.push(AppRoutes.todoDone),
      icon: const Icon(Icons.check_circle_outline,
          color: Colors.white24, size: 16),
      label: Text(
        AppLocalizations.of(context)!.habitTodoDoneLink,
        style: const TextStyle(color: Colors.white24, fontSize: 13),
      ),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
