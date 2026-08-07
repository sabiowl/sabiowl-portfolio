import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';  // 【FEAT-518】確率画面への遷移
import '../../../core/router/app_router.dart';  // 【FEAT-518】
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/sabi_error_chip.dart';
import '../../../shared/widgets/sabi_loading_skeleton.dart';  // FEAT-218
import '../../habits/providers/habits_provider.dart';
import '../models/gamification_models.dart';
import '../providers/gamification_provider.dart';
import '../providers/pending_reward_provider.dart';
import '../widgets/sabi_gacha_onboarding_flow.dart';  // 【FEAT-512】
import 'gacha_summon_page.dart';

// ─────────────────────────────────────────────────
// レアリティカラー（履歴行で使用）
// ─────────────────────────────────────────────────
const Map<String, Color> _rarityColors = {
  'N':   Color(0xFF9E9E9E),
  'R':   Color(0xFF42A5F5),
  'SR':  AppTheme.rarityPurple,
  'SSR': AppTheme.gold,
};

// ─────────────────────────────────────────────────
// カスタムページルート（召喚画面へのフェード遷移）
// ─────────────────────────────────────────────────
class _GachaSummonRoute extends PageRoute<void> {
  final Future<GachaReward?> pullFuture;
  final String ticketType;
  final VoidCallback onCompleted;

  _GachaSummonRoute({
    required this.pullFuture,
    required this.ticketType,
    required this.onCompleted,
  });

  @override
  Color? get barrierColor => Colors.black;

  @override
  String? get barrierLabel => null;

  @override
  bool get barrierDismissible => false;

  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return GachaSummonPage(
      pullFuture:  pullFuture,
      ticketType:  ticketType,
      onCompleted: onCompleted,
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeIn),
      child: child,
    );
  }
}

// ─────────────────────────────────────────────────
// GachaPage（ロビー画面）
// ─────────────────────────────────────────────────
class GachaPage extends ConsumerStatefulWidget {
  const GachaPage({super.key});

  @override
  ConsumerState<GachaPage> createState() => _GachaPageState();
}

class _GachaPageState extends ConsumerState<GachaPage> {
  bool _isPulling = false;

  // ─── 通常の引く操作 ─────────────────────────────────────────
  Future<void> _pull(String ticketType) async {
    if (_isPulling) return;
    setState(() => _isPulling = true);
    HapticFeedback.mediumImpact();

    final pullFuture =
        ref.read(gachaNotifierProvider.notifier).pull(ticketType);

    // BUG-G: 旧実装は `if (!mounted) setState(...)` という矛盾コードだった。
    // 現状は pull() が同期的に Future を返すため発火しないが、将来 await を
    // 挟むリファクタで容易に踏める。setState を呼ばずに早期 return する。
    if (!mounted) return;

    await Navigator.of(context).push<void>(
      _GachaSummonRoute(
        pullFuture: pullFuture,
        ticketType: ticketType,
        onCompleted: () {
          if (mounted) {
            ref.invalidate(gachaNotifierProvider);
            ref.invalidate(playerNotifierProvider);
            ref.invalidate(pendingRewardsProvider);
          }
        },
      ),
    );

    if (mounted) setState(() => _isPulling = false);
  }

  // 【2026-05-28 dead code 削除】v1.0 リリース直前に開発用デバッグパネル
  // (`_debugPull` + `_buildDebugPanel` + `kDebugMode` 分岐) を物理削除。
  // release ビルドでは元々非表示だったが、リリース直前の dead code 整理として
  // 撤廃。開発時に必要なら git history (削除前 commit) から復元可能。

  // ─── build ───────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // FEAT-188: ガチャはサーバー側ゲスト基盤で完全動作（初期チケット 3 枚）。
    // 旧 GuestLinkPromptCard 分岐は撤廃。
    final l10n = AppLocalizations.of(context)!;
    final gachaAsync = ref.watch(gachaNotifierProvider);

