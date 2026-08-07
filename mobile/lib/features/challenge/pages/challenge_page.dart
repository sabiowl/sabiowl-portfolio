import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/toast_center.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_loading_skeleton.dart';
import '../models/challenge.dart';
import '../providers/challenge_provider.dart';
import '../widgets/challenge_card.dart';
import '../widgets/sabi_challenge_onboarding_flow.dart';  // 【FEAT-512】

/// 【FEAT-465→FEAT-466 (2026-06-24)】月次カテゴリチャレンジ画面。
///
/// Gemini Ver1.1 要件 + PM 確定設計 (Q1-Q7 + R1/R2) に基づく一覧表示。個人
/// ランキング / 未達告知は表示しない (Sabi「比較・誇示禁止」哲学、§8 v1.1 で
/// 意図的にやらない事項)。
class ChallengePage extends ConsumerWidget {
  const ChallengePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final challengesAsync = ref.watch(challengeListProvider);

    // 【§5-4】lazy 報酬配布で達成扱いになった分のみ、達成段階に応じた 3 種類の
    // Sabi 口調 SnackBar を発火する。未達 (achievedAny=false) は無音 (§5-4、
    // 心理的安全性優先)。`ref.listen` は provider の値が変化したときだけ
    // 反応するため、再描画での重複発火はしない。同じ participation は
    // gold_granted=True 後に二度と pending_rewards に載らないため (Backend 側
    // の冪等性保証)、再取得時の再発火も発生しない。
    ref.listen<AsyncValue<ChallengeListData>>(challengeListProvider,
        (prev, next) {
      final data = next.valueOrNull;
      if (data == null) return;
      for (final reward in data.pendingRewards) {
        if (!reward.achievedAny) continue;
        final message = _buildAchievementMessage(l10n, reward);
        if (message == null) continue;
        ToastCenter.showSabi(message, duration: const Duration(seconds: 5));
      }
    });

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: Text(l10n.challengePageTitle, style: const TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(challengeListProvider.future),
        child: challengesAsync.when(
          loading: () =>
              SabiWaitingPanel(message: l10n.challengePageLoadingSabi_message),
          error: (e, _) => ListView(
            children: [
              const SizedBox(height: 80),
              Center(
                child: Text(
                  l10n.challengePageErrorSabi_message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
          data: (data) => _buildBody(context, data),
        ),
      ),
    );
  }

  /// 【§5-4】達成段階に応じた 3 種類の Sabi 口調文言を組み立てる。
  /// `highestTier` が null (= 配布なし) の場合は呼び出し元で既にスキップ済み
  /// だが、防御的に null を返す。
  String? _buildAchievementMessage(AppLocalizations l10n, PendingChallengeReward reward) {
    switch (reward.highestTier) {
      case 'gold':
        return l10n.challengePageRewardGoldSabi_message(
          reward.challengeTitle,
          reward.totalRewardExp,
          reward.contributionCount,
        );
      case 'silver':
        return l10n.challengePageRewardSilverSabi_message(
          reward.challengeTitle,
          reward.totalRewardExp,
        );
      case 'bronze':
        return l10n.challengePageRewardBronzeSabi_message(
          reward.challengeTitle,
          reward.totalRewardExp,
        );
      default:
        return null;
    }
  }

  Widget _buildBody(BuildContext context, ChallengeListData data) {
    // 【BUG】ChallengePage は ShellRoute 配下で BottomNav が Stack overlay
    // (Positioned) で重ねられるため、Scaffold.bottomNavigationBar による自動の
    // body 縮小が効かない。_ScaffoldWithBottomNav が MediaQuery.padding.bottom
    // に kNavBarHeight を加算補正済みなので、ここで明示的に bottom padding へ
    // 反映しないと最後のカードがナビバーの下に隠れてスクロールしきれない。
    final navClearance = MediaQuery.of(context).padding.bottom + 16;

    if (data.active.isEmpty) {
      return ListView(
        children: [
          if (data.infoText.isNotEmpty) _InfoBanner(infoText: data.infoText),
          const SizedBox(height: 60),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Center(
              child: Text(
                AppLocalizations.of(context)!.challengePageEmptyStateSabi_message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.6),
              ),
            ),
          ),
          SizedBox(height: navClearance),
        ],
      );
    }

    // 【FEAT-512】全チャレンジが未参加 (myContributionCount == 0) = チュートリアル表示
    final showTutorial = data.active.isNotEmpty &&
        data.active.every((c) => c.myContributionCount == 0);
    return ListView.builder(
      padding: EdgeInsets.only(bottom: navClearance),
      itemCount: data.active.length + (showTutorial ? 2 : 1),
      itemBuilder: (context, index) {
        if (index == 0) {
          return data.infoText.isNotEmpty
              ? _InfoBanner(infoText: data.infoText)
              : const SizedBox.shrink();
        }
        if (showTutorial && index == 1) {
          return const SabiChallengeOnboardingFlow();
        }
        final cardIndex = showTutorial ? index - 2 : index - 1;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: ChallengeCard(challenge: data.active[cardIndex]),
        );
      },
    );
  }
}

/// 【R1 (2026-06-24)】1 日 1 回ガード説明バナー。ChallengePage 上部に常時表示。
class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.infoText});

  final String infoText;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.20)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: AppTheme.primary, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              infoText,
              style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
