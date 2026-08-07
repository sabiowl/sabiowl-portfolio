import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/category_request_dialog.dart';
// 【2026-07-09】user 要望: テンプレート項目入力からも予定・ToDo・習慣と同じ検索を使えるように。
import '../../task_suggestion/widgets/task_title_search_sheet.dart';
import '../providers/timeline_provider.dart';
import '../widgets/time_picker.dart';
import '../../../shared/widgets/drum_roll_time_picker.dart';
import '../../../shared/widgets/sabi_category_chips.dart';

// 時刻フォーマットヘルパー
String _fmtHM(int h, int m) =>
    '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

/// テンプレート新規登録ページ（全画面）。
/// FEAT-175: AddTemplateSheet（BottomSheet）→ 全画面ページに変更。
class AddTemplatePage extends ConsumerStatefulWidget {
  const AddTemplatePage({super.key});

  @override
  ConsumerState<AddTemplatePage> createState() => _AddTemplatePageState();
}

class _AddTemplatePageState extends ConsumerState<AddTemplatePage> {
  // ── ロジックは AddTemplateSheet からそのまま流用 ──────────────
  final _titleCtrl     = TextEditingController();
  // 【FEAT-197】テンプレートにメモを保存できるようにする（TimelineTemplate.memo / FEAT-196）
  final _memoCtrl      = TextEditingController();
  String _selectedSlot = 'morning';
  int    _startHour    = 6;
  int    _startMinute  = 0;
  int    _endHour      = 8;
  int    _endMinute    = 0;
  bool   _saving       = false;

  // 【FEAT-210】カテゴリ定数は `kSabiHabitCategories` に統一（旧 `_categories` 削除）。
  // タイムラインは「健康」をデフォルトに（kDefaultTemplates と整合）
  String _selectedCategory = '健康';

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

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) return;
    HapticFeedback.mediumImpact();
    setState(() => _saving = true);

    final newTemplate = TimelineTemplate(
      id:          'custom_${DateTime.now().millisecondsSinceEpoch}',
      title:       title,
      startHour:   _startHour,
      startMinute: _startMinute,
      endHour:     _endHour,
      endMinute:   _endMinute,
      // 【FEAT-208】UI で選択したカテゴリを反映（旧ハードコード 'other' から変更）
      category:    _selectedCategory,
      iconKey:     'event',
      isEnabled:   true,
      timeSlot:    _selectedSlot == 'custom' ? null : _selectedSlot,
      // 【FEAT-197】メモ入力を反映。空文字でも問題なし（後方互換）。
      memo:        _memoCtrl.text.trim(),
    );

    await ref.read(timelineTemplatesProvider.notifier).add(newTemplate);
    if (!mounted) return;

    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    ref.read(timelineAutoCreateProvider(today).future).catchError((_) {});

    Navigator.of(context).pop(); // 全画面ページを閉じて前画面（DefaultsPage）へ戻る
  }

  @override
  Widget build(BuildContext context) {
    final isCustomSlot = _selectedSlot == 'custom';

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: Text(AppLocalizations.of(context)!.timelineAddTemplatePageTitle),
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
            // 方式に変更。sheet 側でテンプレート・master・custom を merge 表示
            // (前 commit の TaskTitleSearchSheet 拡張が effective)。
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
                  type: 'event',  // テンプレートは event 系 = event 検索を利用
                  initialText: _titleCtrl.text,
                );
                if (suggestion == null || !mounted) return;
                setState(() {
                  _titleCtrl.text = suggestion.title;
                  // 候補の category / memo が付いていれば pre-fill。
                  if (suggestion.category.isNotEmpty) {
                    _selectedCategory = suggestion.category;
                  }
                  if (suggestion.memo != null && suggestion.memo!.isNotEmpty) {
                    _memoCtrl.text = suggestion.memo!;
                  }
                  // timeSlot は kTimeSlotPresets の id と一致すれば _selectPreset
                  // で反映 (時刻も同期)。テンプレ発 suggestion の timeSlot が
                  // 'custom' なら preset マッチしないため無視 = 現在の時刻設定維持。
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

            // ── 【FEAT-210】カテゴリ選択 UI（共通コンポーネント化 / 旧 FEAT-208 真実値） ──
            Text(
              AppLocalizations.of(context)!.habitQuickAddCategoryLabel,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 8),
            SabiCategoryChips(
              categories:       kSabiHabitCategories,
              selectedCategory: _selectedCategory,
              onChanged:        (cat) => setState(() => _selectedCategory = cat),
            ),
            // 【2026-07-05】add_event_page と同パターン (「もっと追加する？」)。
            // FEAT-148 のカテゴリ追加リクエスト導線をテンプレート追加画面にも展開し、
            // 予定追加フローとカテゴリ選択の UX を統一する。
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

            // ── 追加ボタン ────────────────────────────────────
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _titleCtrl,
              builder: (_, value, __) {
                final canAdd = value.text.trim().isNotEmpty && !_saving;
                return SizedBox(
                  width: double.infinity,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity:  canAdd ? 1.0 : 0.4,
                    child: ElevatedButton(
                      onPressed: canAdd ? _save : null,
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
                              AppLocalizations.of(context)!.timelineAddTemplatePageSaveButton,
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
      ),
    );
  }
}
