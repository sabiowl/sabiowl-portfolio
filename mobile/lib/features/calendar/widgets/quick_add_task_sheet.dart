import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/error_formatter.dart';  // 【FEAT-450】生例外リーク防止
import '../../../core/theme/app_theme.dart';
import '../../../core/services/notification_service.dart';
import '../../../l10n/app_localizations.dart';
import '../providers/calendar_provider.dart';
import '../../timeline/providers/timeline_provider.dart';
import '../services/smart_text_parser.dart';
import '../../../shared/widgets/drum_roll_time_picker.dart'; // FEAT-120

/// カレンダー画面のクイック追加ボトムシート（FEAT-33 強化版）。
///
/// スマートパーサー + 属性アイコン（日付・時刻・優先度・カテゴリ）+
/// メモ欄 + 連続追加モード対応。
class QuickAddTaskSheet extends ConsumerStatefulWidget {
  /// シートを閉じた後に invalidate すべき日付文字列（'YYYY-MM-DD'）
  final String? selectedDate;

  const QuickAddTaskSheet({super.key, this.selectedDate});

  @override
  ConsumerState<QuickAddTaskSheet> createState() => _QuickAddTaskSheetState();
}

class _QuickAddTaskSheetState extends ConsumerState<QuickAddTaskSheet> {
  final _controller     = TextEditingController();
  final _memoController = TextEditingController();
  final _focusNode      = FocusNode();
  bool _loading         = false;

  ParsedTask? _preview;

  // ── 手動設定された属性（スマートパーサーより優先） ─────────────────────
  DateTime?  _manualDate;
  TimeOfDay? _manualTime;
  String?    _manualPriority;  // 'high'|'medium'|'low'
  String?    _manualCategory;

  // ── 連続追加モード ────────────────────────────────────────────────────
  bool _continuousMode = false;

  // BUG-59: 優先度・カテゴリのインラインピッカー表示フラグ。
  // showModalBottomSheet を 2 重に開く旧実装は背後にシートが透けて
  // 「空白の画面が重なっている」体感だったため、シート内にトグル展開する方式に変更。
  bool _priorityPickerOpen = false;
  bool _categoryPickerOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _focusNode.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _memoController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged(String text) {
    if (text.trim().isEmpty) {
      setState(() => _preview = null);
      return;
    }
    setState(() => _preview = SmartTextParser.parse(text));
  }

  // ── 手動設定 + スマートパーサーのマージ ─────────────────────────────────
  ParsedTask get _effectiveParsed {
    final base = _preview ??
        ParsedTask(
          name:     _controller.text.trim(),
          date:     null,
          priority: 'medium',
          time:     null,
        );
    return ParsedTask(
      name:     base.name,
      date:     _manualDate    ?? base.date,
      priority: _manualPriority ?? base.priority,
      time:     _manualTime    ?? base.time,
    );
  }

  // ── カテゴリラベル → タイムライン category キー ──────────────────────────
  // 【FEAT-288】Backend CATEGORY_CHOICES（11 値）真実値に統一。
  // 旧 '作業' / 'メンタル' / '交流' は migration 0066 で死語化済 → '仕事' / '精神' / '社交'
  static String _categoryKey(String? label) => switch (label) {
    '運動'  => 'habit',
    '健康'  => 'health',
    '仕事'  => 'work',
    '精神'  => 'rest',
    '社交'  => 'social',
    _       => 'other',
  };

  // ── カテゴリラベル → タイムライン icon_key ──────────────────────────────
  static String _iconKey(String? label) => switch (label) {
    '運動'  => 'directions_run',
    '健康'  => 'self_improvement',
    '仕事'  => 'work',
    '精神'  => 'self_improvement',
    '社交'  => 'groups',
    _       => 'event',
  };