    // 【20260729 user feedback (案 C) 対応】daily/weekly チケットが本日 MAX に
    // 到達した瞬間、Sabi 口調 SnackBar で穏やかにお祝いする。Backend が
    // just_reached_max フラグを制御するため、SnackBar の過剰発火はない
    // (既に MAX の状態や未到達では false)。cap 30/10 緩和 (silent loss 実質
    // ゼロ化) と対で「積み上げの達成感」の subtle 演出を担う。
    ref.listen<AsyncValue<GachaStatus>>(gachaNotifierProvider, (_, next) {
      final status = next.valueOrNull;
      if (status == null) return;
      if (status.dailyTicketJustReachedMax) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                l10n.gamifGachaDailyTicketNewToastSabi_message(status.dailyTickets),
              ),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 4),
            ),
          );
        });
      } else if (status.weeklyTicketJustReachedMax) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                l10n.gamifGachaWeeklyTicketNewToastSabi_message(status.weeklyTickets),
              ),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 4),
            ),
          );
        });
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.gamifGachaPageTitle),
        actions: [
          // 【FEAT-518】排出確率の開示 (App Store Guideline 3.1.1)。
          // チケットを消費する前に必ず到達できる位置に置く。
          IconButton(
            icon: const Icon(Icons.percent),
            tooltip: l10n.gachaOddsTitle,
            onPressed: () => context.push(AppRoutes.gachaOdds),
          ),
        ],
      ),
      body: gachaAsync.when(
        data:    (status) => _buildBody(context, status),
        loading: () => SabiWaitingPanel(message: l10n.gamifGachaPageLoadingSabi_message),
        error:   (e, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 12),
              Text(
                // FEAT-186: 紳士的トーンへ統一
                l10n.gamifGachaPageErrorSabi_message,
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => ref.invalidate(gachaNotifierProvider),
                icon:  const Icon(Icons.refresh),
                label: Text(l10n.gamifGachaPageReloadButton),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, GachaStatus status) {
    // 【BUG-92 (2026-06-11)】bottom padding に SafeArea (システムナビゲーション
    // のジェスチャー領域) + BottomNav 高さ (~80px、ShellRoute の _ScaffoldWith
    // BottomNav) を加算して、末尾要素 (_buildPendingSection) が BottomNav と
    // 重ならず下までスクロール可能にする。同様のパターンは他の ShellRoute 配下
    // ページ (stats_tab.dart 等) で確立済。
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottomInset + 80),
      child: Column(
        children: [
          // 【BUG-92 (2026-06-11)】「✨ チケットを選んでガチャを引こう」案内バナー
          // を撤去。ユーザー要望「必要性を感じない」採択。チケット選択 UI 自体が
          // 自己説明的で、追加の案内文は冗長だった。
          _buildTicketSection(context, status),
          const SizedBox(height: 20),
          // 【FEAT-512】ガチャ未経験ユーザーへのチュートリアル
          if (status.history.isEmpty) const SabiGachaOnboardingFlow(),
          if (status.history.isNotEmpty) _buildHistory(context, status.history),
          _buildPendingSection(context),
        ],
      ),
    );
  }

  // ─── チケットセクション ──────────────────────────────────────
  Widget _buildTicketSection(BuildContext context, GachaStatus status) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        _TicketCard(
          label:         l10n.gamifGachaDailyTicketLabel,
          tickets:       status.dailyTickets,
          pity:          status.dailyPity,
          // 【BUG-93 (2026-06-11)】天井廃止に伴い pityLimit=0 (= 天井 UI 非表示)。
          // Backend 側でも force_sr_plus=False に統一済。
          pityLimit:     0,
          guaranteeLabel: 'SR+',
          isPulling:     _isPulling,
          onPull:        () => _pull('daily'),
        ),
        const SizedBox(height: 10),
        _TicketCard(
          label:         l10n.gamifGachaWeeklyTicketLabel,
          tickets:       status.weeklyTickets,
          pity:          status.weeklyPity,
          // 【BUG-93 (2026-06-11)】天井廃止に伴い pityLimit=0 (= 天井 UI 非表示)。
          // Backend 側でも force_sr_plus=False に統一済。
          pityLimit:     0,
          guaranteeLabel: 'SR+',
          isPulling:     _isPulling,
          onPull:        () => _pull('weekly'),
          // 【更新 (2026-06-25)】weekly_ticket_granted_this_week フラグ連動。
          // 配布済: 「✓ 今週分のチケット取得済み」(grant は前週 5 日達成基準で
          //   今週の日数進捗とは別計算のため、シンプルな grant 表示に振り切る)
          // 未達: 「今週N日達成 (Y%) あとM日」(進捗率 Y = N/5 * 100、5 日達成で
          //   翌週月曜にチケット +1 配布される旨を進捗率で明示)
          extraInfo: _buildWeeklyExtraInfo(l10n,
            daysDone: status.weeklyDaysDone,
            granted:  status.weeklyTicketGrantedThisWeek,
          ),
        ),
        const SizedBox(height: 10),
        _TicketCard(
          // 【2026-06-13】ガチャ名称変更: マンスリー → SSR 確定 (BUG-97 で Monthly =
          // キャラ専用ランダム排出に変更したため、機能を明示する命名に統一)。
          label:         l10n.gamifGachaSsrTicketLabel,
          tickets:       status.monthlyTickets,
          pity:          status.monthlyPity,
          // 【BUG-97 hotfix (2026-06-13)】Monthly 天井廃止に伴い pityLimit=0
          // (= 天井 UI 非表示)。Backend 側は本セッション BUG-97 で
          // monthly_pity 経路全廃止済 (gacha.py + migration 0132)、Mobile UI
          // の本箇所が反映漏れだった。daily/weekly は BUG-93 で同様に pityLimit=0
          // 化済 (line 203/215 参照)、本変更で monthly も整合。
          // Monthly = キャラ専用ランダム排出 (BUG-97) のため天井の概念自体が
          // 不要になった (毎回キャラ確定排出)。
          pityLimit:     0,
          guaranteeLabel: 'SSR',
          isPulling:     _isPulling,
          onPull:        () => _pull('monthly'),
          // 【新規 (2026-06-25)】FEAT-433: 当月の SSR 確定チケットを既に取得済か
          // 否かをカード下部に明示する。
          //   - 取得済 (monthlyTicketGrantedThisMonth=true): 「今月分 配布済 ✓」
          //   - 未達 (monthlyDaysDone < 21): 「今月 N 日達成 / あと M 日で配布」
          //   - まれな経路 (= 21 日達成済だがフラグ false): days 表示のみで様子見
          extraInfo: _buildMonthlyExtraInfo(l10n,
            daysDone: status.monthlyDaysDone,
            granted:  status.monthlyTicketGrantedThisMonth,
          ),
          // 【BUG-102 (2026-06-14)】全 SSR 開放済時は引けない (dead pieces 救済回避)。
          // チケットは保持されたまま、新キャラ追加で自動解除される。
          disabled:      status.allSsrUnlocked,
          disabledMessage: status.allSsrUnlocked
              ? l10n.gamifGachaAllUnlockedSabi_message
              : null,
        ),
      ],
    );
  }

  /// 【更新 v2 (2026-06-25)】SSR 確定チケットカード下部の extraInfo を構築。
  ///
  /// 旧表示「今月N日達成 (Y%) ✓ チケット取得済み」はカード幅に対して長すぎて
  /// 右端がオーバーフロー (約 +18 px) するため、配布済表示を Weekly と同じ
  /// 「✓ 今月分のチケット取得済み」に簡素化。
  ///
  /// 表示パターン:
  ///   - 配布済 (granted=true):  「✓ 今月分のチケット取得済み」(Weekly と書式統一)
  ///   - 未達 / 21+ 未配布:      「今月N日達成 (Y%)」(進捗のみ、達成日数 + 進捗率)
  ///
  /// 進捗率 Y = round(N / 21 * 100)、最大 100% にクランプ。
  String _buildMonthlyExtraInfo(AppLocalizations l10n, {
    required int daysDone,
    required bool granted,
  }) {
    if (granted) {
      return l10n.gamifGachaDailyTicketClaimed;
    }
    const target = 21;
    final pct = ((daysDone / target) * 100).round().clamp(0, 100);
    return l10n.gamifGachaDailyProgress(daysDone, pct);
  }

  /// 【更新 v2 (2026-06-25)】ウィークリーチケットカード下部の extraInfo を構築。
  ///
  /// SSR 確定チケットと書式を統一 (オーバーフロー回避 + 視覚的一貫性)。
  /// Weekly の grant 条件は「前週 5 日達成」、配布判定は「今週月曜以降の
  /// GachaStatusView 初回呼び出し時」。granted=true は「前週 5+ 日 + 今週月曜
  /// 以降の初回呼び出し済」を意味し、今週の `weeklyDaysDone` (0-7) とは
  /// 直接対応しないため、配布済表示はシンプルに振り切る。
  ///
  /// 表示パターン:
  ///   - 配布済 (granted=true): 「✓ 今週分のチケット取得済み」
  ///   - 未達 / 5+ 未配布:      「今週N日達成 (Y%)」(進捗のみ、達成日数 + 進捗率)
  ///
  /// 進捗率 Y = round(N / 5 * 100)、最大 100% にクランプ。
  String _buildWeeklyExtraInfo(AppLocalizations l10n, {
    required int daysDone,
    required bool granted,
  }) {
    if (granted) {
      return l10n.gamifGachaWeeklyTicketClaimed;
    }
    const target = 5;
    final pct = ((daysDone / target) * 100).round().clamp(0, 100);
    return l10n.gamifGachaWeeklyProgress(daysDone, pct);
  }

  // ─── 履歴セクション ──────────────────────────────────────────
  Widget _buildHistory(BuildContext context, List<GachaHistoryItem> history) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.gamifGachaHistoryLabel,
          style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1),
        ),
        const SizedBox(height: 8),
        ...history.take(5).map((h) => _HistoryRow(item: h)),
      ],
    );
  }

  // ─── 交換待ちセクション ──────────────────────────────────────
  Widget _buildPendingSection(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final pendingAsync = ref.watch(pendingRewardsProvider);
    return pendingAsync.when(
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            Text(
              l10n.gamifGachaPendingRewardLabel,
              style: const TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1),
            ),
            const SizedBox(height: 8),
            ...list.map((p) => _PendingRewardRow(
                  pending:    p,
                  onExchanged: () {
                    ref.invalidate(pendingRewardsProvider);
                    ref.invalidate(playerNotifierProvider);
                  },
                )),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      // P0-2: 通信失敗を黙殺せず、ユーザーに状況を伝える
      error: (_, __) => SabiErrorChip(
        message: l10n.gamifGachaPendingRewardErrorLabel,
      ),
    );
  }

}

