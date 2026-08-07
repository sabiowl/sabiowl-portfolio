import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/category_request_dialog.dart';
import '../../../shared/widgets/sabi_category_chips.dart';
// 【2026-07-09】user 要望: テンプレート項目入力からも予定・ToDo・習慣と同じ検索を使えるように。
import '../../task_suggestion/widgets/task_title_search_sheet.dart';
import '../providers/timeline_provider.dart';
import '../widgets/time_picker.dart';
import '../../../shared/widgets/drum_roll_time_picker.dart';

// 時刻フォーマットヘルパー
String _fmtHM(int h, int m) =>
    '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

/// テンプレート編集ページ（全画面）。
/// FEAT-175: EditTemplateSheet（BottomSheet）→ 全画面ページに変更。
class EditTemplatePage extends ConsumerStatefulWidget {
  const EditTemplatePage({super.key, required this.template});

  final TimelineTemplate template;

  @override
  ConsumerState<EditTemplatePage> createState() => _EditTemplatePageState();
}

class _EditTemplatePageState extends ConsumerState<EditTemplatePage> {
  // ── ロジックは EditTemplateSheet からそのまま流用 ─────────────
  late final TextEditingController _titleCtrl;
  // 【FEAT-197】既存テンプレートの memo を初期表示・編集できるようにする。
  late final TextEditingController _memoCtrl;
  late String _selectedSlot;
  late int    _startHour;
  late int    _startMinute;
  late int    _endHour;
  late int    _endMinute;
  // 【2026-07-05】旧実装ではカテゴリ選択が欠落しており、テンプレート編集時に
  // 変更できなかった (add_template_page とは非対称。ユーザー報告 2026-07-05)。
  // add_template_page と同様に SabiCategoryChips で 11 値から選ばせる。
  late String _selectedCategory;
  bool        _saving   = false;
  bool        _deleting = false;

  bool get _isBuiltIn =>
      widget.template.id == 'wake' || widget.template.id == 'sleep';

  @override
  void initState() {
    super.initState();
    final t       = widget.template;
    _titleCtrl    = TextEditingController(text: t.title);
    _memoCtrl     = TextEditingController(text: t.memo);
    _selectedSlot = t.timeSlot ?? 'custom';
    _startHour    = t.startHour;
    _startMinute  = t.startMinute;
    _endHour      = t.endHour;
    _endMinute    = t.endMinute;
    // 【2026-07-05】旧テンプレートで category が kSabiHabitCategories 11 値の
    // どれとも一致しないケース (旧英語コード migration 済 or 空文字) は
    // 「その他」にフォールバック (全 stat 均等分散、消失防止)。
    _selectedCategory = _resolveCategory(t.category);
  }

  /// テンプレートの category が 11 値のどれかにマッチするか判定し、
  /// 一致しなければ「その他」にフォールバック。
  static String _resolveCategory(String stored) {
    for (final entry in kSabiHabitCategories) {
      if (entry.$1 == stored) return stored;
    }
    return 'その他';
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _memoCtrl.dispose();
    super.dispose();
  }

  /// 【FEAT-197】メモをクリップボードへコピー（add_event_page.dart 同パターン）。
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

  void _selectPreset(String slotId) {
    final preset = kTimeSlotPresets.firstWhere(
      (p) => p.$1 == slotId,
      orElse: () => kTimeSlotPresets.last,
    );
    setState(() {
      _selectedSlot = slotId;
      if (preset.$4 >= 0) {
        _startHour   = preset.$4;
        _startMinute = preset.$5;
        _endHour     = preset.$6;
        _endMinute   = preset.$7;
      }
    });
  }

  Future<void> _pickTime({required bool isStart}) async {
    final initial = isStart
        ? TimeOfDay(hour: _startHour, minute: _startMinute)
        : TimeOfDay(hour: _endHour,   minute: _endMinute);
    final picked = await showDrumRollTimePicker(
      context:     context,
      initialTime: initial,
    );
    if (picked == null || !mounted) return;
    HapticFeedback.selectionClick();
    setState(() {
      if (isStart) {
        _startHour   = picked.hour;
        _startMinute = picked.minute;
      } else {
        _endHour   = picked.hour;
        _endMinute = picked.minute;
      }
    });
  }

  void _save() {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) return;
    HapticFeedback.mediumImpact();
    setState(() => _saving = true);

