import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/category_request_dialog.dart';
import '../../../shared/widgets/sabi_category_chips.dart';
import '../../../l10n/app_localizations.dart';
import '../models/habit.dart';
import '../providers/habits_provider.dart';

/// GoRouter extra に渡すラッパークラス（FEAT-168）。
/// readOnly: true のとき完了済み ToDo の詳細表示モードになる。
class EditTodoArgs {
  final Habit todo;
  final bool  readOnly;
  const EditTodoArgs({required this.todo, this.readOnly = false});
}

/// ToDo 編集全画面ページ（FEAT-161）。
/// EditHabitPage と同じ GoRouter push 遷移で表示される。
/// todo_section で ToDo を長押しすると遷移する。
/// FEAT-168: readOnly=true のとき詳細表示モード（編集・削除不可）。
class EditTodoPage extends ConsumerStatefulWidget {
  final Habit todo;
  final bool  readOnly; // FEAT-168

  const EditTodoPage({super.key, required this.todo, this.readOnly = false});

  @override
  ConsumerState<EditTodoPage> createState() => _EditTodoPageState();
}

class _EditTodoPageState extends ConsumerState<EditTodoPage> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _memoCtrl;

  late String _priority;
  late String _difficulty;
  late String _category;

  bool _saving   = false;
  bool _deleting = false;

  // 【FEAT-210】カテゴリ定数は `kSabiHabitCategories` に統一（旧 `_categories` 削除）。

  @override
  void initState() {
    super.initState();
    _titleCtrl  = TextEditingController(text: widget.todo.name);
    _memoCtrl   = TextEditingController(text: widget.todo.memo);
    _priority   = widget.todo.priority;
    _difficulty = widget.todo.difficulty;
    _category   = widget.todo.category;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _memoCtrl.dispose();
    super.dispose();
  }

  // FEAT-170: タイトルをクリップボードにコピー
  void _copyTitle() {
    final text = _titleCtrl.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:  Text(AppLocalizations.of(context)!.habitEditTodoCopyTitleSabi_message),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // FEAT-164: メモをクリップボードにコピー
  void _copyMemo() {
    final text = _memoCtrl.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:  Text(AppLocalizations.of(context)!.habitAddTodoCopiedSabi_message),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── 保存 ──────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    final trimmed = _titleCtrl.text.trim();
    if (trimmed.isEmpty) return;
    HapticFeedback.mediumImpact();
    setState(() => _saving = true);

    final messenger = ScaffoldMessenger.of(context);

    try {
      await ref.read(habitsNotifierProvider.notifier).updateHabit(
        widget.todo.id,
        {
          'name':       trimmed,
          'priority':   _priority,
          'difficulty': _difficulty,
          'habit_type': 'todo',
          'category':   _category,
          'memo':       _memoCtrl.text.trim(), // FEAT-161: メモを追加
          'frequency':  widget.todo.frequency,
          'reset_cycle': widget.todo.resetCycle,
        },
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content:  Text(AppLocalizations.of(context)!.habitEditTodoSavedSabi_message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content:  Text(AppLocalizations.of(context)!.habitEditTodoSaveErrorSabi_message),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── 削除 ──────────────────────────────────────────────────────────────────

  Future<void> _confirmDelete() async {
    HapticFeedback.lightImpact();
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          l10n.habitEditTodoDeleteTitle,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          l10n.habitEditTodoDeleteContent(widget.todo.name),
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.habitCardDialogCancelButton,
                style: const TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () {
              HapticFeedback.mediumImpact();
              Navigator.pop(ctx, true);
            },
            child: Text(
              l10n.habitEditTodoDeleteButton,
              style: const TextStyle(
                color:      Colors.redAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    final messenger = ScaffoldMessenger.of(context);

    try {
      await ref.read(habitsNotifierProvider.notifier).deleteHabit(widget.todo.id);
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content:  Text(AppLocalizations.of(context)!.habitEditTodoDeletedSabi_message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content:  Text(AppLocalizations.of(context)!.habitEditTodoDeleteErrorSabi_message),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final busy = _saving || _deleting;

    return Scaffold(
      appBar: AppBar(
        // FEAT-168: 読み取り専用モードはタイトルを変える
        title: Text(widget.readOnly ? l10n.habitEditTodoDetailTitle : l10n.habitEditTodoEditTitle),
        actions: [
          // FEAT-170: 通常モード・読み取り専用モード共に削除ボタンを表示
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: l10n.habitEditTodoDeleteTooltip,
            onPressed: busy ? null : _confirmDelete,
            color: busy ? Colors.white24 : Colors.white54,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16, 16, 16,
          16 + MediaQuery.of(context).padding.bottom,
        ),
        children: [

          // ── タイトル（FEAT-170: readOnly のとき読み取り専用 ＋ コピーアイコン）──
          Stack(
            alignment: Alignment.topRight,
            children: [
              TextField(
                controller:      _titleCtrl,
                autofocus:       false,
                readOnly:        widget.readOnly, // FEAT-170: 詳細モードでは編集不可
                style: const TextStyle(color: Colors.white, fontSize: 15),
                textInputAction: widget.readOnly
                    ? TextInputAction.none
                    : TextInputAction.done,
                onSubmitted: widget.readOnly ? null : (_) => _save(),
                decoration: InputDecoration(
                  hintText:  l10n.habitEditTodoInputHint,
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled:    true,
                  fillColor: Colors.white.withValues(alpha: 0.06),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:   BorderSide.none,
                  ),
                  // FEAT-170: readOnly のときコピーアイコン分の右余白を確保
                  contentPadding: widget.readOnly
                      ? const EdgeInsets.fromLTRB(14, 12, 42, 12)
                      : const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
              // FEAT-170: 詳細モードのみコピーアイコンを表示
              if (widget.readOnly)
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _titleCtrl,
                  builder: (_, value, __) {
                    return GestureDetector(
                      onTap: value.text.isEmpty ? null : _copyTitle,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 200),
                          opacity:  value.text.isEmpty ? 0.15 : 0.7,
                          child: const Icon(
                            Icons.copy_outlined,
                            size:  17,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),

          const SizedBox(height: 20),

          // ── 優先度 ───────────────────────────────────────────────
          _SectionLabel(l10n.habitQuickAddPriorityLabel),
          const SizedBox(height: 8),
          // FEAT-168: 読み取り専用モードでは薄くして操作不可
          Opacity(
            opacity: widget.readOnly ? 0.6 : 1.0,
            child: Row(
              children: [
                _PriorityPill(
                  label:    l10n.habitTodoPriorityHigh,
                  selected: _priority == 'high',
                  color:    Colors.redAccent,
                  onTap:    widget.readOnly ? null : () => setState(() => _priority = 'high'),
                ),
                const SizedBox(width: 8),
                _PriorityPill(
                  label:    l10n.habitTodoPriorityMid,
                  selected: _priority == 'medium',
                  color:    Colors.amber,
                  onTap:    widget.readOnly ? null : () => setState(() => _priority = 'medium'),
                ),
                const SizedBox(width: 8),
                _PriorityPill(
                  label:    l10n.habitTodoPriorityLow,
                  selected: _priority == 'low',
                  color:    Colors.blueGrey,
                  onTap:    widget.readOnly ? null : () => setState(() => _priority = 'low'),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ── 難易度 ───────────────────────────────────────────────
          _SectionLabel(l10n.habitQuickAddDifficultyLabel),
          const SizedBox(height: 8),
          // FEAT-168: 読み取り専用モードでは薄くして操作不可
          Opacity(
            opacity: widget.readOnly ? 0.6 : 1.0,
            child: Row(
              children: [
                _DifficultyPill(
                  label:    'Easy',
                  exp:      20,
                  selected: _difficulty == 'easy',
                  onTap:    widget.readOnly ? null : () => setState(() => _difficulty = 'easy'),
                ),
                const SizedBox(width: 8),
                _DifficultyPill(
                  label:    'Normal',
                  exp:      30,
                  selected: _difficulty == 'normal',
                  onTap:    widget.readOnly ? null : () => setState(() => _difficulty = 'normal'),
                ),
                const SizedBox(width: 8),
                _DifficultyPill(
                  label:    'Hard',
                  exp:      40,
                  selected: _difficulty == 'hard',
                  onTap:    widget.readOnly ? null : () => setState(() => _difficulty = 'hard'),
                ),
                const SizedBox(width: 8),
                _DifficultyPill(
                  label:    'Legend',
                  exp:      60,
                  selected: _difficulty == 'legendary',
                  onTap:    widget.readOnly ? null : () => setState(() => _difficulty = 'legendary'),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ── カテゴリ ─────────────────────────────────────────────
          _SectionLabel(l10n.habitQuickAddCategoryLabel),
          const SizedBox(height: 8),
          // 【FEAT-168】読み取り専用モードは選択中のチップを静的表示。
          // 【FEAT-210】カテゴリ表示は共通コンポーネントに統一。読み取り専用時のみ
          //   静的に 1 チップだけ表示する分岐は残す（編集不可の視覚表現として有効）。
          if (widget.readOnly) ...[
            Builder(builder: (context) {
              final cat = kSabiHabitCategories.firstWhere(
                (c) => c.$1 == _category,
                orElse: () => kSabiHabitCategories.last,
              );
              // 静的表示は SabiCategoryChips のスタイル（選択時）と揃える:
              //   padding h14/v8, border alpha 0.7 width 1.5, text color white
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color:        cat.$2.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: cat.$2.withValues(alpha: 0.7),
                    width: 1.5,
                  ),
                ),
                child: Text(
                  cat.$1,
                  style: const TextStyle(
                    color:      Colors.white,
                    fontSize:   13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );
            }),
          ] else ...[
            // 【FEAT-210】カテゴリチップ共通コンポーネント化
            SabiCategoryChips(
              categories:       kSabiHabitCategories,
              selectedCategory: _category,
              onChanged:        (cat) => setState(() => _category = cat),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  CategoryRequestDialog.show(context);
                },
                child: Text(
                  l10n.habitQuickAddCategoryRequestLink,
                  style: TextStyle(
                    color:           AppTheme.primary.withValues(alpha: 0.65),
                    fontSize:        12,
                    decoration:      TextDecoration.underline,
                    decorationColor: AppTheme.primary.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ),
          ],

          const SizedBox(height: 20),

          // ── メモ欄（FEAT-161: 新規追加 / FEAT-164: コピーアイコン追加）──
          _SectionLabel(l10n.habitAddTodoMemoHint),
          const SizedBox(height: 8),
          Stack(
            alignment: Alignment.topRight,
            children: [
              TextField(
                controller: _memoCtrl,
                maxLines:   4,
                minLines:   2,
                // FEAT-168: 読み取り専用モードでは編集不可
                readOnly:   widget.readOnly,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText:  l10n.habitEditTodoMemoHint,
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled:    true,
                  fillColor: Colors.white.withValues(alpha: 0.06),
                  prefixIcon: const Icon(
                      Icons.notes_outlined, size: 18, color: Colors.white38),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:   BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.fromLTRB(14, 12, 42, 12),
                ),
              ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _memoCtrl,
                builder: (_, value, __) {
                  return GestureDetector(
                    onTap: value.text.isEmpty ? null : _copyMemo,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 200),
                        opacity:  value.text.isEmpty ? 0.15 : 0.7,
                        child: const Icon(
                          Icons.copy_outlined,
                          size:  17,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),

          const SizedBox(height: 28),

          // ── 保存ボタン（FEAT-168: 読み取り専用モードでは非表示）──
          if (!widget.readOnly)
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _titleCtrl,
              builder: (_, value, __) {
                final canSave = value.text.trim().isNotEmpty && !busy;
                return SizedBox(
                  width: double.infinity,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity:  canSave ? 1.0 : 0.35,
                    child: ElevatedButton(
                      onPressed: canSave ? _save : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: _saving
                          ? const SizedBox(
                              height: 18, width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white,
                              ),
                            )
                          : Text(
                              l10n.habitEditTodoSaveButton,
                              style: const TextStyle(
                                fontSize:   15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                );
              },
            ),

        ],
      ),
    );
  }
}

// ── セクションラベル ──────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color:         Colors.white.withValues(alpha: 0.4),
        fontSize:      11,
        fontWeight:    FontWeight.bold,
        letterSpacing: 0.5,
      ),
    );
  }
}

// ── 優先度ピル ────────────────────────────────────────────────────────────────

class _PriorityPill extends StatelessWidget {
  final String        label;
  final bool          selected;
  final Color         color;
  final VoidCallback? onTap; // FEAT-168: nullable（読み取り専用モードで null を渡す）

  const _PriorityPill({
    required this.label,
    required this.selected,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap == null ? null : () {
        HapticFeedback.selectionClick();
        onTap!();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? color.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? color.withValues(alpha: 0.7)
                : Colors.white.withValues(alpha: 0.1),
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color:      selected ? color : Colors.white54,
            fontSize:   13,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

// ── 難易度ピル ────────────────────────────────────────────────────────────────

class _DifficultyPill extends StatelessWidget {
  final String        label;
  final int           exp;
  final bool          selected;
  final VoidCallback? onTap; // FEAT-168: nullable（読み取り専用モードで null を渡す）

  const _DifficultyPill({
    required this.label,
    required this.exp,
    required this.selected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap == null ? null : () {
          HapticFeedback.selectionClick();
          onTap!();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.primary.withValues(alpha: 0.18)
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? AppTheme.primary.withValues(alpha: 0.7)
                  : Colors.white.withValues(alpha: 0.1),
              width: selected ? 1.5 : 1.0,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color:      selected ? AppTheme.primary : Colors.white54,
                  fontSize:   12,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              Text(
                '+$exp',
                style: TextStyle(
                  color:    selected
                      ? AppTheme.primary.withValues(alpha: 0.7)
                      : Colors.white24,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