// ─────────────────────────────────────────────────
// ピティ警告しきい値
// ─────────────────────────────────────────────────
const _kPityWarningThreshold = 5;

// ─────────────────────────────────────────────────
// チケットカード
// ─────────────────────────────────────────────────
class _TicketCard extends StatelessWidget {
  final String label;
  final int tickets;
  final int pity;
  final int pityLimit;
  final String guaranteeLabel;
  final bool isPulling;
  final VoidCallback onPull;
  final String? extraInfo;
  // 【BUG-102 (2026-06-14)】Monthly = SSR 確定ガチャで全 SSR キャラ開放済時に true。
  // ボタン非活性化 + 説明文表示 (チケットは保持されたまま新キャラ追加を待つ)。
  final bool disabled;
  final String? disabledMessage;

  const _TicketCard({
    required this.label,
    required this.tickets,
    required this.pity,
    required this.pityLimit,
    required this.guaranteeLabel,
    required this.isPulling,
    required this.onPull,
    this.extraInfo,
    this.disabled = false,
    this.disabledMessage,
  });

  // サーバー判定: force_sr_plus = (pity >= pity_limit)
  // → pity == pityLimit に到達した時点で「次回が確定発動」なので残り 0 回。
  // 旧式 (pityLimit + 1 - pity) は「あと 1 回引けばゲット」と表示するが
  // その "1 回" 自体が天井発動回で、ユーザー体験的に詐欺になる。
  int get _remaining => max(0, pityLimit - pity);