    final updated = widget.template.copyWith(
      title:       title,
      startHour:   _startHour,
      startMinute: _startMinute,
      endHour:     _endHour,
      endMinute:   _endMinute,
      timeSlot:    _selectedSlot == 'custom' ? null : _selectedSlot,
      // 【2026-07-05】編集画面で選択されたカテゴリを反映。旧実装は copyWith に
      // 含めておらず、UI 追加後もサイレントに破棄される regression を防ぐ。
      category:    _selectedCategory,
      // 【FEAT-197】編集されたメモを反映。空文字でも問題なし。
      memo:        _memoCtrl.text.trim(),
    );
    ref.read(timelineTemplatesProvider.notifier).update(updated);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _confirmDelete() async {
    HapticFeedback.lightImpact();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          AppLocalizations.of(context)!.timelineEditTemplatePageDeleteDialogTitle,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          AppLocalizations.of(context)!.timelineDeleteDialogContent(widget.template.title),
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppLocalizations.of(context)!.timelineDeleteDialogCancel,
                style: const TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () {
              HapticFeedback.mediumImpact();
              Navigator.pop(ctx, true);
            },
            child: Text(
              AppLocalizations.of(context)!.timelineDeleteDialogConfirm,
              style: const TextStyle(
                color:      Colors.redAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      setState(() => _deleting = true);
      ref.read(timelineTemplatesProvider.notifier).remove(widget.template.id);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCustomSlot = _selectedSlot == 'custom';
    final busy = _saving || _deleting;

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: Text(AppLocalizations.of(context)!.timelineEditTemplatePageTitle),
        actions: [
          // 削除ボタン（AppBar 右側）
          Opacity(
            opacity: _isBuiltIn ? 0.3 : 1.0,
            child: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: _isBuiltIn
                  ? AppLocalizations.of(context)!.timelineEditTemplatePageDeleteBuiltInTooltip
                  : AppLocalizations.of(context)!.timelineDeleteTooltip,
              color: busy ? Colors.white24 : Colors.white54,
              onPressed: (_isBuiltIn || busy) ? null : _confirmDelete,
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          16, 16, 16,
          24 + MediaQuery.of(context).padding.bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // ── タイトル入力 ──────────────────────────────────
            // 【2026-07-09 hotfix】user 要望: 予定・ToDo・習慣と同じ検索 UI
            // (TaskTitleSearchSheet) を使えるように、readOnly + onTap で起動する
            // 方式に変更。add_template_page と同じパターン。
            TextField(
              controller: _titleCtrl,
              readOnly:   true,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText:  AppLocalizations.of(context)!.timelineTitleHint,
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
                    _selectedCategory = suggestion.category;
                  }
                  if (suggestion.memo != null && suggestion.memo!.isNotEmpty) {
                    _memoCtrl.text = suggestion.memo!;
                  }
                  // 編集画面では既存の startHour/endHour を尊重、timeSlot 一致
                  // 時のみプリセット選択に切替 (時刻自動同期は _selectPreset 内で実施)。
                  if (suggestion.timeSlot != null) {
                    final slot = suggestion.timeSlot!;
                    final matches = kTimeSlotPresets.any((p) => p.$1 == slot);
                    if (matches) _selectPreset(slot);
                  }
                });
              },
            ),

            const SizedBox(height: 16),

            // ── 時間帯プリセット ──────────────────────────────
            Text(
              AppLocalizations.of(context)!.timelineTemplateTimeSlotLabel,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection:  Axis.horizontal,
                itemCount:        kTimeSlotPresets.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final p          = kTimeSlotPresets[i];
                  final isSelected = _selectedSlot == p.$1;
                  return GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      _selectPreset(p.$1);
                    },
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
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(p.$3,
                              style: const TextStyle(fontSize: 13)),
                          const SizedBox(width: 4),
                          Text(
                            p.$2,
                            style: TextStyle(
                              color: isSelected
                                  ? AppTheme.primary
                                  : Colors.white54,
                              fontSize:   12,
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            // ── 時刻 ─────────────────────────────────────────
            if (isCustomSlot) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TimePicker(
                      label:    AppLocalizations.of(context)!.timelineTimeStartLabel,
                      timeText: _fmtHM(_startHour, _startMinute),
                      onTap:    () => _pickTime(isStart: true),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TimePicker(
                      label:    AppLocalizations.of(context)!.timelineTimeEndLabel,
                      timeText: _fmtHM(_endHour, _endMinute),
                      onTap:    () => _pickTime(isStart: false),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 10),
              Text(
                '${_fmtHM(_startHour, _startMinute)} 〜 ${_fmtHM(_endHour, _endMinute)}',
                style: TextStyle(
                  color:    Colors.white.withValues(alpha: 0.38),
                  fontSize: 13,
                ),
              ),
            ],

            const SizedBox(height: 20),

            // ── 【2026-07-05】カテゴリ選択 (add_template_page.dart と対称) ──
            // 旧実装は selector 自体が欠落しており、テンプレート編集画面から
            // カテゴリを変更できなかった (ユーザー報告)。add_template_page と
            // 同じ SabiCategoryChips + kSabiHabitCategories 11 値で統一。
            Text(
              AppLocalizations.of(context)!.habitQuickAddCategoryLabel,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 8),
            SabiCategoryChips(
              categories:       kSabiHabitCategories,
              selectedCategory: _selectedCategory,
              onChanged: (cat) => setState(() => _selectedCategory = cat),
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

            const SizedBox(height: 20),

            // ── 【FEAT-197】メモ欄 + コピーアイコン（add_event_page.dart 同パターン） ──
            Stack(
              alignment: Alignment.topRight,
              children: [
                TextField(
                  controller: _memoCtrl,
                  maxLines:   4,
                  minLines:   2,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText:  AppLocalizations.of(context)!.timelineMemoHint,
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

            // ── 保存ボタン ────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity:  busy ? 0.6 : 1.0,
                child: ElevatedButton(
                  onPressed: busy ? null : _save,
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
                            strokeWidth: 2,
                            color:       Colors.white,
                          ),
                        )
                      : Text(
                          AppLocalizations.of(context)!.timelineEditTemplatePageSaveButton,
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
