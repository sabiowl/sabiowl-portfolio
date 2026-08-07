// 【FEAT-512 (2026-07-30)】習慣 inline 空状態チュートリアル。
// 案 Y: data-driven trigger (habits.isEmpty) で自動表示、SharedPreferences 不使用。
// PostHog: tutorial_shown {feature: 'habit'} を initState で 1 回送信。
import 'package:flutter/material.dart';

import '../../../core/analytics/posthog_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_flow_diagram.dart';

class SabiHabitOnboardingFlow extends StatefulWidget {
  final VoidCallback onAddHabit;
  const SabiHabitOnboardingFlow({super.key, required this.onAddHabit});

  @override
  State<SabiHabitOnboardingFlow> createState() =>
      _SabiHabitOnboardingFlowState();
}

class _SabiHabitOnboardingFlowState extends State<SabiHabitOnboardingFlow> {
  @override
  void initState() {
    super.initState();
    PosthogService.instance.capture(
      'tutorial_shown',
      properties: {'feature': 'habit'},
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          children: [
            const SizedBox(height: 16),
            // ── Flow 図 ─────────────────────────────────────────────
            SabiFlowBox(icon: '🌱', label: l10n.habitOnboardingStep1),
            const SabiFlowArrow(),
            SabiFlowBox(icon: '📅', label: l10n.habitOnboardingStep2),
            const SabiFlowArrow(),
            SabiFlowBox(icon: '🏔️', label: l10n.habitOnboardingStep3),
            const SizedBox(height: 28),
            // ── サビ口調メッセージ ─────────────────────────────────
            Text(
              l10n.habitOnboardingSabi_message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 14,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 24),
            // ── 最初の習慣を追加 CTA ────────────────────────────────
            ElevatedButton.icon(
              onPressed: widget.onAddHabit,
              icon: const Icon(Icons.add, size: 18),
              label: Text(l10n.habitOnboardingStartButton),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
