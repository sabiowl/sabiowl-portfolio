import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// 【FEAT-498 §2.4 (2026-07-31)】旧 shared_preferences 依存
// (_checkFreeMemoMonthlyPrompt) は memo_page.dart に移設したため import 撤去。

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/reward_toast.dart';
import '../../auth/services/onboarding_service.dart';
import '../../battle/providers/battle_provider.dart';
import '../../challenge/models/challenge.dart';  // 【20260729 v1.0.5】PendingChallengeReward
// 【FEAT-498 §2.4 (2026-07-31)】旧 free_memo_provider (freeMemoCountProvider) 依存も
// _checkFreeMemoMonthlyPrompt 撤去に伴い import 撤去。
import '../providers/home_bootstrap_provider.dart';  // 【20260729 v1.0.5】
import '../../guild/services/receptionist_service.dart';
import '../../guild/widgets/lilia_floating_panel.dart';
import '../models/habit.dart' show HabitReward;
import 'home_notification_prompt_controller.dart';
import '../providers/completion_effect_provider.dart';
import '../providers/habits_provider.dart';
import '../widgets/light_beam_overlay.dart';

/// 【FEAT-473 Phase 1 (2026-07-03)】ホーム画面の ref.listen を集約したラッパー。
///
/// home_page.dart から 5 件の ref.listen を抽出し、状態変数・OverlayEntry・
/// メソッドとともに本クラスに移動。home_page.dart は widget.child を
/// HomeListeners で包むだけで同じ動作を保つ。
class HomeListeners extends ConsumerStatefulWidget {
  const HomeListeners({required this.child, super.key});
  final Widget child;

  @override
  ConsumerState<HomeListeners> createState() => _HomeListenersState();
}

class _HomeListenersState extends ConsumerState<HomeListeners> {
  // ── 初回体験フラグ ────────────────────────────────────────────────────
  bool _firstTodoCompleted = true; // initState で実際の値を読み込む

  // ── 【FEAT-315】リリア勝利祝福パネル ──────────────────────────────────
  final ReceptionistService _liliaService = ReceptionistService();
  DateTime? _lastShownVictoryAt; // 同一 victory イベントの二重発火防止用

