import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../models/timeline_models.dart';

/// FEAT-248: 旧 `timeline_defaults_sheet.dart`（死コード）から切り出した
/// 唯一の生存 widget。`timeline_defaults_page.dart` から使用される。
///
/// 元のシート本体（TimelineDefaultsSheet / AddTemplateSheet / EditTemplateSheet）は
/// FEAT-175 で全画面ページ化された後も物理削除されておらず、本 FEAT で削除した。
/// その際 TemplateRow + 関連 CustomPainter / ヘルパーをここに集約した。
class TemplateRow extends StatefulWidget {
  const TemplateRow({
    super.key,
    required this.template,
    required this.onToggle,
    required this.onLongPress,
  });

  final TimelineTemplate              template;
  final Future<void> Function(bool)   onToggle;   // FEAT-143: val = new enabled state
  final VoidCallback                  onLongPress;

  @override
  State<TemplateRow> createState() => _TemplateRowState();
}

class _TemplateRowState extends State<TemplateRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progressController;
  bool _isLongPressing = false;

  // 【FEAT-203】旧実装はシート表示後 2 秒沈黙 → ヒントバルーン表示 → 4 秒沈黙 → 消去 という
  // `Future.delayed(2s)` + `Future.delayed(4s)` で体感速度を殺す UX だった。
  // Tooltip の長押し起動に置き換え、シート表示直後から操作可能にする。
  // 旧ヒント表示回数の永続化（SharedPreferences の `template_row_hint_count`）も
  // 廃止（Tooltip は SDK 自然挙動で十分、状態管理不要）。

  @override
  void initState() {
    super.initState();
    _progressController = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 500),
    )..addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _progressController.reset();
        if (mounted) setState(() => _isLongPressing = false);
        HapticFeedback.mediumImpact();
        widget.onLongPress();
      }
    });
  }

  @override
  void dispose() {
    _progressController.dispose();
    super.dispose();
  }

  void _onLongPressStart(LongPressStartDetails _) {
    HapticFeedback.selectionClick();
    setState(() {
      _isLongPressing = true;
    });
    _progressController.forward(from: 0);
  }

  void _onLongPressEnd(LongPressEndDetails _) {
    if (_isLongPressing) {
      _progressController.reset();
      setState(() => _isLongPressing = false);
    }
  }

  void _onLongPressCancel() {
    if (_isLongPressing) {
      _progressController.reset();
      setState(() => _isLongPressing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.template;
    final timeLabel =
        '${_fmtHM(t.startHour, t.startMinute)} - '
        '${_fmtHM(t.endHour, t.endMinute)}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      // 【FEAT-203】長押しで Tooltip 表示（旧 Future.delayed(2s/4s) のヒントバルーン撤回）。
      // Tooltip 自体の表示挙動は OS / Material SDK の標準に従う。
      child: Tooltip(
        message:        AppLocalizations.of(context)!.timelineTemplateRowEditHintSabi_message,
        triggerMode:    TooltipTriggerMode.longPress,
        showDuration:   const Duration(seconds: 2),
        waitDuration:   const Duration(milliseconds: 200),
        preferBelow:    false,
        child: GestureDetector(
          onLongPressStart:  _onLongPressStart,
          onLongPressEnd:    _onLongPressEnd,
          onLongPressCancel: _onLongPressCancel,
          child: Stack(
          children: [
            // ── メインカード ──────────────────────────────────
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: t.isEnabled
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: t.isEnabled
                      ? Colors.white.withValues(alpha: 0.12)
                      : Colors.white.withValues(alpha: 0.06),
                ),
              ),
              child: Row(
                children: [
                  // アイコン
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: t.isEnabled
                          ? AppTheme.primary.withValues(alpha: 0.14)
                          : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      kTimelineIconMap[t.iconKey] ?? Icons.event_outlined,
                      size:  18,
                      color: t.isEnabled ? AppTheme.primary : Colors.white24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // タイトル + 時刻
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.title,
                          style: TextStyle(
                            color:      t.isEnabled
                                ? Colors.white
                                : Colors.white38,
                            fontSize:   14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          timeLabel,
                          style: TextStyle(
                            color:    t.isEnabled
                                ? Colors.white38
                                : Colors.white24,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // トグルスイッチ
                  Switch(
                    value:    t.isEnabled,
                    onChanged: (val) async {
                      HapticFeedback.selectionClick();
                      await widget.onToggle(val);    // FEAT-143: await + val を渡す
                    },
                    activeColor:        AppTheme.primary,
                    inactiveThumbColor: Colors.white24,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
                  ),
                ],
              ),
            ),

            // ── ボーダー進捗オーバーレイ ──────────────────────
            if (_isLongPressing)
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _progressController,
                  builder:   (_, __) => CustomPaint(
                    painter: TemplateBorderProgressPainter(
                      progress: _progressController.value,
                      radius:   14,
                    ),
                  ),
                ),
              ),

            // 【FEAT-203】旧ヒントバッジ（`Future.delayed(2s/4s)` で遅延表示）は撤廃。
            // Tooltip の長押し起動が同等の役割を担う（行全体を Tooltip でラップ済み）。
          ],
        ),
        ),  // 【FEAT-203】Tooltip 終了
      ),
    );
  }
}

// ── ボーダー進捗 CustomPainter ─────────────────────────────────────────────────

class TemplateBorderProgressPainter extends CustomPainter {
  const TemplateBorderProgressPainter({
    required this.progress,
    required this.radius,
  });

  final double progress;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final paint = Paint()
      ..color       = AppTheme.primary.withValues(alpha: 0.75)
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap   = StrokeCap.round;

    final rRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(1, 1, size.width - 2, size.height - 2),
      Radius.circular(radius),
    );
    final path   = Path()..addRRect(rRect);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress),
      paint,
    );
  }

  @override
  bool shouldRepaint(TemplateBorderProgressPainter old) =>
      old.progress != progress;
}

// ── 時刻フォーマットヘルパー ───────────────────────────────────────────────────

String _fmtHM(int h, int m) =>
    '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
