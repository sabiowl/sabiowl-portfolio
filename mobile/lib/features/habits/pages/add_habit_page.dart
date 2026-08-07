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

void showAddHabitModal(BuildContext context) =>
    showAddTaskModal(context, title: AppLocalizations.of(context)!.habitAddHabitModalTitle, child: const AddHabitPage(useScaffold: false));

class AddHabitPage extends ConsumerStatefulWidget {
  /// 【2026-06-27】Scaffold + AppBar の有無を切替えるフラグ。
  /// - `true` (default): 単独画面として AppBar 付き Scaffold で表示 (既存挙動、router 経路)。
  /// - `false`: Form 部分のみを返す (calendar_add_page の TabBarView 内に埋め込む用途)。
  ///   呼び出し側 widget の TabBar / AppBar と二重表示しないよう構造選択を可能にする。
  final bool useScaffold;
  // 【FEAT-493】フリーメモ変換経路からの pre-fill タイトル (省略可)
  final String? initialTitle;

  const AddHabitPage({super.key, this.useScaffold = true, this.initialTitle});

  @override
  ConsumerState<AddHabitPage> createState() => _AddHabitPageState();
}

class _AddHabitPageState extends ConsumerState<AddHabitPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _memoController = TextEditingController();
  final _checklistController = TextEditingController();

  // 【20260729 user feedback 対応】default '学習' → 'その他' に変更。
  // 「その他」は CATEGORY_STAT_MAP で 6 stat 均等分配、選択負担を減らしつつ
  // 「選ばなくても均等に届く」= Sabi 哲学「押し付けない」に整合。
  // 旧 FEAT-147 の「より直感的なデフォルト」は 4 値時代の名残、11 値時代の
  // 現在は「その他」default が偏り解消に有効 (user 実利用 feedback より)。
  String _category = 'その他';
  String _frequency = 'daily';
  String _resetCycle = 'daily';
  String _habitType = 'count';
  String _difficulty = 'normal';
  bool _isLoading = false;
  String? _error;

  final List<String> _checklistItems = [];

  // 【FEAT-210】カテゴリ定数は `kSabiHabitCategories` に統一（旧 `_categories` 削除）。
  // _frequencies / _resetCycles は l10n 化のため build メソッド内でインライン定義。
  @override
  void initState() {
    super.initState();
    if (widget.initialTitle != null) {
      _nameController.text = widget.initialTitle!;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _memoController.dispose();
    _checklistController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 【2026-07-02】UI を add_event_page / add_todo_page と統一。
    // 変更点:
    // - ListView padding を safe bottom 対応 (fromLTRB)
    // - 「習慣名」だけ primary 見出し (13/bold/white70)、他項目は sub 見出し
    //   (11/bold/white40/letterSpacing 0.5) の 2 段構成 (add_todo と同 pattern)
    // - 入力フォーム 3 種 (name/memo/checklist) を filled + rounded box に統一
    // - 送信ボタンを styleFrom で primary bg + rounded 14 + fontSize 15 bold に統一
    // - _typeCard の背景色を surface → white 5% に変更 (event 時刻帯セレクターと同色)
    // 触らない項目 (機能側 UI): SabiCategoryChips / ChoiceChip (頻度/リセット周期) /
    // チェックリストエディター機能 / エラーバナー / 「もっと追加する？」リンク
    final l10n = AppLocalizations.of(context)!;
    final form = Form(
      key: _formKey,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          16, 16, 16,
          16 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          if (_error != null) _buildErrorBanner(),
          // 「習慣名」だけ大きな primary 見出し (add_todo の「ToDo名」と同 pattern)
          _buildSection(l10n.habitAddHabitNameLabel, _buildNameField(context, l10n)),
          _buildSubSection(l10n.habitQuickAddCategoryLabel, _buildCategoryChips()),
          _buildSubSection(l10n.habitAddHabitTypeLabel, _buildTypeSelector()),
          if (_habitType == 'checklist')
            _buildSubSection(l10n.habitAddHabitChecklistSectionLabel, _buildChecklistEditor()),
          _buildSubSection(l10n.habitAddHabitFreqLabel, _buildFrequencySelector()),
          _buildSubSection(l10n.habitAddHabitResetCycleLabel, _buildResetCycleSelector()),
          // 【FEAT-434 (2026-06-14)】Habit (count/checklist) の難易度 UI は廃止。
          // _difficulty はデフォルト 'normal' のまま送信される (Backend は
          // calc_habit_base_exp で参照しない、field 自体は維持)。
          _buildSubSection(l10n.habitAddTodoMemoHint, _buildMemoField()),
          const SizedBox(height: 24),
          // 【2026-06-27】必須項目未入力時はボタンを非活性化 + 半透明で「押せない」
          // ことを視覚的に明示。予定/ToDo タブ (calendar_add_page) の
          // ValueListenableBuilder + AnimatedOpacity パターンに統一。
          // 非活性条件:
          //   - 習慣名が空
          //   - 送信中 (_isLoading)
          //   - チェックリスト型かつ項目 1 件もなし (元々 _submit 内で validate していた
          //     条件をボタン側にも反映、ユーザーが「押してもエラー」体験を避ける)
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _nameController,
            builder: (_, value, __) {
              final hasName = value.text.trim().isNotEmpty;
              final hasChecklist = _habitType != 'checklist' ||
                  _checklistItems.isNotEmpty;
              final canSubmit = hasName && hasChecklist && !_isLoading;
              // 【2026-07-02】ボタンスタイルを add_event/add_todo と統一。
              // width full + AnimatedOpacity + styleFrom (primary bg + rounded 14 +
              // padding vertical 14) + fontSize 15 bold + 絵文字。
              return SizedBox(
                width: double.infinity,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: canSubmit ? 1.0 : 0.35,
                  child: ElevatedButton(
                    onPressed: canSubmit ? _submit : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 18, width: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : Text(
                            l10n.habitAddHabitSubmitButton,
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

    // 【2026-06-27】useScaffold=false (calendar_add_page の TabBarView 内)
    // では Form のみ返す。AppBar 二重表示 / Scaffold 二重を回避。
    if (!widget.useScaffold) return form;

    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context)!.habitAddHabitAppBarTitle)),
      body: form,
    );
  }

  /// primary 見出し (「習慣名」用、add_event/add_todo の先頭ラベルと統一)。
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

  /// 【2026-07-02】サブ見出し (「カテゴリ」「タイプ」等)。
  /// add_event/add_todo のサブラベル (fontSize: 11, bold, white 40%,
  /// letterSpacing: 0.5) と統一。primary との段差でセクション階層を視覚化。
  Widget _buildSubSection(String title, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 18),
          child: Text(
            title,
            style: TextStyle(
              color:         Colors.white.withValues(alpha: 0.4),
              fontSize:      11,
              fontWeight:    FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ),
        child,
      ],
    );
  }

  /// 【2026-07-02】add_event/add_todo と統一した filled/rounded ボックス style。
  /// 3 種類 (name / memo / checklist 追加行) で共通利用する。
  InputDecoration _filledRoundedDecoration({
    required String hintText,
    EdgeInsets contentPadding = const EdgeInsets.symmetric(
        horizontal: 14, vertical: 12),
  }) {
    return InputDecoration(
      hintText:  hintText,
      hintStyle: const TextStyle(color: Colors.white38),
      filled:    true,
      fillColor: Colors.white.withValues(alpha: 0.06),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide:   BorderSide.none,
      ),
      contentPadding: contentPadding,
    );
  }

  // 【FEAT-467 (2026-07-02)】readOnly + onTap で検索 popup を開く。
  // 【2026-07-02 UI 統一】filled/rounded box style に変更 (add_event/add_todo と統一)。
  // prefixIcon (Icons.edit_outlined) は削除、hint 「タップして検索・入力」で
  // 検索アフォーダンスは十分担保される (add_todo も prefixIcon なし)。
  Widget _buildNameField(BuildContext context, AppLocalizations l10n) {
    return TextFormField(
      controller: _nameController,
      readOnly:   true,
      style: const TextStyle(color: Colors.white, fontSize: 15),
      decoration: _filledRoundedDecoration(hintText: l10n.habitAddTodoTitleHint),
      onTap: () async {
        HapticFeedback.selectionClick();
        final suggestion = await TaskTitleSearchSheet.show(
          context,
          type: 'habit',
          initialText: _nameController.text,
        );
        if (suggestion == null || !mounted) return;
        setState(() {
          _nameController.text = suggestion.title;
          if (suggestion.category.isNotEmpty) {
            _category = suggestion.category;
          }
          // 【2026-07-07】カスタム候補の nullable field を復元 (Backend
          // master には無いので通常 null、ローカル custom のみ発火)。
          if (suggestion.habitType != null) {
            _habitType = suggestion.habitType!;
          }
          if (suggestion.frequency != null) {
            _frequency = suggestion.frequency!;
          }
          if (suggestion.resetCycle != null) {
            _resetCycle = suggestion.resetCycle!;
          }
          if (suggestion.memo != null && suggestion.memo!.isNotEmpty) {
            _memoController.text = suggestion.memo!;
          }
        });
      },
      validator: (v) =>
          (v == null || v.trim().isEmpty) ? l10n.habitAddHabitNameValidator : null,
    );
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
        // 分配の hint を薄く表示。「その他 = 地味で選ばれない」印象を、
        // 「Sabi へのおまかせ」の物語性で置き換える。他カテゴリ選択時は非表示 =
        // 情報過多回避。
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

  Widget _buildTypeSelector() {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        Expanded(
          child: _typeCard(
            'count', Icons.add_circle_outline,
            l10n.habitAddHabitTypeCount, l10n.habitAddHabitTypeCountSub,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _typeCard(
            'checklist', Icons.checklist,
            l10n.habitAddHabitTypeChecklist, l10n.habitAddHabitTypeChecklistSub,
          ),
        ),
      ],
    );
  }

  Widget _typeCard(String value, IconData icon, String label, String sub) {
    final selected = _habitType == value;
    // 【2026-07-02 UI 統一】非選択時の背景を AppTheme.surface (=0xFF16213E、画面
    // 背景と近くカードが浮かない問題があった) から Colors.white 5% に変更。
    // add_event の時刻帯セレクター (white 5%) と同色でトーンを合わせる。
    // 選択時の primary 22% + border primary 55% はコントラスト維持のため変更なし。
    return GestureDetector(
      onTap: () => setState(() => _habitType = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primary.withValues(alpha: 0.22)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? AppTheme.primary.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.1),
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          children: [
            Icon(icon,
                color: selected ? AppTheme.primary : Colors.white54, size: 28),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                  color: selected ? AppTheme.primary : Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                )),
            Text(sub,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 11,
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildChecklistEditor() {
    return Column(
      children: [
        ..._checklistItems.asMap().entries.map((entry) {
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            // 【FEAT-441 (2026-06-17)】Icons.drag_handle → Icons.drag_indicator
            // (6 点 2×3 グリッド) に変更、home_page と統一。
            leading: const Icon(Icons.drag_indicator, color: Colors.white38),
            title: Text(entry.value,
                style: const TextStyle(color: Colors.white, fontSize: 14)),
            trailing: IconButton(
              icon: const Icon(Icons.close, color: Colors.red, size: 18),
              onPressed: () =>
                  setState(() => _checklistItems.removeAt(entry.key)),
            ),
          );
        }),
        Row(
          children: [
            Expanded(
              // 【2026-07-02 UI 統一】filled/rounded box style に変更。
              // prefixIcon (Icons.add) は右側の add_circle IconButton と重複する
              // ため削除、視覚的に軽くする。
              child: TextFormField(
                controller: _checklistController,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: _filledRoundedDecoration(hintText: AppLocalizations.of(context)!.habitAddHabitChecklistItemHint),
                onFieldSubmitted: (_) => _addChecklistItem(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.add_circle, color: AppTheme.primary),
              onPressed: _addChecklistItem,
            ),
          ],
        ),
      ],
    );
  }

  void _addChecklistItem() {
    final text = _checklistController.text.trim();
    if (text.isNotEmpty) {
      setState(() {
        _checklistItems.add(text);
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

  /// 【2026-07-02】メモをクリップボードへコピー (add_event/add_todo と同 pattern)。
  /// 空文字は no-op、成功時は SnackBar でサビ口調の完了通知 (絵文字はサビ台詞規則の
  /// 例外的許可範囲としてシステム SnackBar のみ絵文字可)。
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
    // 【2026-07-02 UI 統一】filled/rounded box style + minLines/maxLines を
    // add_event/add_todo の memo 欄と統一。
    // 【2026-07-02 (v2)】右上に copy アイコンを Stack で重ねる (add_event/add_todo と
    // 同 pattern)。空文字時は opacity 0.15 で非活性感、入力後は 0.7。
    // contentPadding の右側 (42) は copy アイコン領域確保用 (14 + 20 + 8 = 42)。
    return Stack(
      alignment: Alignment.topRight,
      children: [
        TextFormField(
          controller: _memoController,
          maxLines: 4,
          minLines: 2,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: _filledRoundedDecoration(
            hintText: AppLocalizations.of(context)!.habitAddHabitMemoHint,
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
    if (_habitType == 'checklist' && _checklistItems.isEmpty) {
      setState(() => _error = AppLocalizations.of(context)!.habitAddHabitChecklistErrorSabi_message);
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await ref.read(habitsNotifierProvider.notifier).createHabit(
            name:       _nameController.text.trim(),
            category:   _category,
            frequency:  _frequency,
            resetCycle: _resetCycle,
            habitType:  _habitType,
            difficulty: _difficulty,
            memo:       _memoController.text.trim(),
            checklistItems: _habitType == 'checklist' ? _checklistItems : [],
          );

      // 【2026-07-07】新規追加した title を端末ローカルカスタム候補として upsert。
      // master data に無い title のみ、full form state (category / habitType /
      // frequency / resetCycle / memo) 付きで保存 → 次回同 title 選択時に自動入力。
      await _maybePersistCustomSuggestion();

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = AppLocalizations.of(context)!.habitAddHabitErrorSabi_message;
      });
    }
  }

  /// 【2026-07-07】新規追加した title を端末ローカルカスタム候補として upsert。
  ///
  /// 条件:
  /// - title が非空
  /// - Backend master data に無い title (case-insensitive) のみ
  ///
  /// 保存内容: form 現在の state 全体 (category / habitType / frequency /
  /// resetCycle / memo)。**difficulty は保存しない** (FEAT-434 で Habit の
  /// 難易度 UI 廃止 = 常に 'normal' 送信、記憶する意味なし)。
  /// best-effort: 失敗しても save flow は継続。
  Future<void> _maybePersistCustomSuggestion() async {
    final title = _nameController.text.trim();
    if (title.isEmpty) return;
    try {
      final master = await ref.read(taskSuggestionsProvider('habit').future);
      final inMaster = master
          .any((s) => s.title.toLowerCase() == title.toLowerCase());
      if (inMaster) return;
      final memo = _memoController.text.trim();
      await CustomSuggestionStore.upsert(
        TaskSuggestion(
          id:         -1,
          type:       'habit',
          title:      title,
          category:   _category,
          emoji:      '',
          hint:       '',
          order:      0,
          habitType:  _habitType,
          frequency:  _frequency,
          resetCycle: _resetCycle,
          memo:       memo.isEmpty ? null : memo,
        ),
      );
    } catch (_) {
      // best-effort
    }
  }
}
