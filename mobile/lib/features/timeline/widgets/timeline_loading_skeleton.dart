import 'package:flutter/material.dart';

// ── ローディングスケルトン ────────────────────────────────────────────────────

class TimelineLoadingSkeleton extends StatelessWidget {
  const TimelineLoadingSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        children: List.generate(3, (_) => const SkeletonRow()),
      ),
    );
  }
}

class SkeletonRow extends StatelessWidget {
  const SkeletonRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左レーン
          SizedBox(
            width: 52,
            child: Column(
              children: [
                Container(
                  width: 32, height: 10,
                  decoration: BoxDecoration(
                    color:        Colors.white.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.07),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // カード
          Expanded(
            child: Container(
              height: 62,
              decoration: BoxDecoration(
                color:        Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
