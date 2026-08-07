import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';  // 【FEAT-416】倍速永続化

import '../../../core/constants/preferences_keys.dart';  // 【FEAT-462】戻るヒント抑制
import '../../../core/router/app_router.dart';  // FEAT-295: AppRoutes.home
import '../dialogs/post_battle_rewards.dart';  // 【gameplay_review 20260803 §2-2 a】
import '../services/ambient_auto_battle_orchestrator.dart';  // 【要素 B-3】
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_loading_skeleton.dart';  // 【FEAT-482】SabiWaitingPanel
import '../models/battle_state.dart';
import '../models/combatant.dart';        // 【FEAT-387】_CombatantPanel 引数用
import '../models/tactic.dart';
import '../providers/battle_provider.dart';
import '../services/battle_haptics_service.dart';  // 【新規 2026-06-26】撃墜ハプティクス
import '../widgets/battle_back_hint_bubble.dart';  // 【FEAT-462】初回ヒント吹き出し
import '../widgets/battle_log_text.dart';
import '../widgets/combatant_sprite.dart';
import '../widgets/floating_damage_text.dart';  // 【FEAT-385】Floating Damage
import '../widgets/hp_atb_combined_bar.dart';  // 【FEAT-387】_CombatantPanel 用
import '../widgets/potion_count_indicator.dart';
import '../widgets/ult_gauge.dart';
import '../widgets/ultimate_button.dart';
import '../widgets/ultimate_hit_effect_overlay.dart';  // 【新規 2026-06-26】撃墜エフェクト

/// 【FEAT-295 Phase 1c】全画面戦闘ページ。
///
/// `BattleProvider` を listen して、ATB ゲージ + キャラ/敵スプライト + ログを表示。
/// 戦闘終了時（won / lost）に勝利 / 敗北モーダルを表示し、ユーザーが閉じたら
/// ギルドに戻る（2026-07-05 変更、旧: ホーム）。
///
/// **CLAUDE.md「dialog から navigation する時は caller が showDialog の結果で分岐」
/// パターン厳守**: モーダル内では `Navigator.pop(dialogContext, result)` のみ、
/// navigation 自体は本ページの `await showDialog<T>` 完了後に行う。
class BattlePage extends ConsumerStatefulWidget {
  const BattlePage({super.key});

  @override
  ConsumerState<BattlePage> createState() => _BattlePageState();
}

class _BattlePageState extends ConsumerState<BattlePage> {
  // 【FEAT-462】初回バトル時のみ「戻る = バトル継続」ヒントを表示するフラグ。
  bool _showBackHint = false;

  /// 【新規 (2026-06-26)】撃墜エフェクト発火 controller。
  /// ref.listen で UltimateHitEvent transition を検知して fire() を呼ぶ。
  /// 同一フレームで [BattleHapticsService.playUltimateHit] も発火する。
  final UltimateHitEffectController _ultimateHitEffect =
      UltimateHitEffectController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 初回 build 後にバトル開始。
      // 【FEAT-297】既に WorldFrameSection 経由でセッションが進行中の場合は
      // `BattleSessionNotifier.startBattle` 側で `if (_orchestrator != null) return`
      // で no-op となり、既存セッション (state / token) はそのまま継続表示される。
      ref.read(battleSessionProvider.notifier).startBattle();

