import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/analytics/posthog_service.dart';  // FEAT-200
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/category_request_dialog.dart';
import '../widgets/time_picker.dart';
import '../../../shared/widgets/drum_roll_time_picker.dart';
import '../providers/timeline_provider.dart';
import '../../task_suggestion/models/task_suggestion.dart';  // 【2026-07-07】upsert 用
import '../../task_suggestion/providers/task_suggestion_provider.dart';  // 【2026-07-07】master 判定
import '../../task_suggestion/services/custom_suggestion_store.dart';  // 【2026-07-07】upsert
import '../../task_suggestion/widgets/task_title_search_sheet.dart'; // 【FEAT-467】
import '../../calendar/providers/calendar_provider.dart'; // FEAT-153: カレンダードット更新
import '../../../shared/widgets/add_task_modal.dart';

void showAddEventModal(BuildContext context, DateTime date) {
  final l10n = AppLocalizations.of(context)!;
  showAddTaskModal(context, title: l10n.timelineAddEventLabel, child: AddEventPage(useScaffold: false, initialDate: date));
}

/// タイムライン予定追加ページ（全画面・FEAT-151）。
/// 習慣追加（AddHabitPage）と同じ GoRouter push 遷移で表示される。
///
/// 【2026-06-29】AddHabitPage と同じ `useScaffold: bool` パラメータを導入し、
/// `calendar_add_page.dart` (ホーム FAB / カレンダー FAB 経由の 3 タブ統合ページ)
/// の予定タブ内に直接埋め込めるようにした。旧実装は calendar_add_page.dart 側で
/// 予定 form を独立実装として複製 (~500 LOC) しており、UI 修正の二度手間が
/// 発生していた (「予定名」ラベル追加時に両方への同期漏れが 2 度発生)。
/// 本統合で予定 form の実装は本ファイル 1 箇所に集約、二度手間の構造解消。
class AddEventPage extends ConsumerStatefulWidget {
  final DateTime initialDate;

  /// 【2026-06-29】Scaffold + AppBar の有無を切替えるフラグ (AddHabitPage 準拠)。
  /// - `true` (default): 単独画面として AppBar 付き Scaffold で表示 (既存挙動、router 経路)。
  /// - `false`: Form 部分のみを返す (calendar_add_page の TabBarView 内に埋め込む用途)。
  ///   呼び出し側 widget の TabBar / AppBar と二重表示しないよう構造選択を可能にする。
  final bool useScaffold;
  // 【FEAT-493】フリーメモ変換経路からの pre-fill タイトル (省略可)
  final String? initialTitle;

  const AddEventPage({
    super.key,
    required this.initialDate,
    this.useScaffold = true,
    this.initialTitle,
  });

  @override
  ConsumerState<AddEventPage> createState() => _AddEventPageState();
}

class _AddEventPageState extends ConsumerState<AddEventPage> {
  final _formKey   = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _memoCtrl  = TextEditingController();
  // 【FEAT-498 §2.2 (2026-07-26)】日付選択の state 化。
  // 旧: widget.initialDate を _submit() で直接使用 = user は変更不可
  // 新: _selectedDate = widget.initialDate で init、user が日付ピッカー button
  //     から変更可能。仮メモから「明日の予定」を作れる (gameplay-review §2-1
  //     本質的解決)。
  late DateTime _selectedDate;
  TimeOfDay? _startTime;
  TimeOfDay? _endTime;
  // 【FEAT-244 hotfix】Backend の TIMELINE_CATEGORY_CHOICES は FEAT-208/213 以降
  // 日本語 11 値のみ受け付ける。旧 default `'study'` (英語コード) は choices 違反で
  // HTTP 400 となり「追加がうまくいきませんでした」SnackBar が出ていた。
  // 【20260729 user feedback 対応】default '学習' → 'その他' に変更。学習/運動
  // 偏重の user 報告に応え、「その他」は CATEGORY_STAT_MAP で 6 stat 均等分配、
  // 選択負担軽減 + Sabi 哲学「押し付けない」に整合 (kSabiHabitCategories と同期)。
  String     _category   = 'その他';
  String     _timeSlot   = 'none';
  bool       _submitting = false;

