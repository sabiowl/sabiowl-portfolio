import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../models/challenge.dart';

/// 【FEAT-466 (2026-06-24)】チャレンジ詳細ポップアップ (R2)。
///
/// 全段階達成状況 + 報酬 + 残り日数 + 配布タイミング + 1 日 1 回ガード説明を
/// まとめて確認できる。単一「閉じる」ボタンのみ (BUG-138 例外: 単一ボタン
/// 情報ダイアログ)。dialog 内で他画面への navigation は一切行わない
/// (BUG-65 再発防止、Pre-mortem S7)。
class ChallengeDetailDialog extends StatelessWidget {
  const ChallengeDetailDialog({super.key, required this.challenge});

  final ChallengeEntry challenge;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      backgroundColor: AppTheme.card,
      title: Text(challenge.title, style: const TextStyle(color: Colors.white)),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _sectionTitle(l10n.challengeDetailDescriptionTitle),
            Text(challenge.description, style: _bodyStyle),
            const SizedBox(height: 14),
            _sectionTitle(challenge.isTiered
                ? l10n.challengeDetailTieredSectionTitle
                : l10n.challengeDetailSimpleSectionTitle),
            if (challenge.isTiered) ...[
              if (challenge.bronze != null) _tierLine(l10n, l10n.challengeDetailTierBronzeLabel, challenge.bronze!),
              if (challenge.silver != null) _tierLine(l10n, l10n.challengeDetailTierSilverLabel, challenge.silver!),
              if (challenge.gold != null) _tierLine(l10n, l10n.challengeDetailTierGoldLabel, challenge.gold!),
            ] else if (challenge.gold != null)
              _tierLine(l10n, l10n.challengeDetailTierGoldLabel, challenge.gold!),
            const SizedBox(height: 14),
            Text(l10n.challengeDetailMyContributionLabel(challenge.myContributionCount), style: _bodyStyle),
            const SizedBox(height: 6),
            Text(
              l10n.challengeDetailPeriodLabel(
                challenge.startDate,
                challenge.endDate,
                challenge.remainingDays,
              ),
              style: _bodyStyle,
            ),
            const SizedBox(height: 14),
            _sectionTitle(l10n.challengeDetailRewardTitle),
            if (challenge.isTiered)
              Text(l10n.challengeDetailRewardTieredNote, style: _bodyStyle),
            Text(l10n.challengeDetailRewardDistributionNote, style: _bodyStyle),
            Text(l10n.challengeDetailRewardCountLimitNote, style: _bodyStyle),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose, style: const TextStyle(color: Colors.white70)),
        ),
      ],
    );
  }

  static const TextStyle _bodyStyle = TextStyle(color: Colors.white70, fontSize: 13, height: 1.5);

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
        ),
      );

  Widget _tierLine(AppLocalizations l10n, String label, TierInfo tier) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.challengeDetailTierRow(
                label,
                l10n.challengeCardCountLabel(tier.target),
                tier.rewardExp,
              ),
              style: _bodyStyle,
            ),
          ),
          Text(
            tier.achieved
                ? l10n.challengeTierAchievedLabel
                : l10n.challengeTierRemainingLabel(tier.remainingCount),
            style: TextStyle(
              color: tier.achieved ? AppTheme.success : Colors.white54,
              fontSize: 12,
              fontWeight: tier.achieved ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}
