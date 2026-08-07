// 【FEAT-512 (2026-07-30)】ステータス inline チュートリアル。
// 案 Y: data-driven trigger (player.level == 1) で表示。
// 初回ユーザーへの 6 ステータス育成方法の説明。
// PostHog: tutorial_shown {feature: 'stats'} を initState で 1 回送信。
import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';

import '../../../core/analytics/posthog_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/sabi_flow_diagram.dart';

class SabiStatsOnboardingFlow extends StatefulWidget {
  const SabiStatsOnboardingFlow({super.key});

  @override
  State<SabiStatsOnboardingFlow> createState() =>
      _SabiStatsOnboardingFlowState();
}

class _SabiStatsOnboardingFlowState extends State<SabiStatsOnboardingFlow> {
  @override
  void initState() {
    super.initState();
    PosthogService.instance.capture(
      'tutorial_shown',
      properties: {'feature': 'stats'},
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: AppTheme.card.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.20),
        ),
      ),
      child: Column(
        children: [
          Text(
            l10n.gamifStatsOnboardingTitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.90),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          // ── Flow 図 ─────────────────────────────────────────────
          SabiFlowBox(icon: '🌱', label: l10n.gamifStatsOnboardingStep1),
          const SabiFlowArrow(),
          SabiFlowBox(icon: '📈', label: l10n.gamifStatsOnboardingStep2),
          const SabiFlowArrow(),
          // 3 分岐 (stat 例)
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
              SabiFlowLeaf(icon: '💪', label: l10n.gamifStatsOnboardingStatExercise),
              SabiFlowLeaf(icon: '📚', label: l10n.gamifStatsOnboardingStatStudy),
              SabiFlowLeaf(icon: '🧘', label: l10n.gamifStatsOnboardingStatMental),
            ],
          ),
          const SizedBox(height: 20),
          // ── サビ口調メッセージ ─────────────────────────────────
          Text(
            l10n.gamifStatsOnboardingSabi_message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.70),
              fontSize: 13,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}
