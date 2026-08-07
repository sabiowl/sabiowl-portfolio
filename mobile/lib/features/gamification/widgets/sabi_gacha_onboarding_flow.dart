// 【FEAT-512 (2026-07-30)】ガチャ inline 空状態チュートリアル。
// 案 Y: data-driven trigger (status.history.isEmpty) で自動表示。
// PostHog: tutorial_shown {feature: 'gacha'} を initState で 1 回送信。
import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';

import '../../../core/analytics/posthog_service.dart';
import '../../../shared/widgets/sabi_flow_diagram.dart';

class SabiGachaOnboardingFlow extends StatefulWidget {
  const SabiGachaOnboardingFlow({super.key});

  @override
  State<SabiGachaOnboardingFlow> createState() =>
      _SabiGachaOnboardingFlowState();
}

class _SabiGachaOnboardingFlowState extends State<SabiGachaOnboardingFlow> {
  @override
  void initState() {
    super.initState();
    PosthogService.instance.capture(
      'tutorial_shown',
      properties: {'feature': 'gacha'},
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        children: [
          // ── Flow 図 ─────────────────────────────────────────────
          SabiFlowBox(icon: '🎫', label: l10n.gamifGachaOnboardingStep1),
          const SabiFlowArrow(),
          SabiFlowBox(icon: '✨', label: l10n.gamifGachaOnboardingStep2),
          const SabiFlowArrow(),
          SabiFlowBox(icon: '⚔️', label: l10n.gamifGachaOnboardingStep3),
          const SizedBox(height: 20),
          // ── サビ口調メッセージ ─────────────────────────────────
          Text(
            l10n.gamifGachaOnboardingSabi_message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.70),
              fontSize: 13,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 8),
          // ── チケット促し ─────────────────────────────────────
          Text(
            l10n.gamifGachaOnboardingBodySabi_message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.50),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