      // 【FEAT-462】初回バトル時のみ「戻る = バトル継続」ヒントを表示。
      // 戦闘開始演出 (sprite フェードイン等) と被らないよう 1.5 秒遅延。
      Future.delayed(const Duration(milliseconds: 1500), () async {
        if (!mounted) return;
        if (await shouldShowBattleBackHint()) {
          if (!mounted) return;
          // 【Pre-mortem S1/S2】表示前に記録する (race / crash で 2 回目発火を防ぐ)。
          await markBattleBackHintShown();
          if (!mounted) return;
          setState(() => _showBackHint = true);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(battleSessionProvider);

    // 【新規 (2026-06-26)】必殺技命中時の撃墜エフェクト発火。
    // UltimateHitEvent transition (null → non-null) を検知して、ハプティクス +
    // 画面シェイク + 白フラッシュ + 爆発リング を **同一フレーム同期開始** する。
    ref.listen<BattleSession>(battleSessionProvider, (prev, next) {
      final prevEvent = prev?.state?.ultimateHitEvent;
      final nextEvent = next.state?.ultimateHitEvent;
      // null → non-null、または別 timestamp の event に切り替わったとき発火
      if (nextEvent != null && nextEvent != prevEvent) {
        // 視覚エフェクト + ハプティクスを同フレームで発火 (fire-and-forget)。
        _ultimateHitEffect.fire();
        // ハプティクスは async だが await しない (UI スレッドをブロックしない)。
        // BattleHapticsService 内で MethodChannel 経由 (Android Waveform /
        // iOS Core Haptics)、失敗時は HapticFeedback chain にフォールバック。
        BattleHapticsService.instance.playUltimateHit();
      }
    });

    // 【新規】通常攻撃命中時のハプティクス（クリティカルは別感触）。
    // player/enemy どちらの DamageEvent も「攻撃が当たった」イベントなので
    // 両方を監視し、null → non-null / timestamp 変化を検知して発火する。
    ref.listen<BattleSession>(battleSessionProvider, (prev, next) {
      final prevPlayerEvent = prev?.state?.playerDamageEvent;
      final nextPlayerEvent = next.state?.playerDamageEvent;
      final prevEnemyEvent  = prev?.state?.enemyDamageEvent;
      final nextEnemyEvent  = next.state?.enemyDamageEvent;

      DamageEvent? firedEvent;
      if (nextPlayerEvent != null && nextPlayerEvent != prevPlayerEvent) {
        firedEvent = nextPlayerEvent;
      } else if (nextEnemyEvent != null && nextEnemyEvent != prevEnemyEvent) {
        firedEvent = nextEnemyEvent;
      }
      if (firedEvent == null) return;
      if (firedEvent.isCritical) {
        BattleHapticsService.instance.playCriticalHit();
      } else {
        BattleHapticsService.instance.playNormalHit();
      }
    });

    // 戦闘終了検知 → モーダル表示 + ホーム戻り（caller-decides-navigation）
    ref.listen<BattleSession>(battleSessionProvider, (prev, next) {
      if (next.state == null) return;
      final status = next.state!.status;
      // 【FEAT-296 hotfix 2026-05-24】_sendFinish の API 応答完了
      // （finishCompleted = true）を待ってからモーダル発火。
      // 旧実装は status == won/lost だけで即発火していたため、
      // rewardCoinsGained = 0 のまま「+0 coins / +0 EXP」表示される
      // バグがあった。Backend 失敗時も catch 経路で finishCompleted
      // = true に設定されるためフリーズしない設計。
      // 【FEAT-297 Pre-mortem #3】BattlePage と WorldFrameSection の二重発火を防ぐため、
      // `markModalShown()` で「最初の listener が独占的に true を取りに行く」設計。
      // 既に true ならスキップ（他で発火済）。
      if ((status == BattleStatus.won || status == BattleStatus.lost)
          && next.finishCompleted) {
        final won = ref
            .read(battleSessionProvider.notifier)
            .markModalShown();
        if (!won) return; // 他で発火済 → BattlePage 側はスキップ
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _handleBattleEnd(status, next);
        });
      }
    });

    // 【新規 (2026-06-26)】UltimateHitEffectOverlay で全画面を wrap。
    // 撃墜エフェクト (画面シェイク + 白フラッシュ + 爆発リング) を最前面に重ね、
    // _ultimateHitEffect.fire() で 350ms の演出を発火する。
    return UltimateHitEffectOverlay(
      controller: _ultimateHitEffect,
      child: Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.battlePageTitle),
        backgroundColor: Colors.transparent,
        elevation: 0,
        // 【ユーザー判断 2026-05-31】戻るボタンを context.go(/home) に override。
        // 旧: Navigator.pop でギルド画面に戻る (push 元への単純 pop)
        // 新: ホーム遷移 + バトル state 継続 (autoDispose 無効、WorldFrameSection が
        //     isBattleRunning=true を検知して MiniBattleArena overlay 表示)
        // → 「大画面で受託 → 戻るで縮小、ながらプレイ移行」UX フロー。
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: AppLocalizations.of(context)!.battlePageBackTooltip,
          onPressed: () => context.go(AppRoutes.home),
        ),
        // 【FEAT-416 (2026-06-01) + FEAT-513 v1.1 hotfix 2026-07-31】
        // 5 段階の倍速チップ (1x / 1.5x / 2x / 3x / ⏭ Skip)。
        // ⏭ Skip = 50x tick 速度で battle が ~1-2 秒で終了 (FEAT-505 §2.1 原仕様復元)。
        // AnimatedContainer(150ms) で即時選択フィードバック (Pre-mortem S4)。
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SpeedChip(value: 1.0,  label: '1x'),
                  _SpeedChip(value: 1.5,  label: '1.5x'),
                  _SpeedChip(value: 2.0,  label: '2x'),
                  _SpeedChip(value: 3.0,  label: '3x'),
                  _SpeedChip(value: 50.0, label: '⏭'),
                ],
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: session.state == null
            // 【FEAT-482 (2026-07-06)】Sabi パネル統一 (shop_page.dart:196 と同パターン)
            ? SabiWaitingPanel(message: AppLocalizations.of(context)!.battlePageLoadingSabi_message)
            : Stack(
                children: [
                  // 【FEAT-387 (2026-05-30)】背景は _buildBattleArena 内の
                  // 上半分 Stack に移動 (バトルエリアのみに背景を閉じ込め、
                  // ログ + 作戦エリアは黒ベース維持)。
                  _buildBattleArena(session.state!),
                  // 【FEAT-298】右上に回復薬残数（plan > 0 のときのみ表示）。
                  const Positioned(
                    top: 8,
                    right: 12,
                    child: PotionCountIndicator(),
                  ),
                  // 【FEAT-462 Pre-mortem S3】Positioned でラップし、表示有無に
                  // 関わらず Stack の sizing 主導は Positioned.fill 側が担う
                  // (FEAT-454 パターン踏襲、非 Positioned の子を Stack に直接
                  // 置くと sizing が崩れるリスクを回避)。
                  if (_showBackHint)
                    Positioned(
                      top: 0,
                      left: 0,
                      child: BattleBackHintBubble(
                        onComplete: () {
                          if (!mounted) return;
                          setState(() => _showBackHint = false);
                        },
                      ),
                    ),
                ],
              ),
      ),
    ),  // ← Scaffold の閉じ
    );  // ← UltimateHitEffectOverlay の閉じ
  }

  /// 【FEAT-387 (2026-05-30)】横並び対峙レイアウト (縦並び→横並び再構築)。
  ///
  /// 上 6 割: 対峙バトルエリア (敵=左右向き / 味方=右左向き) + 背景 (FEAT-381 経路維持)。
  /// 下 4 割: 戦闘ログ + 作戦切替 + 必殺ゲージ + 必殺ボタン。
  ///
  /// Pre-mortem #1 (charge 方向): CombatantSprite.attackDirection で左右符号を制御。
  /// Pre-mortem #2 (バー幅): HpAtbCombinedBar(compact: false) で十分な幅確保。
  /// Pre-mortem #4 (FloatingDamage): spriteSize 128 に合わせ top: -16。
  Widget _buildBattleArena(BattleState state) {
    final bgPath = state.enemyBackgroundImagePath;

    return Column(
      children: [
        // ── 上半分: 対峙バトルエリア ──────────────────────
        Expanded(
          flex: 6,
          child: Stack(
            children: [
              // 【FEAT-381 経路維持】バトルエリア内に背景を閉じ込める。
              // MiniArena alpha 0.25 より薄い 0.15 で全画面の迫力を演出。
              if (bgPath.isNotEmpty) ...[
                Positioned.fill(
                  child: Image.asset(
                    bgPath,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.none,
                    errorBuilder: (_, __, ___) =>
                        Container(color: AppTheme.background),
                  ),
                ),
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.15),
                  ),
                ),
              ],
              // ── 対峙構図 (横並び Row) ──────────────────
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 24),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // 左: 敵 (sprite は PixelLab で既に右向き生成のため flipHorizontal: false 維持)
                    // 【FEAT-387 hotfix 2026-05-30】真因: 敵 sprite (enemy_*.png) は全 14 体
                    // 右向き生成済 (Read で確認: goblin_king / dragon / griffin / giant_slime /
                    // armored_knight)、flipHorizontal: true で逆に左向きへ反転 = 味方から離れる
                    // 方向になり対峙構図が崩れていた。default false で元の右向きを維持し、
                    // 味方 (left-facing) と正しく向き合う。
                    Expanded(
                      child: _CombatantPanel(
                        combatant: state.enemy,
                        spriteSize: 128,
                        flipHorizontal: false,
                        attackDirection: AttackDirection.right,
                        action: state.status == BattleStatus.won
                            ? SpriteAction.fadeOut
                            : state.enemyAction,
                        damageEvent: state.enemyDamageEvent,
                        isEnemy: true,  // 【FEAT-403】敵側は ATB 廃止 + HP 全幅化
                      ),
                    ),
                    // 中央: 対峙の象徴アイコン (MiniArena より大きく迫力)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Icon(
                        Icons.flash_on,
                        size: 32,
                        color: Colors.amber,
                      ),
                    ),
                    // 右: 味方 (flipHorizontal: false で左向き = 敵を見る)
                    Expanded(
                      child: _CombatantPanel(
                        combatant: state.player,
                        spriteSize: 128,
                        flipHorizontal: false,
                        attackDirection: AttackDirection.left,
                        action: state.status == BattleStatus.lost
                            ? SpriteAction.fadeOut
                            : state.playerAction,
                        damageEvent: state.playerDamageEvent,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // ── 下半分: ログ + 作戦切替 + 必殺 ───────────────
        Expanded(
          flex: 4,
          child: _BattleLogAndTacticsPanel(state: state),
        ),
      ],
    );
  }

  Future<void> _handleBattleEnd(BattleStatus status, BattleSession session) async {
    final isWin = status == BattleStatus.won;
    // 【CLAUDE.md】showDialog の caller-decides-navigation パターン:
    // モーダル内では Navigator.pop(dialogContext) のみ、本ページの caller で
    // 結果を受けてから navigation を実行。300ms 待機で dispose 完全完了を待つ。
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _BattleEndModal(
        isWin:        isWin,
        rewardCoins:  session.rewardCoinsGained,
        rewardExp:    session.rewardExpGained,
        leveledUp:    session.leveledUp,
        newLevel:     session.newLevel,
        onConfirm:    () => Navigator.pop(dialogContext),
      ),
    );
    if (!mounted) return;
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    // 【gameplay_review 20260803 §2-2 a】武器ドロップ / 初勝利ダイヤ / 熟練度 Max の
    // 3 演出は `showPostBattleRewards` に集約済。ホーム経路 (showWorldBattleEndModal)
    // と同じ関数を通すことで「主経路にだけ演出が届かない」漏れを構造的に防ぐ。
    await showPostBattleRewards(context, session);
    if (!mounted) return;
    // 【2026-07-05】クエスト完了後はギルドへ戻す。ホームではなく「クエスト受注元」
    // に戻すことで、続けて次のクエストを選ぶ動線が自然になる。leading の戻るボタン
    // (line 167) は現状通り AppRoutes.home（ながらプレイ移行）で維持。
    //
    // 【gameplay_review 20260803 要素 B-3】ただし ambient queue 実行中に user が
    // ワールドフレームを tap して入ってきた場合はホームへ返す。ギルドに飛ばすと
    // **続く 2 戦目がワールドフレームの無い画面で進行**してしまい、「ながら見」
    // という機能の前提そのものが壊れる。
    final ambientRunning = ref.read(ambientAutoBattleProvider).isRunning;
    context.go(ambientRunning ? AppRoutes.home : AppRoutes.guild);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 【FEAT-387 (2026-05-30)】_CombatantPanel — 敵 / 味方共通パネル (private)
