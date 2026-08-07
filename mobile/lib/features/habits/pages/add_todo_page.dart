import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/category_request_dialog.dart';
import '../../../shared/widgets/sabi_category_chips.dart';
import '../../task_suggestion/models/task_suggestion.dart';  // 【2026-07-07】upsert 用
import '../../task_suggestion/providers/task_suggestion_provider.dart';  // 【2026-07-07】master 判定
import '../../task_suggestion/services/custom_suggestion_store.dart';  // 【2026-07-07】upsert
import '../../task_suggestion/widgets/task_title_search_sheet.dart'; // 【FEAT-467】
import '../providers/habits_provider.dart';
import '../../../shared/widgets/add_task_modal.dart';
import '../../../l10n/app_localizations.dart';

void showAddTodoModal(BuildContext context) =>
    showAddTaskModal(context, title: AppLocalizations.of(context)!.habitAddTodoTitle, child: const AddTodoPage(useScaffold: false));

/// ToDo 全画面追加ページ（FEAT-152）。
/// 習慣追加（AddHabitPage）と同じ GoRouter push 遷移で表示される。
///
/// 【2026-06-29】AddHabitPage / AddEventPage と同じ `useScaffold: bool` パラメータを
/// 導入し、`calendar_add_page.dart` の ToDo タブ内に直接埋め込めるようにした。旧実装は
/// calendar_add_page.dart 側で ToDo form を独立実装として複製 (~300 LOC) しており、
/// UI 修正の二度手間が発生していた。本統合で ToDo form の実装は本ファイル 1 箇所に集約。
class AddTodoPage extends ConsumerStatefulWidget {
  /// 【2026-06-29】Scaffold + AppBar の有無を切替えるフラグ (AddHabitPage 準拠)。
  /// - `true` (default): 単独画面として AppBar 付き Scaffold で表示 (既存挙動、router 経路)。
  /// - `false`: ListView 部分のみを返す (calendar_add_page の TabBarView 内に埋め込む用途)。
  ///   呼び出し側 widget の TabBar / AppBar と二重表示しないよう構造選択を可能にする。
  final bool useScaffold;
  // 【FEAT-493】フリーメモ変換経路からの pre-fill タイトル (省略可)
  final String? initialTitle;

  const AddTodoPage({super.key, this.useScaffold = true, this.initialTitle});

  @override
  ConsumerState<AddTodoPage> createState() => _AddTodoPageState();
}

class _AddTodoPageState extends ConsumerState<AddTodoPage> {
  final _titleCtrl  = TextEditingController();
  // 【FEAT-198】ToDo 追加画面にメモ入力欄を追加（add_event_page.dart 同パターン）
  final _memoCtrl   = TextEditingController();
  bool   _saving    = false;
  String _priority  = 'medium';
  String _difficulty = 'normal';
  // 【20260729 user feedback 対応】default '学習' → 'その他' に変更。
  // 旧【FEAT-201】「その他」廃止 (4 値時代) の名残を、11 値時代の設計思想
  // (FEAT-213) に整合させて撤回。「その他」は CATEGORY_STAT_MAP で 6 stat
  // 均等分配、選択負担を減らしつつ Sabi 哲学「押し付けない」に整合。
  String _category  = 'その他';

