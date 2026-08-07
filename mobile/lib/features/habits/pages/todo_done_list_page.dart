import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_loading_skeleton.dart';   // FEAT-230
import '../models/habit.dart';
import '../pages/edit_todo_page.dart' show EditTodoArgs; // FEAT-168
import '../providers/habits_provider.dart';

/// 完了済みToDoプロバイダー
final todoDoneProvider = FutureProvider.autoDispose<List<TodoDoneGroup>>((ref) {
  return ref.watch(habitsServiceProvider).fetchTodoDone();
});

class TodoDoneListPage extends ConsumerWidget {
  const TodoDoneListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final asyncData = ref.watch(todoDoneProvider);

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: Text(l10n.habitTodoDonePageTitle,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: asyncData.when(
        loading: () => SabiWaitingPanel(message: l10n.habitTodoDoneLoadingSabi_message),
        error: (e, _) => Center(
          // 【chore】CLAUDE.md 紳士的トーン準拠（旧「〜たよ + 命令形」をサビ口調に統一）
          child: Text(
            l10n.habitTodoDoneErrorSabi_message,
            style: const TextStyle(color: Colors.white54),
            textAlign: TextAlign.center,
          ),
        ),
        data: (groups) {
          if (groups.isEmpty) {
            return Center(
              child: Text(
                l10n.habitTodoDoneEmptySabi_message,
                style: const TextStyle(color: Colors.white54, fontSize: 14),
              ),
            );
          }
          return ListView.builder(
            // 【ユーザー要望 2026-06-22】最下部までスクロールできるよう、
            // safe area (iOS home indicator / Android navigation bar) +
            // 視覚的余裕 24px を bottom padding に追加。
            // CLAUDE.md「下部余白 (nav bar に隠れないよう)」標準パターン準拠。
            padding: EdgeInsets.fromLTRB(
              16, 16, 16,
              40 + MediaQuery.of(context).padding.bottom,
            ),
            itemCount: groups.length,
            itemBuilder: (context, i) {
              final group   = groups[i];
              final now     = DateTime.now();
              final todayStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
              final isToday = group.date == todayStr;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 16, bottom: 8),
                    child: Text(
                      isToday ? l10n.habitTodoDoneTodayLabel : group.date,
                      style: TextStyle(
                        color:         isToday ? Colors.white60 : Colors.white38,
                        fontSize:      12,
                        fontWeight:    FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  // FEAT-165: _DoneTodoItem（長押しで EditTodoPage へ遷移）
                  ...group.todos.map((todo) =>
                      _DoneTodoItem(key: ValueKey(todo.id), todo: todo)),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

// ── 完了済み ToDo アイテム（FEAT-165: 長押し詳細遷移） ─────────────────────────

class _DoneTodoItem extends ConsumerStatefulWidget {
  final Habit todo;
  const _DoneTodoItem({super.key, required this.todo});

  @override
  ConsumerState<_DoneTodoItem> createState() => _DoneTodoItemState();
}

class _DoneTodoItemState extends ConsumerState<_DoneTodoItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pressController;
  bool _pressed            = false;
  // 【2026-07-02 dead code cleanup】_longPressActivated は書き込みのみで参照ゼロ
  // (前回レビュー 6/29 継続指摘)。tap vs longpress の分岐は_onLongPress の
  // _openDetail() 呼び出しで完結しており、フラグ経由で状態を保持する必要はない。
  // 対応する _onTapDown / _onLongPress 内の書き込みも削除。

  // ヒントバッジ（初回〜3回）
  bool _showHint = false;
  static const _kDoneHintKey      = 'todo_done_hint_count';
  static const _kDoneHintMaxCount = 3;

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

  Future<void> _scheduleHint() async {
    final prefs = await SharedPreferences.getInstance();
    final count = prefs.getInt(_kDoneHintKey) ?? 0;
    if (count >= _kDoneHintMaxCount) return;
    await prefs.setInt(_kDoneHintKey, count + 1);
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    setState(() => _showHint = true);
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    setState(() => _showHint = false);
  }

  void _onTapDown(TapDownDetails _) {
    _pressController.forward(from: 0.0);
    setState(() => _pressed = true);
  }

  void _onTapUp(TapUpDetails _) => _resetPressState();

  void _onTapCancel() => _resetPressState();

  void _onLongPress() {
    HapticFeedback.mediumImpact();
    setState(() => _showHint = false);
    _openDetail();
    _resetPressState();
  }

  void _onLongPressCancel() => _resetPressState();

  void _resetPressState() {
    _pressController.reverse();
    if (mounted) setState(() => _pressed = false);
  }

  void _openDetail() {
    // FEAT-168: 読み取り専用モードで詳細表示
    context.push(
      AppRoutes.editTodo,
      extra: EditTodoArgs(todo: widget.todo, readOnly: true),
    ).then((_) {
      if (mounted) ref.invalidate(todoDoneProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final todo = widget.todo;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: _pressed
                      ? AppTheme.card.withValues(alpha: 0.9)
                      : AppTheme.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _pressed
                        ? AppTheme.primary.withValues(alpha: 0.2)
                        : Colors.white.withValues(alpha: 0.06),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle,
                        color: AppTheme.primary, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        todo.name,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 14,
                          decoration: TextDecoration.lineThrough,
                          decorationColor: Colors.white.withValues(alpha: 0.3),
                        ),
                      ),
                    ),
                    Text(
                      todo.category,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ),

              // ② 長押しプログレスボーダーオーバーレイ
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _pressController,
                  builder:   (_, __) => CustomPaint(
                    painter: _DoneTodoBorderProgressPainter(
                      progress:     _pressController.value,
                      borderRadius: 12,
                    ),
                  ),
                ),
              ),

              // ③ ヒントバッジ（初回〜3回）
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
                        AppLocalizations.of(context)!.habitTodoDoneLongPressHint,
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

// ── 完了済み ToDo 長押しプログレスボーダー ──────────────────────────────────────
class _DoneTodoBorderProgressPainter extends CustomPainter {
  const _DoneTodoBorderProgressPainter({
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
  bool shouldRepaint(_DoneTodoBorderProgressPainter old) =>
      old.progress != progress;
}
