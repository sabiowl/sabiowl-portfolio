import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../models/challenge.dart';

/// 【FEAT-466 (2026-06-24)】3 段階 (Bronze/Silver/Gold) の達成状況バッジ。
///
/// メダル絵文字 (🥉🥈🥇) + 文字 fallback (B/S/G) を併用する
/// (Pre-mortem S5: 古い端末でのメダル絵文字 tofu 化対策)。
enum TierType { bronze, silver, gold }

class TierBadge extends StatelessWidget {
  const TierBadge({
    super.key,
    required this.tierType,
    required this.label,
    required this.tier,
  });

  final TierType tierType;
  final String label;
  final TierInfo tier;

  static const Map<TierType, String> _medal = {
    TierType.bronze: '🥉',
    TierType.silver: '🥈',
    TierType.gold: '🥇',
  };
  static const Map<TierType, String> _letter = {
    TierType.bronze: 'B',
    TierType.silver: 'S',
    TierType.gold: 'G',
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final achieved = tier.achieved;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(
            '${_medal[tierType]} $label ${_letter[tierType]}',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(width: 6),
          Text(
            l10n.challengeCardCountLabel(tier.target),
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const Spacer(),
          Text(
            achieved
                ? l10n.challengeTierAchievedLabel
                : l10n.challengeTierRemainingLabel(tier.remainingCount),
            style: TextStyle(
              color: achieved ? AppTheme.success : Colors.white70,
              fontSize: 12,
              fontWeight: achieved ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}