  bool get _isWarning => _remaining <= _kPityWarningThreshold;

  Color get _barColor {
    if (_remaining <= 1) return Colors.red;
    if (_isWarning) return Colors.orange;
    return AppTheme.primary;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _isWarning
              ? Colors.orange.withValues(alpha: 0.4)
              : Colors.white.withValues(alpha: 0.08),
          width: _isWarning ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ヘッダー行
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        l10n.gamifGachaTicketCount(tickets),
                        style: const TextStyle(
                          color: AppTheme.primary,
                          fontSize: 12,
                        ),
                      ),
                      if (extraInfo != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          extraInfo!,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
              ElevatedButton(
                onPressed:
                    tickets > 0 && !isPulling && !disabled ? onPull : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  minimumSize: Size.zero,
                  textStyle: const TextStyle(fontSize: 13),
                ),
                child: Text(l10n.gamifGachaPullButton),
              ),
            ],
          ),
          // 【BUG-102 (2026-06-14)】非活性化の説明文 (全 SSR 開放済等の理由表示)
          if (disabled && disabledMessage != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: Text(
                disabledMessage!,
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
          ],
          // 【BUG-93 (2026-06-11)】pityLimit > 0 のときのみ天井 UI 表示。
          // daily/weekly の天井保証が廃止された (BUG-93) ため、それらは pityLimit=0
          // が caller から渡され、天井プログレスバー + 警告テキストごと非表示になる。
          // monthly は pityLimit=9 のままで従来通り SSR 確定までの残り回数を表示。
          if (pityLimit > 0) ...[
            const SizedBox(height: 10),

            // ピティプログレスバー
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l10n.gamifGachaCeilingRemaining(_remaining),
                  style: TextStyle(
                    color: _isWarning ? Colors.orange : Colors.white38,
                    fontSize: 10,
                    fontWeight:
                        _isWarning ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                Text(
                  '$pity / $pityLimit',
                  style: TextStyle(
                    color: _isWarning ? Colors.orange : Colors.white38,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pity / pityLimit,
                minHeight: 6,
                backgroundColor: Colors.white.withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation<Color>(_barColor),
              ),
            ),

            // 警告テキスト
            if (_isWarning) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('⚡', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 4),
                  Text(
                    _remaining == 0
                        ? l10n.gamifGachaGuaranteeNext(guaranteeLabel)
                        : l10n.gamifGachaGuaranteeRemaining(_remaining, guaranteeLabel),
                    style: const TextStyle(
                      color: Colors.orange,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// 履歴行
// ─────────────────────────────────────────────────
class _HistoryRow extends StatelessWidget {
  final GachaHistoryItem item;
  const _HistoryRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final color = _rarityColors[item.rarity] ?? Colors.white38;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(item.icon, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(item.rarity,
                style: TextStyle(color: color, fontSize: 9)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(item.name,
                style: const TextStyle(
                    color: Colors.white70, fontSize: 12)),
          ),
          Text(item.ticketType,
              style:
                  const TextStyle(color: Colors.white30, fontSize: 10)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// 交換待ち報酬の行（ロビーの pending stock セクション）
// ─────────────────────────────────────────────────
class _PendingRewardRow extends ConsumerWidget {
  final PendingReward pending;
  final VoidCallback onExchanged;

  const _PendingRewardRow({
    required this.pending,
    required this.onExchanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n  = AppLocalizations.of(context)!;
    final color = _rarityColors[pending.reward.rarity] ?? Colors.white38;
    final daysLeft =
        pending.expiresAt.difference(DateTime.now()).inDays;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: Colors.orange.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Text(pending.reward.icon,
              style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(pending.reward.rarity,
                          style:
                              TextStyle(color: color, fontSize: 9)),
                    ),
                    const SizedBox(width: 6),
                    Text(pending.reward.name,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.gamifGachaPendingExpiryLabel(daysLeft),
                  style: TextStyle(
                    color: daysLeft <= 3
                        ? Colors.red
                        : Colors.white.withValues(alpha: 0.3),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () =>
                _showExchangeDialog(context, ref),
            style: TextButton.styleFrom(
              foregroundColor: Colors.orange,
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: Text(l10n.gamifGachaPendingExchangeButton),
          ),
        ],
      ),
    );
  }

  Future<void> _showExchangeDialog(
      BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    // 【FEAT-497 (2026-08-04)】「交換ピース × 100」選択肢を復活。
    //
    // v1.0 で撤去した理由は「dead currency = backend に消費経路ゼロ」だった。
    // 本 FEAT で Shop に消費先 3 種 (XP ブースト / 出陣チケット / キャラ交換券)
    // を用意したので、選ぶ意味のある 2 択に戻る。
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(l10n.gamifGachaPendingExchangeDialogTitle,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.gamifGachaPendingExchangeDialogBodySabi_message(pending.reward.name),
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 13,
                  height: 1.6),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx, 'stat_points'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(
                      color: AppTheme.primary.withValues(alpha: 0.6)),
                  padding:
                      const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('⚡', style: TextStyle(fontSize: 18)),
                    const SizedBox(width: 8),
                    Text(l10n.gamifGachaStatPointLabel,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            // ── 【FEAT-497 (2026-08-04)】交換ピース × 100 ────────────────
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx, 'pieces'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(
                      color: AppTheme.primary.withValues(alpha: 0.6)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('🧩', style: TextStyle(fontSize: 18)),
                    const SizedBox(width: 8),
                    Text(l10n.gamifGachaPieceLabel,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13)),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.gamifGachaPendingExchangeCancelButton,
                style: const TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );

    if (choice == null) return;
    if (!context.mounted) return;

    final ok = await ref
        .read(pendingRewardsProvider.notifier)
        .exchange(pending.id, choice);

    if (!context.mounted) return;

    final l10nAfter = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        // 【FEAT-497】選んだ経路で文言を出し分ける。
        // 旧実装は 1 択 (stat_points) 前提で toast を固定していた。
        content: Text(ok
            ? (choice == 'pieces'
                ? l10nAfter.gamifGachaPieceToast
                : l10nAfter.gamifGachaStatPointToast)
            : l10nAfter.gamifGachaExchangeErrorSabi_message),
        backgroundColor:
            ok ? AppTheme.primary : Colors.red.shade700,
      ),
    );
    if (ok) onExchanged();
  }
}
