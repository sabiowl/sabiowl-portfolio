import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../l10n/app_localizations.dart';
import '../models/timeline_models.dart';
import './timeline_anchor_row.dart';
import './timeline_event_card.dart';

// ── タイムライン本体 ─────────────────────────────────────────────────────────

/// 選択日のイベントを縦に並べる。
///
/// 今日の場合、現在時刻インジケーターを適切な位置に挿入する。
/// 末尾に「予定を追加」行を配置する。
class TimelineBody extends StatelessWidget {
  const TimelineBody({
    super.key,
    required this.events,
    required this.now,
    required this.selectedDate,
    required this.onAdd,
    required this.onEventLongPress,
  });

  final List<TimelineEvent>          events;
  /// 【FEAT-227】`DateTime` → `ValueListenable&lt;DateTime&gt;` に変更。
  /// 親（TimelineDashboard）の毎分 setState を廃止し、現在時刻に依存する
  /// 本ウィジェット内部のみ再描画するため。`flutter/foundation.dart` を明示 import。
  final ValueListenable<DateTime>    now;
  final DateTime                     selectedDate;
  final VoidCallback                 onAdd;
  final void Function(TimelineEvent) onEventLongPress;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DateTime>(
      valueListenable: now,
      builder: (context, currentTime, _) {
        final isToday = selectedDate.year  == currentTime.year  &&
                        selectedDate.month == currentTime.month &&
                        selectedDate.day   == currentTime.day;

        final nowTime = isToday ? TimeOfDay.fromDateTime(currentTime) : null;
        final nowMin  = nowTime != null
            ? nowTime.hour * 60 + nowTime.minute
            : -1;

        final children      = <Widget>[];
        bool indicatorDone  = false;

        for (int i = 0; i < events.length; i++) {
          final event    = events[i];
          final st       = event.startTime;
          final eventMin = st != null ? st.hour * 60 + st.minute : 0;

          // 現在時刻インジケーターをイベントの直前に挿入
          if (!indicatorDone && nowMin >= 0 && nowMin < eventMin) {
            children.add(CurrentTimeIndicator(time: nowTime!));
            indicatorDone = true;
          }

          children.add(
            TimelineEventCard(
              event:       event,
              isLast:      i == events.length - 1,
              onLongPress: () => onEventLongPress(event),
            ),
          );
        }

        // 全イベントより後に現在時刻がある場合（一番下に追加）
        if (!indicatorDone && nowMin >= 0) {
          children.add(CurrentTimeIndicator(time: nowTime!));
        }

        // 末尾に「予定を追加」行
        children.add(AddEventRow(onAdd: onAdd));

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        );
      },
    );
  }
}

// ── タイムラインスタイル追加行 ────────────────────────────────────────────────

class AddEventRow extends StatelessWidget {
  const AddEventRow({super.key, required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onAdd();
        },
        borderRadius:   BorderRadius.circular(14),
        splashColor:    Colors.white.withValues(alpha: 0.04),
        highlightColor: Colors.white.withValues(alpha: 0.02),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // ── 左レーン（イベントカードと幅を揃える）──────────────
            SizedBox(
              width: 52,
              child: Center(
                child: Container(
                  width:  10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape:  BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.18),
                      width: 1.5,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // ── 右: 点線風カード ──────────────────────────────────
            Expanded(
              child: DashedBorderCard(
                child: Row(
                  children: [
                    Icon(
                      Icons.add_circle_outline,
                      size:  16,
                      color: Colors.white.withValues(alpha: 0.25),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      AppLocalizations.of(context)!.timelineAddEventLabel,
                      style: TextStyle(
                        color:      Colors.white.withValues(alpha: 0.28),
                        fontSize:   13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 点線ボーダーのカード（CustomPainter で破線を描画）
class DashedBorderCard extends StatelessWidget {
  const DashedBorderCard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: DashedRectPainter(
        color:  Colors.white.withValues(alpha: 0.14),
        radius: 14,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: child,
      ),
    );
  }
}

class DashedRectPainter extends CustomPainter {
  const DashedRectPainter({required this.color, required this.radius});
  final Color  color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color       = color
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    const dashLen = 5.0;
    const gapLen  = 4.0;
    final rRect   = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(radius),
    );
    final path  = Path()..addRRect(rRect);
    final metro = path.computeMetrics().first;
    double dist = 0;
    while (dist < metro.length) {
      final end = (dist + dashLen).clamp(0.0, metro.length);
      canvas.drawPath(metro.extractPath(dist, end), paint);
      dist += dashLen + gapLen;
    }
  }

  @override
  bool shouldRepaint(DashedRectPainter old) =>
      old.color != color || old.radius != radius;
}
