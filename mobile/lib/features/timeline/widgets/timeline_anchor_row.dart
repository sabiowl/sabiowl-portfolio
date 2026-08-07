import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';

// ── デフォルト起床・就寝アンカー時刻 ─────────────────────────────────────────
/// 将来的に Settings 画面から shared_preferences で変更可能にすることを想定。
const kWakeTime  = TimeOfDay(hour:  7, minute: 0);
const kSleepTime = TimeOfDay(hour: 23, minute: 0);

// ── 起床・就寝アンカー行 ──────────────────────────────────────────────────────

/// タイムラインの「始まり」と「終わり」を示す固定マーカー行。
/// 水平ライン + 絵文字 + ラベルのシンプルな区切りデザイン。
class TimelineAnchorRow extends StatelessWidget {
  const TimelineAnchorRow({
    super.key,
    required this.time,
    required this.emoji,
    required this.label,
  });

  final TimeOfDay time;
  final String    emoji;
  final String    label;

  static TimelineAnchorRow wake(BuildContext context) => TimelineAnchorRow(
    time:  kWakeTime,
    emoji: '🌅',
    label: AppLocalizations.of(context)!.timelineAnchorRowWakeLabel,
  );

  static TimelineAnchorRow sleep(BuildContext context) => TimelineAnchorRow(
    time:  kSleepTime,
    emoji: '🌙',
    label: AppLocalizations.of(context)!.timelineAnchorRowSleepLabel,
  );

  @override
  Widget build(BuildContext context) {
    final timeLabel =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          // 左レーン（イベントカードと同一幅: 52px）
          SizedBox(
            width: 52,
            child: Text(
              timeLabel,
              style: const TextStyle(
                color:      Colors.white24,
                fontSize:   10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 水平ライン + 絵文字 + ラベル
          Expanded(
            child: Row(
              children: [
                Container(
                  width:  16,
                  height: 1,
                  color:  Colors.white.withValues(alpha: 0.10),
                ),
                const SizedBox(width: 6),
                Text(emoji, style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: const TextStyle(
                    color:         Colors.white24,
                    fontSize:      11,
                    fontWeight:    FontWeight.w500,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Container(
                    height: 1,
                    color:  Colors.white.withValues(alpha: 0.10),
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

// ── 現在時刻インジケーター ────────────────────────────────────────────────────

class CurrentTimeIndicator extends StatelessWidget {
  const CurrentTimeIndicator({super.key, required this.time});
  final TimeOfDay time;

  @override
  Widget build(BuildContext context) {
    final label =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          // 時刻ラベル（左レーン幅に合わせる）
          SizedBox(
            width: 52,
            child: Text(
              label,
              style: const TextStyle(
                color:      Colors.redAccent,
                fontSize:   10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // インジケーターライン
          Expanded(
            child: Container(
              height: 1.5,
              color:  Colors.redAccent.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(width: 4),
          // ドット
          Container(
            width:  8,
            height: 8,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.redAccent,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}