// ─────────────────────────────────────────────────────────────────────────────

/// sprite + FloatingDamage + 名前 + HP|ATB バー を縦積みした共通パネル。
///
/// 敵 / 味方で `flipHorizontal` と `attackDirection` を切り替えることで
/// 「向き合い構図」を実現する (Pre-mortem #1 対応: charge 方向も反転)。
class _CombatantPanel extends StatelessWidget {
  const _CombatantPanel({
    required this.combatant,
    required this.spriteSize,
    required this.flipHorizontal,
    required this.attackDirection,
    required this.action,
    required this.damageEvent,
    this.isEnemy = false,
  });

  final Combatant combatant;
  final double spriteSize;
  final bool flipHorizontal;
  final AttackDirection attackDirection;
  final SpriteAction action;
  final DamageEvent? damageEvent;

  /// 【FEAT-403 (2026-06-01)】敵側 (ボス) パネルは ATB 表示を廃止し HP 全幅化。
  final bool isEnemy;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Sprite + Floating Damage (FEAT-385 既パターン、top -16 でサイズ 128 に合わせ)
        SizedBox(
          width: spriteSize,
          height: spriteSize,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              CombatantSprite(
                spriteKey: combatant.spriteKey,
                size: spriteSize,
                flipHorizontal: flipHorizontal,
                attackDirection: attackDirection,
                action: action,
              ),
              if (damageEvent != null)
                Positioned(
                  // 【FEAT-387 Pre-mortem #4】sprite 128 に合わせて MiniArena (-8) より大きく。
                  top: -16,
                  child: FloatingDamageText(
                    key: ValueKey(damageEvent!.timestamp),
                    event: damageEvent!,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 名前
        Text(
          combatant.name,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        // HP|ATB 一体型バー (FEAT-384)、compact: false で全画面幅を活かす。
        // 【FEAT-387 Pre-mortem #2】幅圧迫対策: Expanded 内に置くので幅は充分確保される。
        // 【FEAT-403】敵側 (isEnemy=true) は ATB 廃止 + HP 全幅化、味方は ATB 表示維持。
        HpAtbCombinedBar(
          combatant: combatant,
          compact: false,
          showAtb: !isEnemy,
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 【FEAT-387 (2026-05-30)】_BattleLogAndTacticsPanel — ログ + 作戦 + 必殺 (private)
// ─────────────────────────────────────────────────────────────────────────────

/// 下半分 (flex 4): 戦闘ログ + 作戦切替チップ + 必殺ゲージ + 必殺ボタン。
///
/// 縦スペースが MiniArena より確保されるため、ログを 6 行表示可能。
/// 作戦切替 + UltGauge + UltimateButton は Row 末尾に横並び。
class _BattleLogAndTacticsPanel extends ConsumerWidget {
  const _BattleLogAndTacticsPanel({required this.state});

  final BattleState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(color: Colors.white12, height: 1),
          // ── 戦闘ログ (縦スペース拡大 flex 4 分を活かして複数行表示) ──
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: BattleLogText(lines: state.logLines, maxLines: 6),
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          const SizedBox(height: 6),
          // ── 作戦切替 + 必殺ゲージ + 必殺ボタン ──────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 作戦チップ群
              // 【BUG (2026-06-25)】回復薬 (基本 + 上位) を 1 個もセットして
              // いない場合は「回復重視」を選択肢から非表示にする。potionsPlanned
              // は戦闘開始時に固定されるため ref.read で十分 (不変値、rebuild 不要)。
              Expanded(
                child: Builder(
                  builder: (context) {
                    final l10n = AppLocalizations.of(context)!;
                    final hasRecovery = ref
                        .read(battleSessionProvider.notifier)
                        .hasRecoveryPotions;
                    final visibleTactics = Tactic.values.where((t) {
                      return t != Tactic.recovery || hasRecovery;
                    }).toList();
                    return Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: visibleTactics.map((t) {
                        final selected = state.tactic == t;
                        return ChoiceChip(
                          label: Text(t.localizedLabel(l10n)),
                          selected: selected,
                          onSelected: (_) {
                            HapticFeedback.selectionClick();
                            ref
                                .read(battleSessionProvider.notifier)
                                .switchTactic(t);
                          },
                          selectedColor: AppTheme.primary,
                          labelStyle: TextStyle(
                            color: selected ? Colors.white : Colors.white70,
                            fontSize: 12,
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ),
              // 必殺ゲージ
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 4),
                child: UltGauge(
                  chargedCount: state.chargedSpecialCount,
                  ultCost: state.player.ultCost,
                ),
              ),
              // 手動必殺ボタン
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 4),
                child: UltimateButton(
                  chargedCount: state.chargedSpecialCount,
                  ultCost: state.player.ultCost,
                  queueUltimate: state.queueUltimate,
                  status: state.status,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 【FEAT-416 (2026-06-01)】_SpeedChip — 倍速選択チップ (private ConsumerWidget)
// ─────────────────────────────────────────────────────────────────────────────

/// AppBar actions に並ぶ速度倍率チップ。
///
/// `battleSessionProvider` を watch して現在の `speedMultiplier` を取得し、
/// 自身の `value` と一致するとき `AppTheme.primary` でハイライト。
/// `AnimatedContainer(150ms)` で即時選択フィードバック (Pre-mortem S4)。
///
/// タップ時:
/// 1. `battleSessionProvider.notifier.setSpeedMultiplier` で Orchestrator に伝搬
/// 2. `SharedPreferences` に永続化（次回バトル開始時に restore される）
class _SpeedChip extends ConsumerWidget {
  const _SpeedChip({required this.value, required this.label});

  final double value;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(battleSessionProvider);
    final current = session.state?.speedMultiplier ?? 1.0;
    final isSelected = (current - value).abs() < 0.01;
    return GestureDetector(
      onTap: () {
        ref.read(battleSessionProvider.notifier).setSpeedMultiplier(value);
        SharedPreferences.getInstance().then((prefs) {
          prefs.setDouble('battle_speed_multiplier', value);
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.5),
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

/// 勝利 / 敗北モーダル。サビ口調 + caller-decides-navigation 厳守。
class _BattleEndModal extends StatelessWidget {
  const _BattleEndModal({
    required this.isWin,
    required this.rewardCoins,
    required this.rewardExp,
    required this.leveledUp,
    required this.newLevel,
    required this.onConfirm,
  });

  final bool isWin;
  final int rewardCoins;
  final int rewardExp;
  final bool leveledUp;
  final int? newLevel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = isWin
        ? l10n.battleEndModalVictoryTitleSabi_message
        : l10n.battleEndModalDefeatTitleSabi_message;
    final body = isWin
        ? '${l10n.battleEndModalVictoryRewardSabi_message(rewardCoins, rewardExp)}'
            '${leveledUp ? l10n.battleEndModalLevelUpSabi_message(newLevel!) : ''}'
        : l10n.battleEndModalDefeatBodySabi_message;
    return AlertDialog(
      backgroundColor: AppTheme.card,
      title: Text(
        title,
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
      content: Text(
        body,
        style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: onConfirm,
          child: Text(l10n.battleEndModalReturnButton),
        ),
      ],
    );
  }
}