  // 【FEAT-244 hotfix】tuple の $1 (送信される値) を Backend
  // TIMELINE_CATEGORY_CHOICES (FEAT-208/213, migration 0065/0066) の日本語 11 値に統一。
  // 旧英語コード (study/business/exercise/...) は DRF choices 違反で HTTP 400 になる。
  // 表示ラベル ($2) と色 ($3) は不変。
  // 【20260729 user feedback 対応】「その他」を先頭配置 (kSabiHabitCategories と同期)。
  static List<(String, String, Color)> _getCategories(AppLocalizations l10n) => [
    ('その他', l10n.habitCategoryOther,       Color(0xFF78909C)),  // 先頭配置 + default (20260729)
    ('学習',   l10n.habitCategoryStudy,       Color(0xFF60A5FA)),
    ('仕事',   l10n.habitCategoryWork,        Color(0xFF5B9BD5)),
    ('運動',   l10n.habitCategoryExercise,    Color(0xFFF87171)),
    ('体力',   l10n.habitCategoryPhysical,    Color(0xFFFB923C)),
    ('美容',   l10n.habitCategoryBeauty,      Color(0xFFF472B6)),
    ('健康',   l10n.habitCategoryHealth,      Color(0xFF34D399)),
    ('精神',   l10n.habitCategoryMental,      Color(0xFFA78BFA)),
    ('創造',   l10n.habitCategoryCreativity,  Color(0xFFFFD60A)),
    ('社交',   l10n.habitCategorySocial,      Color(0xFFEC6EA0)),
    ('休息',   l10n.habitCategoryRest,        Color(0xFF64748B)),
  ];

  static List<(String, String)> _getTimeSlots(AppLocalizations l10n) => [
    ('none',   l10n.timelineAddEventTimeSlotNone),
    ('am',     l10n.timelineAddEventTimeSlotAm),
    ('pm',     l10n.timelineAddEventTimeSlotPm),
    ('custom', l10n.timelineAddEventTimeSlotCustom),
  ];

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.initialDate;
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

  TimeOfDay _roundedNow() {
    final now = DateTime.now();
    final min = now.minute;
    final rounded = min < 45
        ? now.copyWith(minute: ((min ~/ 15) + 1) * 15, second: 0)
        : now.copyWith(hour: now.hour + 1, minute: 0, second: 0);
    return TimeOfDay.fromDateTime(rounded);
  }

  void _onSelectTimeSlot(String slot) {
    HapticFeedback.selectionClick();
    setState(() {
      _timeSlot = slot;
      switch (slot) {
        case 'none':
          _startTime = null;
          _endTime   = null;
        case 'am':
          _startTime = const TimeOfDay(hour: 10, minute: 0);
          _endTime   = null;
        case 'pm':
          _startTime = const TimeOfDay(hour: 14, minute: 0);
          _endTime   = null;
        case 'custom':
          _startTime ??= _roundedNow();
      }
    });
  }

  /// 【FEAT-498 §2.2 (2026-07-26)】日付ピッカー起動 → 選択で _selectedDate 更新。
  /// Pre-mortem S3 予防: calendar_page.dart の table_calendar と同じ範囲制約
  /// (first=1 年前 / last=2 年先) を採用、既存カレンダー UI との mental model 整合。
  Future<void> _pickDate() async {
    HapticFeedback.selectionClick();
    final now  = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(now.year - 1, now.month, now.day),
      lastDate:  DateTime(now.year + 2, now.month, now.day),
      builder: (context, child) {
        // Sabi 哲学: darkTheme + AppTheme.primary で dialog をアプリ配色に統一
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: AppTheme.primary,
                  onPrimary: Colors.white,
                  surface: AppTheme.card,
                  onSurface: Colors.white,
                ),
            dialogTheme: DialogThemeData(backgroundColor: AppTheme.surface),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
    if (picked == null || !mounted) return;
    setState(() => _selectedDate = picked);
  }

  /// 【FEAT-498 §2.2】日付表示用の format (「2026 / 07 / 26 (金)」)。
  String _formatSelectedDate(DateTime d, AppLocalizations l10n) {
    final weekdays = [
      l10n.timelineDateStripWeekdayMon,
      l10n.timelineDateStripWeekdayTue,
      l10n.timelineDateStripWeekdayWed,
      l10n.timelineDateStripWeekdayThu,
      l10n.timelineDateStripWeekdayFri,
      l10n.timelineDateStripWeekdaySat,
      l10n.timelineDateStripWeekdaySun,
    ];
    final w = weekdays[d.weekday - 1];
    return '${d.year} / ${d.month.toString().padLeft(2, '0')} / '
           '${d.day.toString().padLeft(2, '0')} ($w)';
  }

