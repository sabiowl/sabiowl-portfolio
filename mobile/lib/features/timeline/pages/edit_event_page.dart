import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/services/notification_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/category_request_dialog.dart';
import '../../../shared/widgets/drum_roll_time_picker.dart';
import '../models/timeline_models.dart';
import '../providers/timeline_provider.dart';
import '../widgets/time_picker.dart';
import '../../calendar/providers/calendar_provider.dart';

/// 予定編集全画面ページ（FEAT-159）。
/// EditHabitPage と同じ GoRouter push 遷移で表示される。
/// タイムライン画面でイベントを長押しすると遷移する。
class EditEventPage extends ConsumerStatefulWidget {
  final TimelineEvent event;

  const EditEventPage({super.key, required this.event});

  @override
  ConsumerState<EditEventPage> createState() => _EditEventPageState();
}

class _EditEventPageState extends ConsumerState<EditEventPage> {
  final _formKey  = GlobalKey<FormState>();
  late final _titleCtrl = TextEditingController(text: widget.event.title);
  late final _memoCtrl  = TextEditingController(text: widget.event.memo);

  // 【2026-07-05】time-less な予定 (「時刻なし」で保存された event) の編集を
  // 保護するため、_startTime を nullable 化。旧実装 (late TimeOfDay + `?? now()`
  // フォールバック) では長押し編集で開始時刻が現在時刻に上書きされ、時間なしに
  // 戻せなくなる regression が発生していた。
  late TimeOfDay? _startTime;
  late TimeOfDay? _endTime;
  late String     _category;

  bool _submitting = false;
  bool _deleting   = false;

  // 【FEAT-244 hotfix】tuple の $1 (送信される値) を Backend
  // TIMELINE_CATEGORY_CHOICES (FEAT-208/213, migration 0065/0066) の日本語 11 値に統一。
  // 旧英語コード (study/business/exercise/...) は DRF choices 違反で HTTP 400 になる。
  // 表示ラベル ($2) と色 ($3) は不変。
  static List<(String, String, Color)> _getCategories(AppLocalizations l10n) => [
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
    ('その他', l10n.habitCategoryOther,       Color(0xFF78909C)),
  ];

  @override
  void initState() {
    super.initState();
    // 【2026-07-05】旧実装は `?? TimeOfDay.now()` フォールバックしていたが、
    // それでは「時刻なし」で保存された event が長押し編集で強制的に現在時刻に
    // 上書きされ、保存時に元の null に戻せなくなる。null は null のまま保持し、
    // ユーザーが「時刻を設定する」ボタンをタップした時のみ現在時刻に埋める。
    _startTime = widget.event.startTime;
    _endTime   = widget.event.endTime;
    _category  = widget.event.category;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _memoCtrl.dispose();
    super.dispose();
  }

  // ── 時刻ピッカー ──────────────────────────────────────────────────