  @override
  void initState() {
    super.initState();
    if (widget.initialTitle != null) {
      _titleCtrl.text = widget.initialTitle!;
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _memoCtrl.dispose();
    super.dispose();
  }

  /// 【FEAT-198】メモをクリップボードへコピー（add_event_page.dart 同パターン）。
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

  Future<void> _save(String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    setState(() => _saving = true);
    HapticFeedback.mediumImpact();

    // ScaffoldMessenger を pop 前に取得（pop 後に親 Scaffold の Messenger を参照）
    final messenger = ScaffoldMessenger.of(context);

    try {
      await ref.read(habitsNotifierProvider.notifier).createTodo(
            trimmed,
            priority:   _priority,
            difficulty: _difficulty,
            category:   _category,
            // 【FEAT-198】メモも保存する。空文字でも問題なし（既存挙動と整合）。
            memo:       _memoCtrl.text.trim(),
          );

      // 【2026-07-07】新規追加した title を端末ローカルカスタム候補として upsert。
      // master data に無い title のみ、full form state (priority / difficulty /
      // category / memo) 付きで保存 → 次回同 title 選択時に form 自動入力。
      await _maybePersistCustomSuggestion(trimmed);

      if (!mounted) return;
      Navigator.of(context).pop(true);
      messenger.showSnackBar(
        SnackBar(
          content:  Text(AppLocalizations.of(context)!.habitAddTodoSavedSabi_message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e, st) {
      debugPrint('[AddTodo] createTodo failed: $e\n$st');
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content:  Text(AppLocalizations.of(context)!.habitAddTodoErrorSabi_message),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 【2026-07-07】新規追加した title を端末ローカルカスタム候補として upsert。
  ///
  /// 条件:
  /// - title が非空
  /// - Backend master data に無い title (case-insensitive) のみ
  ///
  /// 保存内容: form 現在の state 全体 (priority / difficulty / category / memo)。
  /// best-effort: 失敗しても save flow は継続。
  Future<void> _maybePersistCustomSuggestion(String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    try {
      final master = await ref.read(taskSuggestionsProvider('todo').future);
      final inMaster = master
          .any((s) => s.title.toLowerCase() == trimmed.toLowerCase());
      if (inMaster) return;
      final memo = _memoCtrl.text.trim();
      await CustomSuggestionStore.upsert(
        TaskSuggestion(
          id:         -1,
          type:       'todo',
          title:      trimmed,
          category:   _category,
          emoji:      '',
          hint:       '',
          order:      0,
          priority:   _priority,
          difficulty: _difficulty,
          memo:       memo.isEmpty ? null : memo,
        ),
      );
    } catch (_) {
      // best-effort
    }
  }

  // 【FEAT-210】カテゴリチップ共通コンポーネント化（add_template_page.dart 真実値）。
  Widget _buildCategoryChips() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SabiCategoryChips(
          categories:       kSabiHabitCategories,
          selectedCategory: _category,
          onChanged:        (cat) => setState(() => _category = cat),
        ),
        // 【20260729 user feedback 対応 (案 C)】「その他」選択時のみ 6 stat 均等
        // 分配の hint を薄く表示 (add_habit_page と同型)。
        if (_category == 'その他')
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              AppLocalizations.of(context)!.habitAddTodoCategoryHint,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.38),
                fontSize: 11,
              ),
            ),
          ),
        // FEAT-148: カテゴリ追加リクエストリンク
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              CategoryRequestDialog.show(context);
            },
            child: Text(
              AppLocalizations.of(context)!.habitQuickAddCategoryRequestLink,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 【2026-06-29】useScaffold=false (calendar_add_page の TabBarView 内)
    // では ListView のみ返す。AppBar 二重表示 / Scaffold 二重を回避 (AddHabitPage と同 pattern)。
    final list = ListView(
      padding: EdgeInsets.fromLTRB(
        16, 16, 16,
        16 + MediaQuery.of(context).padding.bottom,
      ),
      children: [

          // ── タイトル入力 ──────────────────────────────────────────
          // 【2026-06-29】add_habit_page.dart の見出しスタイル (fontSize: 13 /
          // FontWeight.bold / Colors.white70) と統一して「ToDo名」ラベルを表示。
          // 何の入力フォームか一目で分かるようにする UX 改善。
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              l10n.habitAddTodoNameLabel,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.white70,
              ),
            ),
          ),
          // 【FEAT-467 (2026-07-02)】readOnly + onTap で検索 popup を開く。
          TextField(
            controller: _titleCtrl,
            readOnly:   true,
            style: const TextStyle(color: Colors.white, fontSize: 15),
            decoration: InputDecoration(
              hintText:  l10n.habitAddTodoTitleHint,
              hintStyle: const TextStyle(color: Colors.white38),
              filled:    true,
              fillColor: Colors.white.withValues(alpha: 0.06),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:   BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
            ),
            onTap: () async {
              HapticFeedback.selectionClick();
              final suggestion = await TaskTitleSearchSheet.show(
                context,
                type: 'todo',
                initialText: _titleCtrl.text,
              );
              if (suggestion == null || !mounted) return;
              setState(() {
                _titleCtrl.text = suggestion.title;
                if (suggestion.category.isNotEmpty) {
                  _category = suggestion.category;
                }
                // 【2026-07-07】カスタム候補の nullable field を復元 (Backend
                // master には無いので通常 null、ローカル custom のみ発火)。
                if (suggestion.priority != null) {
                  _priority = suggestion.priority!;
                }
                if (suggestion.difficulty != null) {
                  _difficulty = suggestion.difficulty!;
                }
                if (suggestion.memo != null && suggestion.memo!.isNotEmpty) {
                  _memoCtrl.text = suggestion.memo!;
                }
              });
            },
          ),

          const SizedBox(height: 20),

          // ── 優先度 ────────────────────────────────────────────────
          Text(
            l10n.habitQuickAddPriorityLabel,
            style: TextStyle(
              color:         Colors.white.withValues(alpha: 0.4),
              fontSize:      11,
              fontWeight:    FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _PriorityPill(
                label: l10n.habitTodoPriorityHigh, value: 'high',
                selected: _priority == 'high',
                color: Colors.redAccent,
                onTap: () => setState(() => _priority = 'high'),
              ),
              const SizedBox(width: 8),
              _PriorityPill(
                label: l10n.habitTodoPriorityMid, value: 'medium',
                selected: _priority == 'medium',
                color: Colors.amber,
                onTap: () => setState(() => _priority = 'medium'),
              ),
              const SizedBox(width: 8),
              _PriorityPill(
                label: l10n.habitTodoPriorityLow, value: 'low',
                selected: _priority == 'low',
                color: Colors.blueGrey,
                onTap: () => setState(() => _priority = 'low'),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // ── 難易度 ────────────────────────────────────────────────
          Text(
            l10n.habitQuickAddDifficultyLabel,
            style: TextStyle(
              color:         Colors.white.withValues(alpha: 0.4),
              fontSize:      11,
              fontWeight:    FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _DifficultyPill(
                label: 'Easy', value: 'easy', exp: 20,
                selected: _difficulty == 'easy',
                onTap: () => setState(() => _difficulty = 'easy'),
              ),
              const SizedBox(width: 8),
              _DifficultyPill(
                label: 'Normal', value: 'normal', exp: 30,
                selected: _difficulty == 'normal',
                onTap: () => setState(() => _difficulty = 'normal'),
              ),
              const SizedBox(width: 8),
              _DifficultyPill(
                label: 'Hard', value: 'hard', exp: 40,
                selected: _difficulty == 'hard',
                onTap: () => setState(() => _difficulty = 'hard'),
              ),
              // 【BUG-80 (2026-06-10)】Legend chip 削除。Backend habits.py:269-272 は
              // habit_type='todo' のとき difficulty を 'normal' に強制 degrade するため、
              // UI 上で legendary を選択可能にすると「設定したのに保存後 Normal に
              // なっている」誤解を生む (add_habit_page.dart からの copy-paste で
              // ToDo 用の制限ガード未実装が真因)。ToDo は Easy/Normal/Hard の
              // 3 種のみ選択可、Backend 仕様と完全一致させる。
            ],
          ),

          const SizedBox(height: 14),

          // ── カテゴリ ──────────────────────────────────────────────
          Text(
            l10n.habitQuickAddCategoryLabel,
            style: TextStyle(
              color:         Colors.white.withValues(alpha: 0.4),
              fontSize:      11,
              fontWeight:    FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          _buildCategoryChips(),

          const SizedBox(height: 18),

          // ── 【FEAT-198】メモ欄 + コピーアイコン（add_event_page.dart 同パターン） ──
          Text(
            l10n.habitAddTodoMemoLabel,
            style: TextStyle(
              color:         Colors.white.withValues(alpha: 0.4),
              fontSize:      11,
              fontWeight:    FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Stack(
            alignment: Alignment.topRight,
            children: [
              TextField(
                controller: _memoCtrl,
                maxLines:   4,
                minLines:   2,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText:  l10n.habitAddTodoMemoHint,
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled:    true,
                  fillColor: Colors.white.withValues(alpha: 0.06),
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

          const SizedBox(height: 20),

          // ── 追加ボタン ────────────────────────────────────────────
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _titleCtrl,
            builder: (_, value, __) {
              final canAdd = value.text.trim().isNotEmpty && !_saving;
              return SizedBox(
                width: double.infinity,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity:  canAdd ? 1.0 : 0.35,
                  child: ElevatedButton(
                    onPressed: canAdd ? () => _save(_titleCtrl.text) : null,
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
                            l10n.habitAddTodoSubmitButton,
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
      );

    // 【2026-06-29】useScaffold=false は list のみ返す (Tab 埋め込み)。
    if (!widget.useScaffold) return list;
    return Scaffold(
      // AppBar がドラッグハンドル・ヘッダー・閉じるボタンを代替
      appBar: AppBar(
        title: Text(l10n.habitAddTodoTitle),
        // leading の戻るボタンは GoRouter が自動付与
      ),
      body: list,
    );
  }
}

// 【FEAT-210】旧 `_todoCategories` 定数は削除。`kSabiHabitCategories`（FEAT-210
// で導入した共通定数）に統一済み。FEAT-201 のカテゴリ 4 値とは別経路の二重管理を
// 解消した。

// ── 優先度ピル（TodoQuickAddSheet と同一） ────────────────────────────────────

class _PriorityPill extends StatelessWidget {
  final String       label;
  final String       value;
  final bool         selected;
  final Color        color;
  final VoidCallback onTap;

  const _PriorityPill({
    required this.label,
    required this.value,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? color.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? color.withValues(alpha: 0.7)
                : Colors.white.withValues(alpha: 0.1),
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

// ── 難易度ピル（TodoQuickAddSheet と同一） ────────────────────────────────────

class _DifficultyPill extends StatelessWidget {
  final String       label;
  final String       value;
  final int          exp;
  final bool         selected;
  final VoidCallback onTap;

  const _DifficultyPill({
    required this.label,
    required this.value,
    required this.exp,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.primary.withValues(alpha: 0.18)
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? AppTheme.primary.withValues(alpha: 0.7)
                  : Colors.white.withValues(alpha: 0.1),
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
