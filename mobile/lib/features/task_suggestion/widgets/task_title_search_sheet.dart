// 【FEAT-467 (2026-07-02)】タイトル入力用の検索 popup。
//
// タップされた title TextField の代わりに showGeneralDialog で表示。
// 戻り値 TaskSuggestion?:
//   - 候補タップ → 該当の TaskSuggestion
//   - 「新規追加」タップ → ad-hoc TaskSuggestion(id: -1, title: 入力文字)
//   - キャンセル (閉じる / 背景タップ) → null
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
// 【2026-07-09】type='event' の時にテンプレートも検索候補に含めるための import。
// TimelineTemplate は timeline_provider が re-export しているため単一 import で十分。
import '../../timeline/providers/timeline_provider.dart';
import '../models/task_suggestion.dart';
import '../providers/task_suggestion_provider.dart';

class TaskTitleSearchSheet extends ConsumerStatefulWidget {
  final String type;
  final String initialText;

  const TaskTitleSearchSheet({
    super.key,
    required this.type,
    this.initialText = '',
  });

  static Future<TaskSuggestion?> show(
    BuildContext context, {
    required String type,
    String initialText = '',
  }) {
    return showGeneralDialog<TaskSuggestion>(
      context: context,
      barrierDismissible: true,
      barrierLabel: AppLocalizations.of(context)!
          .taskSuggestionSearchSheetCloseLabel,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (dialogContext, __, ___) {
        final media = MediaQuery.of(dialogContext);
        return Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: media.size.width - 48,
              height: media.size.height * 0.75,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: AppTheme.sheetBackground,
                border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.4),
                  width: 1.5,
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 24,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: TaskTitleSearchSheet(type: type, initialText: initialText),
            ),
          ),
        );
      },
      transitionBuilder: (_, animation, __, child) => ScaleTransition(
        scale: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  ConsumerState<TaskTitleSearchSheet> createState() =>
      _TaskTitleSearchSheetState();
}