  Future<void> _pickTime({required bool isStart}) async {
    // 【2026-07-05】_startTime が nullable になったため、picker の initial は
    // 現在時刻フォールバック。picker から戻った picked は non-null 保証。
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

  // ── メモコピー ────────────────────────────────────────────────────

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

  // ── 保存 ──────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    HapticFeedback.mediumImpact();
    setState(() => _submitting = true);

    final d       = widget.event.date;
    final dateStr = '${d.year}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';

    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;

    try {
      // 【2026-07-05】_startTime が null (時刻なし) の場合は明示的に null を送信。
      // Backend TimelineEvent.start_time は null=True, blank=True なので許容される。
      // 旧実装は !== nullable のため常に現在時刻を保存しており、時間なし予定の
      // 長押し編集後に「時刻なし」状態を維持できなかった (Task 2 バグ 2026-07-05 報告)。
      await ref.read(timelineServiceProvider).updateEvent(
        widget.event.id,
        {
          'title':      _titleCtrl.text.trim(),
          'date':       dateStr,
          'start_time': _startTime != null
              ? '${_formatTime(_startTime!)}:00'
              : null,
          'end_time':   _endTime != null ? '${_formatTime(_endTime!)}:00' : null,
          'category':   _category,
          'icon_key':   'event',
          'memo':       _memoCtrl.text.trim(), // FEAT-159: メモを送信
        },
      );

      // 【FEAT-220】Calendar provider 統合: bootstrap + timelineEvents (family 全体) に統一
      ref.invalidate(calendarBootstrapProvider);
      ref.invalidate(timelineEventsProvider);

      // 【2026-07-07】FEAT-163「最近の予定」機能撤廃に伴い、履歴保存を廃止。

      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content:  Text(l10n.timelineEditEventPageSaveSnackbar),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content:  Text(l10n.timelineEditEventPageSaveErrorSnackbarSabi_message),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ── 削除 ──────────────────────────────────────────────────────────

  Future<void> _confirmDelete() async {
    HapticFeedback.lightImpact();
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          l10n.timelineEditEventPageDeleteDialogTitle,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          l10n.timelineDeleteDialogContent(widget.event.title),
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.timelineDeleteDialogCancel,
                style: const TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () {
              HapticFeedback.mediumImpact();
              Navigator.pop(ctx, true);
            },
            child: Text(
              l10n.timelineDeleteDialogConfirm,
              style: TextStyle(
                color:      AppTheme.danger,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    // 【FEAT-220】FEAT-220 で `calendarDataProvider(d.year, d.month)` 呼び出しを撤去
    // したため、ここでの `d` 変数は不要になった。
    final messenger = ScaffoldMessenger.of(context);

    try {
      // 削除前に通知をキャンセル（開始時刻通知 + 【FEAT-273】+15 分未完了リマインダー）
      await NotificationService.cancelTimelineEventNotification(widget.event.id);
      await NotificationService.cancelTimelineUncompletedReminder(widget.event.id);
      await ref.read(timelineServiceProvider).deleteEvent(widget.event.id);

      // 【FEAT-220】Calendar provider 統合: bootstrap + timelineEvents (family 全体) に統一
      ref.invalidate(calendarBootstrapProvider);
      ref.invalidate(timelineEventsProvider);

      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content:  Text(l10n.timelineEditEventPageDeleteSnackbar),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content:  Text(l10n.timelineEditEventPageDeleteErrorSnackbarSabi_message),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  // ── build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final busy = _submitting || _deleting;
    final l10n = AppLocalizations.of(context)!;
    final categories = _getCategories(l10n);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.timelineEditEventPageTitle),
        // leading の戻るボタンは GoRouter が自動付与
        actions: [
          // 削除ボタン（AppBar trailing）
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: l10n.timelineDeleteTooltip,
            onPressed: busy ? null : _confirmDelete,
            color: busy ? Colors.white24 : Colors.white54,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            16, 16, 16,
            16 + MediaQuery.of(context).padding.bottom,
          ),
          children: [

            // ── タイトル入力 ────────────────────────────────────
            TextFormField(
              controller: _titleCtrl,
              autofocus:  false,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText:  l10n.timelineEditEventPageTitleHint,
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
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? l10n.timelineTitleValidatorEmpty : null,
            ),

            const SizedBox(height: 16),

            // ── 時刻行（開始・終了）──────────────────────────────
            // 【2026-07-05】開始時刻も placeholder + clear ボタン対応。
            // null 状態 = 「時刻なし」= 終日予定として保存される。開始を clear すると
            // 終了も自動 clear（開始なしで終了だけ残る不整合状態を防ぐ）。
            Row(
              children: [
                Expanded(
                  child: TimePicker(
                    label:         l10n.timelineTimeStartOptionalLabel,
                    timeText:      _startTime != null
                        ? _formatTime(_startTime!)
                        : '-- : --',
                    isPlaceholder: _startTime == null,
                    onTap:         () => _pickTime(isStart: true),
                    onClear: _startTime != null
                        ? () {
                            HapticFeedback.selectionClick();
                            setState(() {
                              _startTime = null;
                              _endTime   = null;
                            });
                          }
                        : null,
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

            const SizedBox(height: 16),

            // ── カテゴリ ──────────────────────────────────────────
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

            // 【2026-07-07】「最近の予定」チップ (recentEventTitlesProvider) を撤廃。
            // 予定タイトルはサジェスト master (TaskSuggestion) のみで検索・入力する仕様に統一。

            const SizedBox(height: 20),

            // ── メモ欄（FEAT-159: 新規追加）──────────────────────
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

            // ── 保存ボタン ────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity:  busy ? 0.6 : 1.0,
                child: ElevatedButton(
                  onPressed: busy ? null : _submit,
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
                          l10n.timelineEditEventPageSaveButton,
                          style: const TextStyle(
                            fontSize:   15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ),

          ],
        ),
      ),
    );
  }
}
