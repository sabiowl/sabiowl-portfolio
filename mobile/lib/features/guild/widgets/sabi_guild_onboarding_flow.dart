// 【FEAT-512 (2026-07-30)】ギルド inline 空状態チュートリアル。
// 案 Y: data-driven trigger (recentBattlesProvider(10).isEmpty) で自動表示。
// リリアがナレーターとして登場 (ギルド画面専任 NPC)。
// PostHog: tutorial_shown {feature: 'guild'} を initState で 1 回送信。
import 'package:flutter/material.dart';

import '../../../core/analytics/posthog_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_flow_diagram.dart';

class SabiGuildOnboardingFlow extends StatefulWidget {
  const SabiGuildOnboardingFlow({super.key});

  @override
  State<SabiGuildOnboardingFlow> createState() =>
      _SabiGuildOnboardingFlowState();
}

class _SabiGuildOnboardingFlowState extends State<SabiGuildOnboardingFlow> {
  @override
  void initState() {
    super.initState();
    PosthogService.instance.capture(
      'tutorial_shown',
      properties: {'feature': 'guild'},
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 12),
          // ── Flow 図 ─────────────────────────────────────────────
          SabiFlowBox(icon: '⚔️', label: l10n.guildOnboardingStep1),
          const SabiFlowArrow(),
          SabiFlowBox(icon: '🗡️', label: l10n.guildOnboardingStep2),
          const SabiFlowArrow(),
          SabiFlowBox(icon: '🎁', label: l10n.guildOnboardingStep3),
          const SizedBox(height: 20),
          // ── Sabi 口調ウェルカムメッセージ ───────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.card.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppTheme.primary.withValues(alpha: 0.25),
              ),
            ),
            child: Text(
              l10n.guildOnboardingWelcomeSabi_message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.80),
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