class _TaskTitleSearchSheetState extends ConsumerState<TaskTitleSearchSheet> {
  late final TextEditingController _queryCtrl;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _query = widget.initialText;
    _queryCtrl = TextEditingController(text: widget.initialText);
    _queryCtrl.addListener(() {
      setState(() => _query = _queryCtrl.text);
    });
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  List<TaskSuggestion> _filter(List<TaskSuggestion> all) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all
        .where((s) =>
            s.title.toLowerCase().contains(q) ||
            s.hint.toLowerCase().contains(q))
        .toList();
  }

  void _select(TaskSuggestion suggestion) {
    HapticFeedback.selectionClick();
    Navigator.of(context).pop(suggestion);
  }

  /// 「〜として新規追加」ボタン押下時: ad-hoc TaskSuggestion を pop で返す。
  ///
  /// 【2026-07-07 更新】旧 hotfix (即時 SharedPreferences 保存) は撤回。
  /// カスタム候補への保存は各 add page (add_event_page / add_todo_page /
  /// add_habit_page) の **保存成功後** に full form state 付きで実施する。
  /// これにより form 書きかけキャンセル時の副作用ゼロ + form state 全体を
  /// 「覚え直す」体験になる。
  void _addCustom() {
    final title = _query.trim();
    if (title.isEmpty) return;
    HapticFeedback.selectionClick();
    Navigator.of(context).pop(
      TaskSuggestion(
        id: -1,
        type: widget.type,
        title: title,
        category: '',
        emoji: '',
        hint: '',
        order: 0,
      ),
    );
  }

  /// 【2026-07-09】type=='event' の時、TimelineTemplate を TaskSuggestion に mapping。
  ///
  /// テンプレートは SharedPreferences ローカルなので同期的に取得可能。
  /// title / category / memo を suggestion に載せ、hint に「HH:MM - HH:MM」形式で
  /// 時間帯を表示 (subtitle で視認性 UP、user が「これはテンプレート」と一目で判別可能)。
  /// id は `-1000 - <template.id.hashCode>` で衝突回避 (master は正の id、custom は -1)。
  ///
  /// 【時間帯の auto-fill について】
  /// 本 fix では **title / category / memo のみ** を pre-fill。時間 field は user 側で
  /// 手動選択 (テンプレート項目の hint で確認可)。full auto-fill 化は将来 TaskSuggestion
  /// に startHM/endHM field 追加で対応可能 (v1.1+ スコープ)。
  /// 【FEAT-489 Phase 2E】hint は locale 依存なので build() で解決した [l10n] を渡す。
  List<TaskSuggestion> _templatesAsSuggestions(
      AppLocalizations l10n, List<TimelineTemplate> templates) {
    return templates.map((t) {
      final startHM = '${t.startHour.toString().padLeft(2, '0')}:'
          '${t.startMinute.toString().padLeft(2, '0')}';
      final endHM = '${t.endHour.toString().padLeft(2, '0')}:'
          '${t.endMinute.toString().padLeft(2, '0')}';
      return TaskSuggestion(
        id:       -1000 - t.id.hashCode,  // 一意化 (負値領域で master/custom と衝突なし)
        type:     'event',
        title:    t.title,
        category: t.category,
        emoji:    '📋',  // テンプレート視覚差別化
        hint:     l10n.taskSuggestionTemplateHint(startHM, endHM),
        order:    -1,  // list の上部に表示 (master 前、user は「テンプレを再利用したい」意図が強い)
        memo:     t.memo.isNotEmpty ? t.memo : null,
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final masterAsync = ref.watch(taskSuggestionsProvider(widget.type));
    final customAsync = ref.watch(customSuggestionsProvider(widget.type));
    // 【2026-07-09】type=='event' の時のみテンプレートも watch。type=='todo'/'habit'
    // では null 扱い = 従来通り master + custom のみ表示。
    final templates = widget.type == 'event'
        ? ref.watch(timelineTemplatesProvider)
        : const <TimelineTemplate>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(),
        const Divider(color: Colors.white12, height: 8, thickness: 0.5),
        _buildSearchField(),
        const Divider(height: 1, color: Colors.white12),
        Expanded(
            child: _buildList(l10n, masterAsync, customAsync, templates)),
      ],
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              AppLocalizations.of(context)!.taskSuggestionSearchSheetTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20, color: Colors.white70),
            tooltip: AppLocalizations.of(context)!
                .taskSuggestionSearchSheetCloseLabel,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: TextField(
        controller: _queryCtrl,
        autofocus: true,
        maxLength: 100,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText:
              AppLocalizations.of(context)!.taskSuggestionSearchSheetHint,
          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
          prefixIcon: const Icon(Icons.search, color: Colors.white54),
          suffixIcon: _query.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, color: Colors.white54),
                  onPressed: () {
                    _queryCtrl.clear();
                    setState(() => _query = '');
                  },
                )
              : null,
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.06),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.20)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide:
                BorderSide(color: AppTheme.primary.withValues(alpha: 0.8)),
          ),
          counterText: '',
        ),
      ),
    );
  }

  /// 【2026-07-07】master (Backend TaskSuggestion) + custom (端末ローカル) を
  /// merge して表示。
  ///
  /// ## Merge 方針
  ///
  /// - master 優先: 同一 title (大文字小文字無視) がある場合、master 版のみ表示
  ///   (master は admin curated で category / emoji / hint 完備、UX 優位)
  /// - master → custom の順で並べる: admin 意図の並び (order) を尊重、user 追加
  ///   分は bottom に追加 (自分用のカスタムは絞込検索でヒットさせる想定)
  ///
  /// ## エラーハンドリング
  ///
  /// - master 取得失敗 (network error) でも custom は表示: オフライン運用でも
  ///   自分が過去追加した候補は使える
  /// - master loading 中: circular progress (custom 分だけ先に見せる UX は
  ///   実質的に無意味、両方待つほうが素直)
  Widget _buildList(
    AppLocalizations l10n,
    AsyncValue<List<TaskSuggestion>> masterAsync,
    AsyncValue<List<TaskSuggestion>> customAsync,
    List<TimelineTemplate> templates,
  ) {
    // 【2026-07-09】テンプレートは SharedPreferences 同期取得 = master fetch 失敗時
    // (network error / cold start) でも表示可能。オフライン運用でもテンプレート
    // からの検索は使える設計。
    final templateSuggestions = _templatesAsSuggestions(l10n, templates);

    return masterAsync.when(
      loading: () {
        // 【2026-07-09】master 取得中でもテンプレート + custom があれば先に表示。
        // Backend cold start 中の user 体験改善。
        final custom = customAsync.valueOrNull ?? const <TaskSuggestion>[];
        final merged = _merge(templateSuggestions, const <TaskSuggestion>[], custom);
        final filtered = _filter(merged);
        if (filtered.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return _buildSuggestionList(filtered);
      },
      error: (_, __) {
        // master 取得失敗でも template + custom があれば見せる (オフライン fallback)
        final custom = customAsync.valueOrNull ?? const <TaskSuggestion>[];
        final merged = _merge(templateSuggestions, const <TaskSuggestion>[], custom);
        if (merged.isEmpty) return _buildEmptyState(networkError: true);
        final filtered = _filter(merged);
        if (filtered.isEmpty) return _buildEmptyState(networkError: false);
        return _buildSuggestionList(filtered);
      },
      data: (masterAll) {
        final custom = customAsync.valueOrNull ?? const <TaskSuggestion>[];
        final merged = _merge(templateSuggestions, masterAll, custom);
        final filtered = _filter(merged);
        if (filtered.isEmpty) return _buildEmptyState(networkError: false);
        return _buildSuggestionList(filtered);
      },
    );
  }

  /// 【2026-07-09 拡張】3 source (template / master / custom) を dedup で merge。
  ///
  /// 表示順序: **テンプレート (最優先) → master → custom**。
  ///   - テンプレートは user が明示的に登録したので「今すぐ再利用したい意図」が強い、最上位表示
  ///   - master は Backend admin curated (category / emoji / hint 完備)
  ///   - custom は user 独自履歴 (bottom 表示、絞込検索で拾う想定)
  ///
  /// dedup 優位順: **テンプレート > master > custom** (先に入った title が勝つ)。
  /// 同 title が master にもある場合は「テンプレを優先表示」で時間帯を見せる。
  List<TaskSuggestion> _merge(
    List<TaskSuggestion> templates,
    List<TaskSuggestion> master,
    List<TaskSuggestion> custom,
  ) {
    final seenTitles = <String>{};
    final result = <TaskSuggestion>[];
    for (final list in [templates, master, custom]) {
      for (final s in list) {
        if (seenTitles.add(s.title.toLowerCase())) {
          result.add(s);
        }
      }
    }
    return result;
  }

  Widget _buildSuggestionList(List<TaskSuggestion> items) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        ...items.map(_buildItem),
        if (_query.trim().isNotEmpty) _buildAddButton(),
      ],
    );
  }

  Widget _buildItem(TaskSuggestion s) {
    return ListTile(
      leading: s.emoji.isNotEmpty
          ? Text(s.emoji, style: const TextStyle(fontSize: 22))
          : const Icon(Icons.task_alt, color: Colors.white54),
      title: Text(s.title, style: const TextStyle(color: Colors.white)),
      subtitle: _buildSubtitle(s),
      onTap: () => _select(s),
    );
  }

  Widget? _buildSubtitle(TaskSuggestion s) {
    final parts = <String>[];
    if (s.category.isNotEmpty) parts.add(s.category);
    if (s.hint.isNotEmpty) parts.add(s.hint);
    if (parts.isEmpty) return null;
    return Text(
      parts.join(' · '),
      style:
          TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12),
    );
  }

  Widget _buildAddButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: OutlinedButton.icon(
        icon: const Icon(Icons.add),
        label: Text(AppLocalizations.of(context)!
            .taskSuggestionSearchSheetAddCustomButton(_query.trim())),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.primaryLight,
          side: BorderSide(color: AppTheme.primaryLight.withValues(alpha: 0.5)),
          alignment: Alignment.centerLeft,
        ),
        onPressed: _addCustom,
      ),
    );
  }

  Widget _buildEmptyState({required bool networkError}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            networkError ? Icons.wifi_off : Icons.search_off,
            color: Colors.white38,
            size: 40,
          ),
          const SizedBox(height: 12),
          Text(
            networkError
                ? AppLocalizations.of(context)!
                    .taskSuggestionSearchSheetEmptyNetworkError
                : AppLocalizations.of(context)!
                    .taskSuggestionSearchSheetEmptyNoMatch,
            style: const TextStyle(color: Colors.white54),
            textAlign: TextAlign.center,
          ),
          if (_query.trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildAddButton(),
          ],
        ],
      ),
    );
  }
}
