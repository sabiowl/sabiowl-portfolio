import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/category_request_dialog.dart';
import '../../../shared/widgets/sabi_category_chips.dart';
import '../../../l10n/app_localizations.dart';
import '../models/habit.dart';
import '../providers/habits_provider.dart';
import 'habit_detail_page.dart'; // habitDetailProvider のため

// 【FEAT-213】カテゴリ色は `kSabiHabitCategories`（11 値）から動的に生成。
// API（`categoriesProvider`）が返す可変カテゴリリストとの突合用フォールバック Map。
// `kSabiHabitCategories` をハードコード再宣言する代わりに `Map.fromEntries` で
// 自動生成することで、将来カテゴリ追加時の二重メンテを回避する。
final _habitCategoryColors = <String, Color>{
  for (final entry in kSabiHabitCategories) entry.$1: entry.$2,
};

class EditHabitPage extends ConsumerStatefulWidget {
  final int habitId;
  const EditHabitPage({super.key, required this.habitId});

  @override
  ConsumerState<EditHabitPage> createState() => _EditHabitPageState();
}

class _EditHabitPageState extends ConsumerState<EditHabitPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _memoController = TextEditingController();
  final _checklistController = TextEditingController();

  String _category = '運動';
  String _frequency = 'daily';
  String _resetCycle = 'daily';
  String _habitType = 'count'; // 表示のみ・変更不可
  String _difficulty = 'normal';
  bool _isLoading = false;
  bool _initialized = false; // 初期化済みフラグ（2回目以降のbuildで上書きしない）
  String? _error;

  // チェックリスト編集用
  List<ChecklistItem> _existingItems = [];
  final List<int> _deleteItemIds = [];
  final List<String> _addItems = [];

  // 【FEAT-213 真実値】CATEGORY_CHOICES（11 値）の subset。API 障害時の
  // 安全フォールバック用。'メンタル' は migration 0066 で '精神' にリネーム済。
  // 【FEAT-307】5/23 P0 積み残し解消、死語リテラル除去。
  static const _defaultCategories = [
    '運動', '学習', '健康', '精神',
  ];
  // _frequencies / _resetCycles / _difficulties は l10n 化のため各 build メソッド内でインライン定義。

  @override
  void initState() {
    super.initState();
    // FEAT-109: HabitDetailPage からの遷移ではプロバイダーがキャッシュ済みのため
    // ref.read() で同期的に取得し、initState 内（ビルド前）で直接フィールドに代入する。
    // initState はビルド前なので setState() 不要。直接代入が最初のビルドに反映される。
    final cached = ref.read(habitDetailProvider(widget.habitId)).valueOrNull;
    if (cached != null) _applyHabit(cached);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _memoController.dispose();
    _checklistController.dispose();
    super.dispose();
  }

  /// initState() から呼ぶ用（setState 不要 — ビルド前に直接代入）
  void _applyHabit(Habit habit) {
    if (_initialized) return;
    _nameController.text = habit.name;
    _memoController.text = habit.memo;
    _category      = habit.category;
    _frequency     = habit.frequency;
    _resetCycle    = habit.resetCycle;
    _habitType     = habit.habitType;
    _difficulty    = habit.difficulty;
    _existingItems = List.from(habit.checklistItems);
    _initialized   = true;
  }

  /// build() / ref.listen から呼ぶ用（setState でリビルドをトリガー）
  void _initFromHabit(Habit habit) {
    if (_initialized) return;
    _applyHabit(habit);
    setState(() {}); // フィールド変更後にリビルドを要求
  }

  @override
  Widget build(BuildContext context) {
    // FEAT-109: ref.listen は API 非同期ロード完了時のフォールバック。
    // 詳細ページからの遷移（キャッシュ済み）は initState() で処理済みのため、
    // このリスナーは実質的に直接 URL 遷移時のみ発火する。
    ref.listen<AsyncValue<Habit>>(habitDetailProvider(widget.habitId), (_, next) {
      next.whenData((habit) {
        if (!_initialized) _initFromHabit(habit);
      });
    });

    final habitAsync = ref.watch(habitDetailProvider(widget.habitId));

    // 修正②: categoriesProvider を habitAsync.when() の外側で無条件に watch
    // → 常にサブスクリプションが安定し、Riverpod の依存追跡が乱れない
    final categoriesAsync = ref.watch(categoriesProvider);

    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.habitEditHabitAppBarTitle)),
      body: habitAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text(l10n.habitArchivedPageErrorSabi_message, style: const TextStyle(color: Colors.red)),
        ),
        data: (_) => Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_error != null) _buildErrorBanner(),
              _buildSection(l10n.habitAddHabitNameLabel, _buildNameField()),
              _buildSection(
                l10n.habitQuickAddCategoryLabel,
                categoriesAsync.when(
                  data: (cats) => _buildCategoryChips(cats),
                  loading: () => const SizedBox(
                    height: 40,
                    child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                  error: (_, __) => _buildCategoryChips(_defaultCategories),
                ),
              ),
              _buildSection(l10n.habitEditHabitTypeSectionLabel, _buildTypeDisplay()),
              if (_habitType == 'checklist')
                _buildSection(l10n.habitAddHabitChecklistSectionLabel, _buildChecklistEditor()),
              _buildSection(l10n.habitAddHabitFreqLabel, _buildFrequencySelector()),
              _buildSection(l10n.habitAddHabitResetCycleLabel, _buildResetCycleSelector()),
              // 【FEAT-434 (2026-06-14)】Habit (count/checklist) の難易度 UI は廃止、
              // ToDo (habit_type='todo') のみ難易度選択を表示する。
              if (_habitType == 'todo')
                _buildSection(l10n.habitEditHabitDifficultyLabel, _buildDifficultySelector()),
              _buildSection(l10n.habitAddTodoMemoHint, _buildMemoField()),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _submit,
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Text(l10n.habitEditHabitSaveButton),
              ),
              SizedBox(height: 24 + MediaQuery.of(context).padding.bottom),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSection(String title, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 16),
          child: Text(
            title,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.white70),
          ),
        ),
        child,
      ],
    );
  }

  Widget _buildNameField() {
    final l10n = AppLocalizations.of(context)!;
    return TextFormField(
      controller: _nameController,
      decoration: InputDecoration(
        hintText: l10n.habitEditHabitNameHint,
        prefixIcon: const Icon(Icons.edit_outlined),
      ),
      maxLength: 100,
      validator: (v) =>
          (v == null || v.trim().isEmpty) ? l10n.habitAddHabitNameValidator : null,
    );
  }

  // 【FEAT-210】カテゴリチップ共通コンポーネント化。API 由来の `allCategories`
  // を `(ラベル, 色)` タプルに射影してから `SabiCategoryChips` に渡す。
  // 未知カテゴリは `_habitCategoryColors` のフォールバック色（青灰）を当てる。
  Widget _buildCategoryChips(List<String> allCategories) {
    final tuples = allCategories.map<(String, Color)>((cat) {
      final color = _habitCategoryColors[cat] ?? const Color(0xFF78909C);
      return (cat, color);
    }).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SabiCategoryChips(
          categories:       tuples,
          selectedCategory: _category,
          onChanged:        (cat) => setState(() => _category = cat),
        ),
        // FEAT-148: カテゴリ追加リクエストリンク（変更なし）
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

  Widget _buildTypeDisplay() {
    final isCount = _habitType == 'count';
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Icon(
            isCount ? Icons.add_circle_outline : Icons.checklist,
            color: Colors.white38,
            size: 20,
          ),
          const SizedBox(width: 10),
          Text(
            isCount ? l10n.habitAddHabitTypeCount : l10n.habitAddHabitTypeChecklist,
            style: const TextStyle(color: Colors.white54, fontSize: 14),
          ),
          const Spacer(),
          Text(
            l10n.habitEditHabitTypeReadOnlyNote,
            style: const TextStyle(color: Colors.white30, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildChecklistEditor() {
    final visibleExisting =
        _existingItems.where((i) => !_deleteItemIds.contains(i.id)).toList();

    return Column(
      children: [
        // 既存項目（削除予定を除く）
        ...visibleExisting.map((item) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              // 【FEAT-441 (2026-06-17)】Icons.drag_handle → Icons.drag_indicator
              // (6 点 2×3 グリッド) に変更、home_page と統一。
              leading: const Icon(Icons.drag_indicator, color: Colors.white38),
              title: Text(item.text,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              trailing: IconButton(
                icon: const Icon(Icons.close, color: Colors.red, size: 18),
                onPressed: () =>
                    setState(() => _deleteItemIds.add(item.id)),
              ),
            )),
        // 新規追加した項目
        ..._addItems.asMap().entries.map((entry) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading:
                  const Icon(Icons.add_circle_outline, color: AppTheme.primary, size: 20),
              title: Text(entry.value,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              trailing: IconButton(
                icon: const Icon(Icons.close, color: Colors.red, size: 18),
                onPressed: () =>
                    setState(() => _addItems.removeAt(entry.key)),
              ),
            )),
        // 入力フィールド
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _checklistController,
                decoration: InputDecoration(
                  hintText: AppLocalizations.of(context)!.habitAddHabitChecklistItemHint,
                  prefixIcon: const Icon(Icons.add),
                ),
                onFieldSubmitted: (_) => _addChecklistItemInEditor(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.add_circle, color: AppTheme.primary),
              onPressed: _addChecklistItemInEditor,
            ),
          ],
        ),
      ],
    );
  }

  void _addChecklistItemInEditor() {
    final text = _checklistController.text.trim();
    if (text.isNotEmpty) {
      setState(() {
        _addItems.add(text);
        _checklistController.clear();
      });
    }
  }

  Widget _buildFrequencySelector() {
    final l10n = AppLocalizations.of(context)!;
    final frequencies = [
      ('daily',   l10n.habitAddHabitFreqDaily),
      ('weekly',  l10n.habitAddHabitFreqWeekly),
      ('monthly', l10n.habitAddHabitFreqMonthly),
    ];
    return Wrap(
      spacing: 8,
      children: frequencies.map((f) {
        final selected = _frequency == f.$1;
        return ChoiceChip(
          label: Text(f.$2),
          selected: selected,
          onSelected: (_) => setState(() => _frequency = f.$1),
          selectedColor: AppTheme.primary.withValues(alpha: 0.3),
          labelStyle: TextStyle(
            color: selected ? AppTheme.primary : Colors.white70,
          ),
        );
      }).toList(),
    );
  }

  Widget _buildResetCycleSelector() {
    final l10n = AppLocalizations.of(context)!;
    final resetCycles = [
      ('daily',   l10n.habitAddHabitFreqDaily),
      ('weekly',  l10n.habitAddHabitFreqWeekly),
      ('monthly', l10n.habitAddHabitFreqMonthly),
      ('yearly',  l10n.habitAddHabitFreqYearly),
    ];
    return Wrap(
      spacing: 8,
      children: resetCycles.map((r) {
        final selected = _resetCycle == r.$1;
        return ChoiceChip(
          label: Text(r.$2),
          selected: selected,
          onSelected: (_) => setState(() => _resetCycle = r.$1),
          selectedColor: AppTheme.primary.withValues(alpha: 0.3),
          labelStyle: TextStyle(
            color: selected ? AppTheme.primary : Colors.white70,
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDifficultySelector() {
    final l10n = AppLocalizations.of(context)!;
    // 【FEAT-334 (2026-05-27)】add_habit_page と同パターン。
    // 【FEAT-380 (2026-05-29)】「6 軸全 Lv 5 ALL で 1 枠目解放」仕様にアップグレード。
    // 編集経路では「すでに legendary なら維持可能、normal/hard/easy → legendary 昇格は
    // 残スロット要」とする UX (現在 _difficulty == 'legendary' なら disabled しない)。
    final difficulties = [
      ('easy',      l10n.habitEditHabitDiffEasy,      Colors.green),
      ('normal',    l10n.habitEditHabitDiffNormal,    Colors.blue),
      ('hard',      l10n.habitEditHabitDiffHard,      Colors.orange),
      ('legendary', l10n.habitEditHabitDiffLegendary, Colors.purple),
    ];
    final playerAsync = ref.watch(playerNotifierProvider);
    final player = playerAsync.valueOrNull;
    final slotsTotal = player?.legendarySlotsTotal ?? 0;
    final slotsUsed  = player?.legendarySlotsUsed ?? 0;
    final canCreateLegendary = player?.canCreateLegendary ?? false;
    final nextUnlockLv = player?.nextLegendaryUnlockLevel ?? 5;
    final isUnlocked = slotsTotal > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: difficulties.map((d) {
            final selected = _difficulty == d.$1;
            final isLegendary = d.$1 == 'legendary';
            // 編集経路: 既に legendary を選択している場合は disabled しない (維持許可)。
            final disabled = isLegendary
                && !canCreateLegendary
                && _difficulty != 'legendary';
            return Expanded(
              child: GestureDetector(
                onTap: disabled
                    ? () {
                        // 【FEAT-380】未解禁 (total=0) と既上限 (used>=total>0) で文言分岐
                        final message = slotsTotal == 0
                            ? l10n.habitEditHabitLegendaryLockedSabi_message
                            : l10n.habitEditHabitLegendarySlotLimitSabi_message(
                                slotsUsed, slotsTotal, nextUnlockLv);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(message),
                            duration: const Duration(seconds: 4),
                          ),
                        );
                      }
                    : () => setState(() => _difficulty = d.$1),
                child: Opacity(
                  opacity: disabled ? 0.4 : 1.0,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: selected
                          ? d.$3.withValues(alpha: 0.2)
                          : AppTheme.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selected ? d.$3 : Colors.white12,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: Text(
                      // 【FEAT-380】未解禁状態 (total=0) は「(未解禁)」、解禁済は「(used/total)」
                      isLegendary
                          ? (isUnlocked
                              ? l10n.habitEditHabitLegendaryUnlockedChip(d.$2, slotsUsed, slotsTotal)
                              : l10n.habitEditHabitLegendaryLockedChip(d.$2))
                          : d.$2,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: selected ? d.$3 : Colors.white54,
                        fontSize: 11,
                        fontWeight: selected
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        if (_difficulty == 'legendary')
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              canCreateLegendary
                  ? l10n.habitEditHabitLegendaryCurrentNote(slotsUsed, slotsTotal)
                  : (isUnlocked
                      ? l10n.habitEditHabitLegendaryNextUnlockNote(nextUnlockLv)
                      : l10n.habitEditHabitLegendaryLockedSabi_message),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 11,
              ),
            ),
          ),
      ],
    );
  }

  // FEAT-162: メモをクリップボードにコピー
  void _copyMemo() {
    final text = _memoController.text.trim();
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

  Widget _buildMemoField() {
    return Stack(
      alignment: Alignment.topRight,
      children: [
        TextFormField(
          controller: _memoController,
          maxLines:   4,
          minLines:   2,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText:  AppLocalizations.of(context)!.habitAddHabitMemoHint,
            hintStyle: const TextStyle(color: Colors.white38),
            filled:    true,
            fillColor: Colors.white.withValues(alpha: 0.06),
            prefixIcon: const Icon(Icons.notes_outlined, size: 18, color: Colors.white38),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:   BorderSide.none,
            ),
            contentPadding: const EdgeInsets.fromLTRB(14, 12, 42, 12),
          ),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _memoController,
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
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        const Icon(Icons.error_outline, color: Colors.red, size: 18),
        const SizedBox(width: 8),
        Expanded(
            child: Text(_error!,
                style: const TextStyle(color: Colors.red, fontSize: 13))),
      ]),
    );
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final body = <String, dynamic>{
        'name': _nameController.text.trim(),
        'category': _category,
        'frequency': _frequency,
        'reset_cycle': _resetCycle,
        'difficulty': _difficulty,
        'memo': _memoController.text.trim(),
      };
      if (_habitType == 'checklist') {
        if (_addItems.isNotEmpty) {
          body['add_checklist_items'] =
              _addItems.map((t) => {'text': t}).toList();
        }
        if (_deleteItemIds.isNotEmpty) {
          body['delete_checklist_items'] = _deleteItemIds;
        }
      }
      await ref
          .read(habitsNotifierProvider.notifier)
          .updateHabit(widget.habitId, body);
      if (!mounted) return;
      // 詳細ページのキャッシュを更新してから戻る
      ref.invalidate(habitDetailProvider(widget.habitId));
      Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = AppLocalizations.of(context)!.habitEditTodoSaveErrorSabi_message;
      });
    }
  }
}
