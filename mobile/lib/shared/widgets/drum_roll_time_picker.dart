import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_theme.dart';
import '../../l10n/app_localizations.dart';

// ──────────────────────────────────────────────────────────────────────────────
// showDrumRollTimePicker — ドラム式時刻ピッカーを表示する
//
// showTimePicker() の drop-in replacement として使用できる。
// ・戻り値: 選択した TimeOfDay。キャンセルなら null。
// ・デフォルトは現在時刻。initialTime で初期値を渡せる。
// ──────────────────────────────────────────────────────────────────────────────
Future<TimeOfDay?> showDrumRollTimePicker({
  required BuildContext context,
  TimeOfDay? initialTime,
}) {
  return showModalBottomSheet<TimeOfDay>(
    context:            context,
    backgroundColor:    Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _DrumRollTimePickerSheet(
      initialTime: initialTime ?? TimeOfDay.now(),
    ),
  );
}

// ──────────────────────────────────────────────────────────────────────────────
// _DrumRollTimePickerSheet — ボトムシート本体
// ──────────────────────────────────────────────────────────────────────────────

class _DrumRollTimePickerSheet extends StatefulWidget {
  final TimeOfDay initialTime;
  const _DrumRollTimePickerSheet({required this.initialTime});

  @override
  State<_DrumRollTimePickerSheet> createState() =>
      _DrumRollTimePickerSheetState();
}

class _DrumRollTimePickerSheetState extends State<_DrumRollTimePickerSheet> {
  late int _hour;
  late int _minute;

  // ドラムロール用コントローラー
  late final FixedExtentScrollController _hourCtrl;
  late final FixedExtentScrollController _minuteCtrl;

  static const double _itemExtent   = 44.0;
  static const double _pickerHeight = 200.0;

  @override
  void initState() {
    super.initState();
    _hour   = widget.initialTime.hour;
    _minute = widget.initialTime.minute;
    _hourCtrl   = FixedExtentScrollController(initialItem: _hour);
    _minuteCtrl = FixedExtentScrollController(initialItem: _minute);
  }

  @override
  void dispose() {
    _hourCtrl.dispose();
    _minuteCtrl.dispose();
    super.dispose();
  }

  // ── OK ボタン ──────────────────────────────────────────────────────────────
  void _confirm() {
    Navigator.of(context).pop(TimeOfDay(hour: _hour, minute: _minute));
  }

  // ──────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color:        AppTheme.sheetBackground,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHandle(),
            _buildHeader(),
            _buildDrumRoll(),
          ],
        ),
      ),
    );
  }

  // ── ドラッグハンドル ────────────────────────────────────────────────────────
  Widget _buildHandle() => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Container(
      width: 40, height: 4,
      decoration: BoxDecoration(
        color:        Colors.white24,
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );

  // ── ヘッダー（キャンセル / タイトル / OK） ──────────────────────────────────
  Widget _buildHeader() {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              l10n.commonCancel,
              style: const TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ),
          Expanded(
            child: Text(
              l10n.sharedDrumRollTimePickerTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color:      Colors.white,
                fontSize:   15,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          TextButton(
            onPressed: _confirm,
            child: const Text(
              'OK',
              style: TextStyle(
                color:      AppTheme.primary,
                fontSize:   14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── ドラムロール本体 ─────────────────────────────────────────────────────────
  Widget _buildDrumRoll() {
    return SizedBox(
      height: _pickerHeight,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // ── 選択位置のハイライト帯 ──────────────────────────────────────
          Positioned(
            top:    (_pickerHeight - _itemExtent) / 2,
            left:   40,
            right:  40,
            height: _itemExtent,
            child: Container(
              decoration: BoxDecoration(
                color:        AppTheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.28),
                  width: 1,
                ),
              ),
            ),
          ),

          // ── ドラムロール列（時 : 分） ──────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 時（0〜23、ループ）
              SizedBox(
                width:  88,
                height: _pickerHeight,
                child: CupertinoPicker(
                  scrollController: _hourCtrl,
                  itemExtent:       _itemExtent,
                  looping:          true,
                  // デフォルトの選択 overlay を非表示にして独自ハイライトを使う
                  selectionOverlay: const SizedBox.shrink(),
                  backgroundColor:  Colors.transparent,
                  onSelectedItemChanged: (i) {
                    HapticFeedback.selectionClick();
                    setState(() => _hour = i % 24);
                  },
                  children: List.generate(24, (h) => Center(
                    child: Text(
                      h.toString().padLeft(2, '0'),
                      style: const TextStyle(
                        color:      Colors.white,
                        fontSize:   26,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )),
                ),
              ),

              // コロン区切り
              const Padding(
                padding: EdgeInsets.only(bottom: 2),
                child: Text(
                  ':',
                  style: TextStyle(
                    color:      Colors.white70,
                    fontSize:   30,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),

              // 分（0〜59、ループ）
              SizedBox(
                width:  88,
                height: _pickerHeight,
                child: CupertinoPicker(
                  scrollController: _minuteCtrl,
                  itemExtent:       _itemExtent,
                  looping:          true,
                  selectionOverlay: const SizedBox.shrink(),
                  backgroundColor:  Colors.transparent,
                  onSelectedItemChanged: (i) {
                    HapticFeedback.selectionClick();
                    setState(() => _minute = i % 60);
                  },
                  children: List.generate(60, (m) => Center(
                    child: Text(
                      m.toString().padLeft(2, '0'),
                      style: const TextStyle(
                        color:      Colors.white,
                        fontSize:   26,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )),
                ),
              ),
            ],
          ),

          // ── 上下フェードマスク（選択外の数字をじんわり消す） ──────────────
          IgnorePointer(
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin:  Alignment.topCenter,
                        end:    Alignment.bottomCenter,
                        colors: [
                          AppTheme.sheetBackground,
                          AppTheme.sheetBackground.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: _itemExtent), // 選択帯の高さ分を空ける
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin:  Alignment.bottomCenter,
                        end:    Alignment.topCenter,
                        colors: [
                          AppTheme.sheetBackground,
                          AppTheme.sheetBackground.withValues(alpha: 0),
                        ],
                      ),
                    ),
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