  Future<void> _pickTime({required bool isStart}) async {
    final initial = isStart
        ? (_startTime ?? TimeOfDay.now())
        : (_endTime ?? _startTime ?? TimeOfDay.now());
    final picked = await showDrumRollTimePicker(
      context:     context,
      initialTime: initial,
    );
    if (picked == null) return;
    HapticFeedback.selectionClick();
    setState(() {
      if (isStart) {
        _startTime = picked;
        if (_endTime != null) {
          final startMin = picked.hour * 60 + picked.minute;
          final endMin   = _endTime!.hour * 60 + _endTime!.minute;
          if (endMin <= startMin) _endTime = null;
        }
      } else {
        _endTime = picked;
      }
    });
  }

  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  void _copyMemo() {
    final text = _memoCtrl.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:  Text(AppLocalizations.of(context)!.timelineMemoSnackbar),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── 送信（FEAT-151 で sheet を全画面ページ化、内側ロジックはそのまま） ──
  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    HapticFeedback.mediumImpact();
    setState(() => _submitting = true);

    // 【FEAT-498 §2.2 (2026-07-26)】widget.initialDate 直参照 → _selectedDate
    // (user が日付ピッカーで変更可能な state) を使用。仮メモから「明日の予定」
    // 作成 flow を有効化。
    final d       = _selectedDate;
    final dateStr = '${d.year}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final startStr =
        _startTime != null ? '${_formatTime(_startTime!)}:00' : null;
    final endStr =
        _endTime != null ? '${_formatTime(_endTime!)}:00' : null;

    // ScaffoldMessenger を pop 前に取得（pop 後に親の Messenger を参照）
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;

    try {
      await ref.read(timelineServiceProvider).createEvent({
        'title':    _titleCtrl.text.trim(),
        'date':     dateStr,
        if (startStr != null) 'start_time': startStr,
        if (endStr   != null) 'end_time':   endStr,
        'category': _category,
        'icon_key': 'event',
        'memo':     _memoCtrl.text.trim(),
      });

      // FEAT-200: タイムライン予定作成をトラッキング
      // （テンプレ自動展開経由ではないユーザー手動作成のみ。timelineAutoCreateProvider は対象外）
      await PosthogService.instance.capture('timeline_event_created', properties: {
        'category': _category,
      });

      // 【FEAT-220】Calendar provider 統合: bootstrap + timelineEvents (family 全体) に統一
      // （FEAT-153 のカレンダードット更新も bootstrap で吸収される）
      ref.invalidate(calendarBootstrapProvider);
      ref.invalidate(timelineEventsProvider);

      // 【2026-07-07】FEAT-163「最近の予定」機能撤廃に伴い、履歴保存を廃止。
      // 検索はサジェスト master (TaskSuggestion) のみに統一。

      // 【2026-07-07】新規追加した title を端末ローカルカスタム候補として upsert。
      // master data に無い title のみ、full form state (category / timeSlot / memo)
      // 付きで保存 → 次回同 title 選択時に form 自動入力。失敗しても save flow は継続。
      await _maybePersistCustomSuggestion();

      if (!mounted) return;
      Navigator.of(context).pop(true);
      messenger.showSnackBar(
        SnackBar(
          content:  Text(l10n.timelineAddEventPageSaveSnackbar),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e, st) {
      // 【FEAT-244 診断】catch (_) で真因が握り潰されていたため、debugPrint で
      // 例外型 + メッセージ + 簡易スタックを出力する。本番リリース時も残してよい
      // 軽量診断ログ（CLAUDE.md「過去の不具合事例」原則: silent failure を作らない）。
      debugPrint('[add_event_page._submit] failed: $e\n$st');
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content:  Text(l10n.timelineAddEventPageErrorSnackbarSabi_message),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 【2026-07-07】新規追加した title を端末ローカルカスタム候補として upsert。
  ///
  /// 条件:
  /// - title が非空
  /// - Backend master data に無い title (case-insensitive) のみ
  ///
  /// 保存内容: form 現在の state 全体 (category / timeSlot / memo)。
  /// 次回同 title を検索して選択したとき add page が nullable field を確認して
  /// setState で form を自動入力する経路になる。
  ///
  /// best-effort: 失敗しても save flow は継続 (try/catch で吞み込み)。
  Future<void> _maybePersistCustomSuggestion() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) return;
    try {
      final master = await ref.read(taskSuggestionsProvider('event').future);
      final inMaster = master
          .any((s) => s.title.toLowerCase() == title.toLowerCase());
      if (inMaster) return;
      final memo = _memoCtrl.text.trim();
      await CustomSuggestionStore.upsert(
        TaskSuggestion(
          id:       -1,
          type:     'event',
          title:    title,
          category: _category,
          emoji:    '',
          hint:     '',
          order:    0,
          timeSlot: _timeSlot,
          memo:     memo.isEmpty ? null : memo,
        ),
      );
    } catch (_) {
      // best-effort: 保存失敗しても save flow は継続
    }
  }

  @override
  Widget build(BuildContext context) {
    // 【2026-06-29】useScaffold=false (calendar_add_page の TabBarView 内)
    // では Form のみ返す。AppBar 二重表示 / Scaffold 二重を回避 (AddHabitPage と同 pattern)。
    final l10n       = AppLocalizations.of(context)!;
    final categories = _getCategories(l10n);
    final timeSlots  = _getTimeSlots(l10n);
    final form = Form(
      key: _formKey,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          16, 16, 16,
          16 + MediaQuery.of(context).padding.bottom,
        ),
        children: [

            // ── タイトル入力 ──────────────────────────────────────────
            // 【2026-06-29】add_habit_page.dart の見出しスタイル (fontSize: 13 /
            // FontWeight.bold / Colors.white70) と統一して「予定名」ラベルを表示。
            // 何の入力フォームか一目で分かるようにする UX 改善。
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                l10n.timelineAddEventPageTitleLabel,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.white70,
                ),
              ),
            ),
            // 【FEAT-467 (2026-07-02)】readOnly + onTap で検索 popup を開く。
            TextFormField(
              controller: _titleCtrl,
              readOnly:   true,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText:  l10n.timelineTitleHint,
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
                  type: 'event',
                  initialText: _titleCtrl.text,
                );
                if (suggestion == null || !mounted) return;
                setState(() {
                  _titleCtrl.text = suggestion.title;
                  if (suggestion.category.isNotEmpty) {
                    _category = suggestion.category;
                  }
                  // 【2026-07-07】カスタム候補の nullable field を復元。
                  // Backend master data には無い field なので通常 null (何もしない)。
                  // ローカル custom で保存されていた場合のみ form が自動入力される。
                  if (suggestion.timeSlot != null) {
                    _timeSlot = suggestion.timeSlot!;
                    // 時刻帯セレクター内部処理は _onSelectTimeSlot が担うが、custom 復元
                    // の場合は _startTime / _endTime は都度ユーザーが再入力する運用
                    // (時刻自体は日付依存で毎回異なるため、記憶しない)。
                  }
                  if (suggestion.memo != null && suggestion.memo!.isNotEmpty) {
                    _memoCtrl.text = suggestion.memo!;
                  }
                });
              },
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? l10n.timelineTitleValidatorEmpty : null,
            ),

            const SizedBox(height: 20),

            // 【2026-07-07】「最近の予定」チップ (recentEventTitlesProvider) を撤廃。
            // 予定タイトルはサジェスト master (TaskSuggestion、GET
            // /api/task-suggestions/?type=event) のみで検索・入力する仕様に統一
            // (ToDo / 習慣 add page と揃える)。

            // ── 日付選択 (【FEAT-498 §2.2】仮メモから任意日付の予定作成対応)
            // 旧: widget.initialDate 固定 = user は変更不可
            // 新: 「日付」button tap で showDatePicker、選択後 _selectedDate 更新。
            // 仮メモから「明日の予定」を作れる (gameplay-review §2-1 本質的解決)。
            Text(
              l10n.timelineAddEventPageDateLabel,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today_outlined,
                        color: Colors.white54, size: 18),
                    const SizedBox(width: 12),
                    Text(
                      _formatSelectedDate(_selectedDate, l10n),
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14),
                    ),
                    const Spacer(),
                    const Icon(Icons.arrow_drop_down,
                        color: Colors.white54, size: 20),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── 時刻帯セレクター ──────────────────────────────────────
            // 【2026-07-02】何のセレクターか一目で分かるよう「時間帯」ラベルを
            // 追加。直下の「カテゴリ」ラベル (line 466 相当、white54/12) と
            // 同スタイルで local consistency を優先。
            Text(
              l10n.timelineAddEventPageTimeSlotLabel,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: timeSlots.map((slot) {
                  final isSelected = _timeSlot == slot.$1;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => _onSelectTimeSlot(slot.$1),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppTheme.primary.withValues(alpha: 0.22)
                              : Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isSelected
                                ? AppTheme.primary.withValues(alpha: 0.55)
                                : Colors.white.withValues(alpha: 0.1),
                            width: isSelected ? 1.5 : 1.0,
                          ),
                        ),
                        child: Text(
                          slot.$2,
                          style: TextStyle(
                            color: isSelected ? AppTheme.primary : Colors.white54,
                            fontSize:   13,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),

            // ── 詳細時刻ピッカー（'custom' のみ）────────────────────
            if (_timeSlot == 'custom') ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TimePicker(
                      label:         l10n.timelineTimeStartLabel,
                      timeText:      _startTime != null
                          ? _formatTime(_startTime!)
                          : '--:--',
                      isPlaceholder: _startTime == null,
                      onTap:         () => _pickTime(isStart: true),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TimePicker(
                      label:         l10n.timelineTimeEndOptionalLabel,
                      timeText:      _endTime != null
                          ? _formatTime(_endTime!)
                          : '-- : --',
                      isPlaceholder: _endTime == null,
                      onTap:         () => _pickTime(isStart: false),
                      onClear: _endTime != null
                          ? () {
                              HapticFeedback.selectionClick();
                              setState(() => _endTime = null);
                            }
                          : null,
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 16),

            // ── カテゴリ ──────────────────────────────────────────────
            Text(
              l10n.habitQuickAddCategoryLabel,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: categories.map((cat) {
                  final isSelected = _category == cat.$1;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _category = cat.$1);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? cat.$3.withValues(alpha: 0.22)
                              : Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isSelected
                                ? cat.$3.withValues(alpha: 0.55)
                                : Colors.white.withValues(alpha: 0.1),
                            width: isSelected ? 1.5 : 1.0,
                          ),
                        ),
                        child: Text(
                          cat.$2,
                          style: TextStyle(
                            color: isSelected ? cat.$3 : Colors.white54,
                            fontSize:   12,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            // 【20260729 user feedback 対応 (案 C)】「その他」選択時のみ 6 stat 均等
            // 分配の hint を薄く表示 (add_habit_page / add_todo_page と同型)。
            if (_category == 'その他')
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Text(
                  l10n.habitAddTodoCategoryHint,
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

            const SizedBox(height: 20),

            // ── メモ欄 ────────────────────────────────────────────────
            Stack(
              alignment: Alignment.topRight,
              children: [
                TextFormField(
                  controller: _memoCtrl,
                  maxLines:   4,
                  minLines:   2,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText:  l10n.timelineMemoHint,
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

            const SizedBox(height: 24),

            // ── 送信ボタン ────────────────────────────────────────────
            // FEAT-155: 未入力時は非活性（CalendarAddPage の予定タブと統一）
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _titleCtrl,
              builder: (_, value, __) {
                final canSubmit = value.text.trim().isNotEmpty && !_submitting;
                return SizedBox(
                  width: double.infinity,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity:  canSubmit ? 1.0 : 0.35,
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
                      child: _submitting
                          ? const SizedBox(
                              height: 18, width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color:       Colors.white,
                              ),
                            )
                          : Text(
                              l10n.timelineAddEventPageSaveButton,
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

    // 【2026-06-29】useScaffold=false は form のみ返す (Tab 埋め込み)。
    if (!widget.useScaffold) return form;
    return Scaffold(
      // AppBar がドラッグハンドル・ヘッダー Row・閉じるボタンを代替
      appBar: AppBar(
        title: Text(l10n.timelineAddEventLabel),
        // leading の戻るボタンは GoRouter が自動付与
      ),
      body: form,
    );
  }
}
