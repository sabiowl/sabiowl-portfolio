import 'package:flutter/material.dart';

// ── 時刻ピッカーボタン ──────────────────────────────────────────────────────────

class TimePicker extends StatelessWidget {
  const TimePicker({
    super.key,
    required this.label,
    required this.timeText,
    required this.onTap,
    this.isPlaceholder = false,
    this.onClear,
  });

  final String        label;
  final String        timeText;
  final VoidCallback  onTap;
  final bool          isPlaceholder;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color:        Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.access_time, size: 14, color: Colors.white54),
                const SizedBox(width: 6),
                Text(
                  timeText,
                  style: TextStyle(
                    color:      isPlaceholder ? Colors.white24 : Colors.white,
                    fontSize:   15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (onClear != null) ...[
                  const Spacer(),
                  GestureDetector(
                    onTap: onClear,
                    child: const Icon(
                      Icons.cancel_outlined,
                      size:  14,
                      color: Colors.white24,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