  // ── リワードトースト ──────────────────────────────────────────────────
  OverlayEntry? _rewardEntry;
  OverlayEntry? _lightBeamEntry; // 光パーティクルエフェクト用

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final firstTodoDone = await OnboardingService.isFirstTodoCompleted();
      if (mounted) {
        _firstTodoCompleted = firstTodoDone;
      }
      if (firstTodoDone && mounted) {
        await HomeNotificationPromptController.maybeShow(context);
      }
      // 【FEAT-498 §2.4 (2026-07-31)】旧 _checkFreeMemoMonthlyPrompt (SnackBar 6 秒
      // 発火) は memo_page.dart 上部 常設 1 行に移設。「急がせない Sabi 哲学」に
      // SnackBar (消えゆく通知) は不整合、user がメモ画面に到達した時に
      // 静かに現れる passive banner に器を変更。
    });
  }

  @override
  void dispose() {
    _rewardEntry?.remove();
    _rewardEntry = null;
    _lightBeamEntry?.remove();
    _lightBeamEntry = null;
    super.dispose();
  }

  // 【FEAT-498 §2.4 (2026-07-31)】旧 _checkFreeMemoMonthlyPrompt (FEAT-493 導入
  // 2026-07-25) は撤去。「急がせない Sabi 哲学」を SnackBar (消えゆく通知) で伝える
  // 器と中身の齟齬を解消。新しい配置 = memo_page.dart 上部の常設 1 行 banner
  // (「その月に 1 回だけ現れる、そこにいる存在」)。SharedPreferences monthKey
  // `free_memo_sabi_prompt_YYYY_M` は memo_page 側で流用 (書式互換)。

  @override
  Widget build(BuildContext context) {
    // ── 【20260729 v1.0.5 Option A】Challenge 期限切れ後の lazy 報酬配布 SnackBar ──
    // Backend `/api/home/` レスポンスの `pending_challenge_rewards` を parse した
    // 結果 (bootstrapPendingChallengeRewardsProvider) を listen、achieved_any=true
    // の分のみ Sabi 口調 SnackBar 発火する。Challenge 画面を開かない user にも
    // 報酬が届いていることを Home で告知 (旧: Challenge 画面 open 時のみ発火、
    // 開かない user は永久放置)。tier 別文言は challenge_page.dart:74-91 と同型。
    ref.listen<List<PendingChallengeReward>>(
      bootstrapPendingChallengeRewardsProvider,
      (_, rewards) {
        if (rewards.isEmpty) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final l10n = AppLocalizations.of(context)!;
          for (final reward in rewards) {
            if (!reward.achievedAny) continue;
            final message = _buildChallengeAchievementMessage(l10n, reward);
            if (message == null) continue;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(message),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 5),
              ),
            );
          }
          // 1 度発火したら state を空に戻して、次回 Home refetch (invalidate 等)
          // で来た新規 rewards のみに反応 (二重発火防止、Backend 側の
          // gold_granted flag と併せて構造的に担保)。
          ref
              .read(bootstrapPendingChallengeRewardsProvider.notifier)
              .state = const [];
        });
      },
    );

    // 🔴 【BUG-150 (2026-08-29)】ログインボーナス / レベルアップの listener は
    // `core/widgets/app_popup_listeners.dart` に**移設した**。
    //
    // ここ (HomePage の中) に置いていたせいで、素の ShellRoute がタブ切替で
    // HomePage を unmount する → `ref.listen` は edge-triggered なので
    // **カレンダータブから達成しても祝われない**状態だった。
    //
    // ⚠️ **戻さないこと。** 両方に置くと二重発火する。

    // ── コンバック通知（休息日なのに習慣を達成）─────────────────────────
    ref.listen<bool>(comebackNotifierProvider, (_, isComeback) {
      if (!isComeback) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(comebackNotifierProvider.notifier).state = false;
        final l10n = AppLocalizations.of(context)!;
        final messages = [
          l10n.habitHomeComebackSabi1_message,
          l10n.habitHomeComebackSabi2_message,
          l10n.habitHomeComebackSabi3_message,
          l10n.habitHomeComebackSabi4_message,
          l10n.habitHomeComebackSabi5_message,
        ];
        final msg = messages[DateTime.now().second % messages.length];
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            content: Text('🪶 $msg'),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ));
      });
    });

    // ── リワードトースト + 光エフェクト統合リスナー ─────────────────────
    ref.listen<HabitReward?>(rewardToastProvider, (_, reward) {
      if (reward == null) return;
      final sourcePos = ref.read(completionTapPositionProvider);
      ref.read(completionTapPositionProvider.notifier).state = null;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        _showRewardToast(reward);
        if (sourcePos != null) {
          _triggerLightBeamEffect(sourcePos);
        }
        if (!_firstTodoCompleted) {
          _firstTodoCompleted = true;
          await OnboardingService.markFirstTodoCompleted();
          if (!mounted) return;
          await Future.delayed(const Duration(milliseconds: 200));
          if (!mounted) return;
          // ignore: use_build_context_synchronously
          await HomeNotificationPromptController.maybeShow(context);
        }
      });
    });

    // ── 【FEAT-315】バトル勝利祝福 → リリアパネル発火 ──────────────────
    ref.listen<BattleSession>(battleSessionProvider, (prev, next) {
      final victoryAt = next.lastVictoryAt;
      if (victoryAt == null) return;
      if (_lastShownVictoryAt == victoryAt) return;
      final elapsed = DateTime.now().difference(victoryAt);
      if (elapsed > const Duration(seconds: 5)) return;
      _lastShownVictoryAt = victoryAt;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).clearSnackBars();
        final messageKey = _liliaService.pickMessageKey(ReceptionistState.victoryJustNow);
        final l10n = AppLocalizations.of(context)!;
        final message = resolveLiliaMessage(l10n, messageKey);
        LiliaFloatingPanel.show(context, message: message);
      });
    });

    return widget.child;
  }

  /// 【20260729 v1.0.5 Option A】Challenge 期限切れ後の lazy 報酬 SnackBar 文言。
  /// challenge_page.dart:74-91 の `_buildAchievementMessage` と同型 (未達=null
  /// で SnackBar 発火スキップ、Sabi「焦らずとも構いません」精神)。
  String? _buildChallengeAchievementMessage(
      AppLocalizations l10n, PendingChallengeReward reward) {
    switch (reward.highestTier) {
      case 'gold':
        return l10n.habitHomeChallengeGoldSabi_message(
          reward.challengeTitle, reward.totalRewardExp, reward.contributionCount);
      case 'silver':
        return l10n.habitHomeChallengeSilverSabi_message(
          reward.challengeTitle, reward.totalRewardExp);
      case 'bronze':
        return l10n.habitHomeChallengeBronzeSabi_message(
          reward.challengeTitle, reward.totalRewardExp);
      default:
        return null;
    }
  }

  // ── リワードトースト表示 ─────────────────────────────────────────────────

  void _showRewardToast(HabitReward reward) {
    _rewardEntry?.remove();
    _rewardEntry = OverlayEntry(
      builder: (_) => RewardToastOverlay(reward: reward),
    );
    Overlay.of(context).insert(_rewardEntry!);
    Future.delayed(const Duration(milliseconds: 1700), () {
      _rewardEntry?.remove();
      _rewardEntry = null;
      if (mounted) {
        ref.read(rewardToastProvider.notifier).state = null;
      }
    });
  }

  // ── 光ビームエフェクト ────────────────────────────────────────────────────

  void _triggerLightBeamEffect(Offset sourcePosition) {
    _lightBeamEntry?.remove();
    _lightBeamEntry = null;
    ref.read(worldFrameGlowProvider.notifier).state = false;
    final screenSize      = MediaQuery.of(context).size;
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final topMargin   = statusBarHeight + kToolbarHeight + 12.0;
    final frameWidth  = screenSize.width - 32.0;
    final frameHeight = frameWidth / 2.4;
    final Offset targetPosition = Offset(
      screenSize.width / 2,
      topMargin + frameHeight / 2,
    );
    _lightBeamEntry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: IgnorePointer(
          child: LightBeamOverlay(
            sourcePosition: sourcePosition,
            targetPosition: targetPosition,
            onFrameReached: () {
              if (mounted) ref.read(worldFrameGlowProvider.notifier).state = true;
            },
            onComplete: () {
              _lightBeamEntry?.remove();
              _lightBeamEntry = null;
              Future.delayed(const Duration(milliseconds: 400), () {
                if (mounted) ref.read(worldFrameGlowProvider.notifier).state = false;
              });
            },
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_lightBeamEntry!);
  }
}