  // ── 送信 ──────────────────────────────────────────────────────────────
  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() => _loading = true);
    try {
      final parsed = _effectiveParsed;

      // date（選択日優先 → スマートパーサー → 今日）
      final targetDate = parsed.date
          ?? (widget.selectedDate != null
              ? DateTime.tryParse(widget.selectedDate!)
              : null)
          ?? DateTime.now();
      final dateStr = '${targetDate.year.toString().padLeft(4, '0')}'
          '-${targetDate.month.toString().padLeft(2, '0')}'
          '-${targetDate.day.toString().padLeft(2, '0')}';

      // start_time / end_time（時刻があれば HH:MM:00 形式で送信）
      String? startTimeStr;
      if (parsed.time != null) {
        startTimeStr =
            '${parsed.time!.hour.toString().padLeft(2, '0')}'
            ':${parsed.time!.minute.toString().padLeft(2, '0')}:00';
      }

      // タイムラインイベントとして作成
      final created = await ref.read(timelineServiceProvider).createEvent({
        'title':      parsed.name,
        'date':       dateStr,
        if (startTimeStr != null) 'start_time': startTimeStr,
        'category':   _categoryKey(_manualCategory),
        'icon_key':   _iconKey(_manualCategory),
        'memo':       _memoController.text.trim(),
      });

      // リマインダー通知（時刻が指定されているとき）
      if (parsed.time != null) {
        final scheduledAt = DateTime(
          targetDate.year,
          targetDate.month,
          targetDate.day,
          parsed.time!.hour,
          parsed.time!.minute,
        );
        await NotificationService.scheduleTaskNotification(
          id:          created.id,
          title:       parsed.name,
          scheduledAt: scheduledAt,
        );
      }

      // 【FEAT-220】Calendar provider 統合: bootstrap + timelineEvents (family 全体) に統一
      ref.invalidate(calendarBootstrapProvider);
      ref.invalidate(timelineEventsProvider);

      if (_continuousMode) {
        // 連続追加: フィールドをリセットして入力継続
        _controller.clear();
        _memoController.clear();
        setState(() {
          _preview        = null;
          _manualDate     = null;
          _manualTime     = null;
          _manualPriority = null;
          _manualCategory = null;
        });
        _focusNode.requestFocus();
      } else {
        if (mounted) Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        // 【FEAT-450 (2026-06-20)】生 DioException 露出を formatApiError で
        // サビ口調 fallback に置換 (codebase_review 20260620 §2-1-A の指摘解消)。
        // 既存 profile_edit_page / friend_profile_page の FEAT-407 パターン踏襲。
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            content:  Text(formatApiError(e)),
            behavior: SnackBarBehavior.floating,
          ));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── 日付ピッカー ──────────────────────────────────────────────────────
  Future<void> _pickDate() async {
    final now     = DateTime.now();
    final initial = _manualDate ?? _preview?.date ?? now;
    final picked  = await showDatePicker(
      context:     context,
      initialDate: initial,
      firstDate:   DateTime(now.year, now.month, now.day),
      lastDate:    DateTime(now.year + 2),
      builder: (ctx, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(primary: AppTheme.primary),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _manualDate = picked);
  }

  // ── 時刻ピッカー ──────────────────────────────────────────────────────
  Future<void> _pickTime() async {
    final initial = _manualTime ?? _preview?.time ?? TimeOfDay.now();
    // FEAT-120: showTimePicker → showDrumRollTimePicker に変更
    final picked = await showDrumRollTimePicker(
      context:     context,
      initialTime: initial,
    );
    if (picked != null) setState(() => _manualTime = picked);
  }

  // ── 優先度ピッカー ────────────────────────────────────────────────────
  // BUG-59: ネスト showModalBottomSheet を廃止し、シート内インライントグル表示に変更。
  void _pickPriority() {
    setState(() {
      _priorityPickerOpen = !_priorityPickerOpen;
      _categoryPickerOpen = false; // カテゴリが開いていれば閉じる（排他）
    });
  }

  // ── カテゴリピッカー ──────────────────────────────────────────────────
  // BUG-59: ネスト showModalBottomSheet を廃止し、シート内インライントグル表示に変更。
  void _pickCategory() {
    setState(() {
      _categoryPickerOpen = !_categoryPickerOpen;
      _priorityPickerOpen = false; // 優先度が開いていれば閉じる（排他）
    });
  }

  // ── ヘルパー ──────────────────────────────────────────────────────────
  String _formatDate(DateTime d, AppLocalizations l10n) {
    final today    = DateTime.now();
    final todayDay = DateTime(today.year, today.month, today.day);
    final diff     = d.difference(todayDay).inDays;
    if (diff == 0) return l10n.calendarQuickAddDateToday;
    if (diff == 1) return l10n.calendarQuickAddDateTomorrow;
    if (diff == 2) return l10n.calendarQuickAddDateDayAfterTomorrow;
    return '${d.month}/${d.day}';
  }

  String _priorityLabel(String p, AppLocalizations l10n) {
    return switch (p) {
      'high' => l10n.calendarQuickAddPriorityHigh,
      'low'  => l10n.calendarQuickAddPriorityLow,
      _      => l10n.calendarQuickAddPriorityMedium,
    };
  }

  Color _priorityColor(String p) {
    return switch (p) {
      'high' => Colors.redAccent,
      'low'  => Colors.lightBlueAccent,
      _      => Colors.orange,
    };
  }

  // ── ビルド ────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final l10n       = AppLocalizations.of(context)!;
    final eff        = _effectiveParsed;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    // FEAT-150: ステータスバー高さを考慮した maxHeight でキーボード表示時もはみ出さない
    final screenH    = MediaQuery.of(context).size.height;
    final statusH    = MediaQuery.of(context).padding.top;

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      // FEAT-150: 90% 固定 → ステータスバー下 8dp の余白を確保した可変値に変更
      constraints: BoxConstraints(maxHeight: screenH - statusH - 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [

          // ① ドラッグハンドル（固定・スクロール外）
          // FEAT-150: SingleChildScrollView の外に移動し、常に表示・操作可能にする
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color:        Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),

          // ② スクロール可能なコンテンツ領域
          // FEAT-150: Flexible + SingleChildScrollView でコンテンツが多い場合のみスクロール
          Flexible(
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Column(
                mainAxisSize:       MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  // ── タイトル入力 ──────────────────────────────────────────
                  TextField(
                    controller:      _controller,
                    focusNode:       _focusNode,
                    onChanged:       _onTextChanged,
                    onSubmitted:     (_) => _focusNode.nextFocus(),
                    textInputAction: TextInputAction.next,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    decoration: InputDecoration(
                      hintText:  l10n.calendarQuickAddHintText,
                      hintStyle: TextStyle(
                        color:    Colors.white.withValues(alpha: 0.28),
                        fontSize: 14,
                      ),
                      filled:    true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:   BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ── メモ入力（第 2 層） ───────────────────────────────────
                  TextField(
                    controller:      _memoController,
                    textInputAction: TextInputAction.done,
                    onSubmitted:     (_) => _submit(),
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    minLines: 1,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText:  l10n.calendarQuickAddMemoHint,
                      hintStyle: TextStyle(
                        color:    Colors.white.withValues(alpha: 0.22),
                        fontSize: 13,
                      ),
                      filled:    true,
                      fillColor: Colors.white.withValues(alpha: 0.03),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide:   BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── 属性アイコン行 ────────────────────────────────────────
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        // 📅 日付
                        _AttrButton(
                          icon:  Icons.calendar_today_outlined,
                          label: eff.date != null ? _formatDate(eff.date!, l10n) : l10n.calendarQuickAddDateLabel,
                          active: _manualDate != null || eff.date != null,
                          color:  AppTheme.secondary,
                          onTap:  _pickDate,
                        ),
                        const SizedBox(width: 8),
                        // ⏰ 時刻
                        _AttrButton(
                          icon: Icons.access_time_outlined,
                          label: eff.time != null
                              ? '${eff.time!.hour.toString().padLeft(2, '0')}:${eff.time!.minute.toString().padLeft(2, '0')}'
                              : l10n.calendarQuickAddTimeLabel,
                          active: _manualTime != null || eff.time != null,
                          color:  AppTheme.secondary,
                          onTap:  _pickTime,
                        ),
                        const SizedBox(width: 8),
                        // 🚩 優先度
                        _AttrButton(
                          icon:   Icons.flag_outlined,
                          label:  _priorityLabel(eff.priority, l10n),
                          active: _manualPriority != null || _priorityPickerOpen,
                          color:  _priorityColor(eff.priority),
                          onTap:  _pickPriority,     // BUG-59: context 不要・トグル
                        ),
                        const SizedBox(width: 8),
                        // 📁 カテゴリ
                        _AttrButton(
                          icon:   Icons.folder_outlined,
                          label:  _manualCategory ?? l10n.calendarQuickAddCategoryLabel,
                          active: _manualCategory != null || _categoryPickerOpen,
                          color:  Colors.white54,
                          onTap:  _pickCategory,     // BUG-59: context 不要・トグル
                        ),
                      ],
                    ),
                  ),

                  // BUG-59: インライン優先度ピッカー（_priorityPickerOpen = true のとき表示）
                  if (_priorityPickerOpen) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                      decoration: BoxDecoration(
                        color:        Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(12),
                        border:       Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        children: [
                          ('high',   l10n.calendarQuickAddPriorityHigh,   Colors.redAccent),
                          ('medium', l10n.calendarQuickAddPriorityMedium, Colors.orange),
                          ('low',    l10n.calendarQuickAddPriorityLow,    Colors.lightBlueAccent),
                        ].map((p) {
                          final key   = p.$1;
                          final label = p.$2;
                          final color = p.$3;
                          final isSelected =
                              (_manualPriority ?? _preview?.priority) == key;
                          return Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() {
                                _manualPriority     = key;
                                _priorityPickerOpen = false;
                              }),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                margin:   const EdgeInsets.symmetric(horizontal: 4),
                                padding:  const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? color.withValues(alpha: 0.20)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: isSelected
                                        ? color.withValues(alpha: 0.6)
                                        : Colors.white12,
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    Icon(Icons.flag, color: color, size: 18),
                                    const SizedBox(height: 4),
                                    Text(label,
                                        style: TextStyle(color: color, fontSize: 13)),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],

                  // BUG-59: インラインカテゴリピッカー（_categoryPickerOpen = true のとき表示）
                  if (_categoryPickerOpen) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color:        Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(12),
                        border:       Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize:       MainAxisSize.min,
                        children: [
                          Text(l10n.calendarQuickAddCategoryLabel,
                              style: const TextStyle(color: Colors.white54, fontSize: 12)),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing:    8,
                            runSpacing: 8,
                            children: [
                              ('その他', Icons.category_outlined),
                              ('運動',   Icons.directions_run),
                              ('健康',   Icons.favorite_border),
                              ('学習',   Icons.menu_book_outlined),
                              ('仕事',   Icons.work_outline),
                              ('精神',   Icons.self_improvement),
                              ('社交',   Icons.people_outline),
                            ].map((c) {
                              final name       = c.$1;
                              final icon       = c.$2;
                              final isSelected = _manualCategory == name;
                              return GestureDetector(
                                onTap: () => setState(() {
                                  _manualCategory     = name;
                                  _categoryPickerOpen = false;
                                }),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  padding:  const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? AppTheme.primary.withValues(alpha: 0.20)
                                        : Colors.white.withValues(alpha: 0.05),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: isSelected
                                          ? AppTheme.primary.withValues(alpha: 0.6)
                                          : Colors.white12,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(icon,
                                          size:  14,
                                          color: isSelected
                                              ? AppTheme.primary
                                              : Colors.white54),
                                      const SizedBox(width: 6),
                                      Text(name,
                                          style: TextStyle(
                                            color: isSelected
                                                ? AppTheme.primary
                                                : Colors.white54,
                                            fontSize: 13,
                                          )),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),
                  ],

                ],
              ),
            ),
          ),

          // ③ 連続追加 + 追加ボタン行（固定・スクロール外）
          // FEAT-150: 常に見えるよう SingleChildScrollView の外に移動
          //           bottom padding を viewInsets + 20 に変更
          Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + viewInsets),
            child: Row(
              children: [
                // 連続追加トグル
                GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _continuousMode = !_continuousMode);
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 18, height: 18,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _continuousMode
                              ? AppTheme.primary.withValues(alpha: 0.20)
                              : Colors.transparent,
                          border: Border.all(
                            color: _continuousMode
                                ? AppTheme.primary
                                : Colors.white24,
                            width: 1.5,
                          ),
                        ),
                        child: _continuousMode
                            ? const Icon(Icons.check,
                                size: 11, color: AppTheme.primary)
                            : null,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        l10n.calendarQuickAddContinuous,
                        style: TextStyle(
                          color: _continuousMode
                              ? AppTheme.primary
                              : Colors.white38,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                // 追加ボタン
                SizedBox(
                  width: 100,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      padding:         const EdgeInsets.symmetric(vertical: 12),
                      backgroundColor: AppTheme.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _loading
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : Text(l10n.calendarQuickAddSubmitButton,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),

        ],
      ),
    );
  }
}

/// 属性アイコンボタン（日付・時刻・優先度・カテゴリ用）
class _AttrButton extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final bool         active;
  final Color        color;
  final VoidCallback onTap;

  const _AttrButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? color.withValues(alpha: 0.14)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active
                ? color.withValues(alpha: 0.45)
                : Colors.white12,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13,
                color: active ? color : Colors.white38),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                  fontSize: 12,
                  color: active ? color : Colors.white38,
                )),
          ],
        ),
      ),
    );
  }
}
