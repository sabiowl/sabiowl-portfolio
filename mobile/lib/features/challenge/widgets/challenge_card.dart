import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../models/challenge.dart';
import 'challenge_detail_dialog.dart';
import 'tier_badge.dart';

/// 【FEAT-465→FEAT-466 (2026-06-24)】チャレンジ 1 件のカード表示。
///
/// 全体進捗 (簡素表示) + 3 段階バッジ (is_tiered=true) または単一表示
/// (is_tiered=false、Pre-mortem S6) + 右上の詳細アイコン (R2)。
class ChallengeCard extends StatelessWidget {
  const ChallengeCard({super.key, required this.challenge});

  final ChallengeEntry challenge;

  static const Map<String, String> _categoryEmoji = {
    '運動': '🏃',
    '学習': '📚',
    '仕事': '💼',
    '体力': '💪',
    '美容': '💄',
    '健康': '❤️',
    '精神': '🧘',
    '創造': '🎨',
    '社交': '🤝',
    '休息': '🌙',
    'その他': '✨',
  };

  bool get _achievedAny =>
      challenge.tiers.values.any((t) => t.achieved);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final emoji = _categoryEmoji[challenge.category] ?? '✨';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _achievedAny
              ? AppTheme.success.withValues(alpha: 0.5)
              : AppTheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  challenge.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
              // 【R2】詳細アイコン (右上)。BUG-138 適用外 (navigation 一切なし、
              // 単一「閉じる」のみの情報ダイアログ)。
              IconButton(
                icon: const Icon(Icons.info_outline, color: Colors.white54, size: 20),
                tooltip: l10n.challengeCardDetailTooltip,
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => ChallengeDetailDialog(challenge: challenge),
                ),
              ),
            ],
          ),
          Text(
            challenge.description,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (challenge.progressRate / 100).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: Colors.white.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(
                _achievedAny ? AppTheme.success : AppTheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.challengeCardCountLabel(challenge.currentCount),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.challengeCardContributionLabel(
              challenge.myContributionCount,
              challenge.remainingDays,
            ),
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          // 【gameplay_review 20260803 要素 C-3】集合カウンタは「自分の積み上げが
          // 誰かの数字になる」を **メカニクスとして既に実装している**唯一の場所なのに、
          // 提示が数字だけで利己的利他の理念が言語化されていなかった。
          // 6 軸ステータスに入れた物語行と同じ処方をここにも当てる。
          // 貢献 0 のときは出さない (「まだ何もしていない」を強調しない)。
          if (challenge.myContributionCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              l10n.challengeCardContributionSabi_message(
                challenge.myContributionCount,
              ),
              style: TextStyle(
                color: AppTheme.primary.withValues(alpha: 0.85),
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          const SizedBox(height: 10),
          const Divider(color: Colors.white12, height: 1),
          const SizedBox(height: 6),
          if (challenge.isTiered) ...[
            if (challenge.bronze != null)
              TierBadge(tierType: TierType.bronze, label: l10n.challengeCardTierBronze, tier: challenge.bronze!),
            if (challenge.silver != null)
              TierBadge(tierType: TierType.silver, label: l10n.challengeCardTierSilver, tier: challenge.silver!),
            if (challenge.gold != null)
              TierBadge(tierType: TierType.gold, label: l10n.challengeCardTierGold, tier: challenge.gold!),
          ] else if (challenge.gold != null)
            TierBadge(tierType: TierType.gold, label: l10n.challengeCardTierTarget, tier: challenge.gold!),
        ],
      ),
    );
  }
}
