// 【FEAT-512 (2026-07-30)】チャレンジ inline チュートリアル。
// 案 Y: data-driven trigger (active.every((c) => c.myContributionCount == 0)) で表示。
// アクティブチャレンジが存在するが未参加のユーザーへの初回 onboarding。
// PostHog: tutorial_shown {feature: 'challenge'} を initState で 1 回送信。
import 'package:flutter/material.dart';

import '../../../core/analytics/posthog_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_flow_diagram.dart';

class SabiChallengeOnboardingFlow extends StatefulWidget {
  const SabiChallengeOnboardingFlow({super.key});

  @override
  State<SabiChallengeOnboardingFlow> createState() =>
      _SabiChallengeOnboardingFlowState();
}

class _SabiChallengeOnboardingFlowState
    extends State<SabiChallengeOnboardingFlow> {
  @override
  void initState() {
    super.initState();
    PosthogService.instance.capture(
      'tutorial_shown',
      properties: {'feature': 'challenge'},
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        children: [
          // ── Flow 図 (3 段階 Bronze → Silver → Gold) ────────────
          SabiFlowBox(icon: '🎯', label: l10n.challengeOnboardingStep1Label),
          const SabiFlowArrow(),
          SabiFlowBox(icon: '📅', label: l10n.challengeOnboardingStep2Label),
          const SabiFlowArrow(),
          // 3 分岐 (Bronze / Silver / Gold)
          SizedBox(
            height: 32,
            width: double.infinity,
            child: CustomPaint(
              size: const Size(240, 32),
              painter: const SabiFlowBranchPainter(),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              SabiFlowLeaf(icon: '🥉', label: l10n.challengeCardTierBronze),
              SabiFlowLeaf(icon: '🥈', label: l10n.challengeCardTierSilver),
              SabiFlowLeaf(icon: '🥇', label: l10n.challengeCardTierGold),
            ],
          ),
          const SizedBox(height: 20),
          // ── サビ口調メッセージ ─────────────────────────────────
          Text(
            l10n.challengeOnboardingBodySabi_message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.70),
              fontSize: 13,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.challengeOnboardingSubcaption,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 16),
          // ── セパレータ ────────────────────────────────────────
          Divider(color: AppTheme.primary.withValues(alpha: 0.15)),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
