import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
import '../widgets/ko_effect_overlay.dart';  // 【FEAT-526】KO 演出
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

  // ── 【FEAT-526 (2026-08-21)】KO 演出 ────────────────────────────────────

  /// KO 演出の発火 controller (戦闘エリアを wrap する overlay に繋がる)。
  final KoEffectController _koEffect = KoEffectController();

  /// 🔴 **KO 演出の状態は battle_page のローカル state に置く。**
  ///
  /// `BattleSession` などの共有 state に置くと、**アンビエントバトル
  /// (ホーム額縁) の終了処理まで待たされて止まる** —— 額縁側は KO 演出を
  /// 描画しないのでフラグが永久に立たず、報酬処理も次の戦闘も始まらない。
  /// しかも「静かに止まる」ので気付きにくい (指示書 Pre-mortem #2)。
  ///
  /// **このページが自分で開始した演出**が再生中かどうか、だけを持つ。
  bool _koPlaying = false;

  /// すでに演出を発火した `KoEvent` (二重発火防止)。
  ///
  /// `koEvent` は勝利後もクリアされないので、session が動くたびに
  /// `_maybeFireKo` が呼ばれる。同じイベントで 2 回目を撃たないための記録。
  KoEvent? _firedKoEvent;

  /// KO 演出のゲートが開いているか (= 敵の fadeOut と報酬モーダルを許すか)。
  ///
  /// 🔴 **「koEvent があるかどうか」で判定してはいけない**
  /// (2026-08-22 実機報告)。`battleSessionProvider` は autoDispose ではないので、
  /// **前のバトルの決着済み state がそのまま残っている**ことがある。
  /// それを見て閉じると、次のバトルに入った瞬間に「もう終わっている他人の KO」を
  /// 待つことになり、敵が消えず報酬モーダルも出ない。
  ///
  /// 閉じるのは **自分が今まさに演出を再生している間だけ**。
  bool get _koGateOpen => !_koPlaying;

  /// KO 演出を 1 回だけ発火する。
  ///
  /// overlay が居なくて再生できなかったときは **その場でゲートを開ける**。
  /// 演出のために本編 (撃破 → 報酬) を止めてはいけない。
  void _maybeFireKo(BattleState? state) {
    if (!mounted || state == null) return;
    final event = state.koEvent;
    if (event == null || event == _firedKoEvent) return;
    _firedKoEvent = event;

    final started = _koEffect.fire(speedMultiplier: state.speedMultiplier);
    if (!started) return; // ゲートは元から開いている (閉じるのは再生中だけ)
    setState(() => _koPlaying = true);
    // ハプティクスは視覚演出と同フレームで打つ (fire-and-forget)。
    // 専用 SE は本 FEAT のスコープ外なので、**手応えはここで補う**。
    //
    // 【2026-08-22】`playUltimateHit` (「強く当たった」= 減衰する余韻) から
    // `playKoFinish` (「勝った」=「一撃 → 間 → 祝祭」) に差し替えた。
    BattleHapticsService.instance.playKoFinish();
  }

  /// KO 演出が終わった → 敵の fadeOut と報酬モーダルを解禁する。
  void _onKoFinished() {
    if (!mounted || !_koPlaying) return;
    setState(() => _koPlaying = false);
    // 🔴 `ref.listen` は **state が動いたときにしか走らない**。
    // 演出中に `finishCompleted` が true になっていた場合、ゲートが開いた
    // 本メソッド側で再評価しないと **モーダルが永久に出ない**。
    _maybeShowBattleEnd(ref.read(battleSessionProvider));
  }

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

      // 🔴 **ここで `_maybeFireKo` を呼んではいけない** (2026-08-22 実機報告)。
      //
      // 旧実装は「mount 時点で既に決着していた state を拾う」ために呼んでいたが、
      // `battleSessionProvider` は autoDispose ではないので、ここで読める state は
      // **たいてい前のバトルの決着済み state** である。しかも `startBattle()` は
      // await されておらず、session のリセットは API 往復の後なので、直後に読むと
      // 確実に古い state が返る。
      //
      // 結果、アンビエント (ホーム額縁) で勝った直後にギルドからバトルを始めると
      // **前のバトルの KO 演出が流れてから新しいバトルが始まる**という症状になった。
      // KO の発火は `ref.listen` の遷移検知だけに任せる。

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
        // 🔴 【FEAT-526 / 2026-08-22 実機報告】**必殺技がとどめだったときは
        // 視覚もハプティクスも出さない。**
        //
        // 撃墜エフェクトは全画面に **白フラッシュ (alpha 0.6 / 350ms)** を掛ける。
        // KO 演出はその裏で ヒットストップ → ズーム → 「K.O.」と進むので、
        // **前半がまるごと白飛びする**。3 倍速では KO 演出 (約 230ms) が
        // フラッシュ (350ms、倍速非追従) に**完全に飲み込まれて一度も見えない**。
        //
        // 額縁に撃墜エフェクトが無いのはこのためで、
        // 「額縁では KO が見えるのに全画面では見えない」の正体でもある。
        //
        // ハプティクス側は FEAT-526 で既に同じ判断をしていた
        // (`koFinish` の先頭に強い一撃が入っており、重ねると濁るだけ)。
        // **視覚に同じガードを掛け忘れていた**のがこの不具合である。
        if (next.state?.status == BattleStatus.won) return;

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

    // 【FEAT-526】KO 演出の発火。
    //
    // 【Pre-mortem #6】オートバトルの連戦でゲートを閉じ直す処理は要らない ——
    // ゲートは「再生中だけ閉じる」ので、演出が終わった時点で自動的に開き、
    // 次のバトルのとどめでまた閉じる。**前バトルのフラグが残る余地が無い。**
    ref.listen<BattleSession>(battleSessionProvider, (prev, next) {
      _maybeFireKo(next.state);
    });

    // 戦闘終了検知 → モーダル表示 + ホーム戻り（caller-decides-navigation）
    ref.listen<BattleSession>(battleSessionProvider, (prev, next) {
      _maybeShowBattleEnd(next);
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
          // 【FEAT-526】KO 演出は **戦闘エリアだけ** を wrap する。
          // 画面全体を wrap すると下半分のログ / 作戦パネルまで拡大されて
          // レイアウトが崩れる (`UltimateHitEffectOverlay` は画面シェイクだけ
          // なので全画面 wrap でよいが、ズームは事情が違う)。
          child: KoEffectOverlay(
            controller: _koEffect,
            onFinished: _onKoFinished,
            child: Stack(
              // 【2026-08-08 ユーザー要望】対峙ブロックをバトルエリアの中央高さへ下げる。
              //
              // MiniBattleArena と**同一の原因**。Stack の既定 alignment は
              // `AlignmentDirectional.topStart` で、非 Positioned な子 (下の
              // `Padding` > `Row`) は**上端に貼り付く**。`Expanded(flex: 6)` から
              // tight 制約を受けて Stack はエリアいっぱいに広がる一方、中身の
              // `_CombatantPanel` は `MainAxisSize.min` なので余白が全部下に落ちていた。
              //
              // なお `_CombatantPanel` の `mainAxisAlignment: center` は
              // **min サイズの Column には効かない** (分配する余白が無い) ため、
              // 「中央寄せは指定済み」に見えて実際は効いていなかった。
              //
              // `Positioned` な子 (背景 / 暗幕) は alignment の影響を受けない。
              alignment: Alignment.center,
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
                          // 【FEAT-526】🔴 `status == won` **ではなく**
                          // 「KO 演出が終わった」で判定する。旧実装は死んだ瞬間に
                          // 500ms かけて消え始めていたので、**ズームする対象が
                          // 残らなかった**。ここを遅らせるのが本 FEAT の中核。
                          action: (state.status == BattleStatus.won &&
                                  _koGateOpen)
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
                          // 【FEAT-527】味方側だけ攻撃フレームを再生する。
                          // 素材を持たないキャラは CombatantSprite 側で
                          // 従来の Transform 演出にフォールバックする。
                          enableMotion: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
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

  /// 戦闘終了モーダルを出してよいか判定して、出す。
  ///
  /// **2 箇所から呼ばれる**:
  ///   1. `ref.listen` (session の state が動いたとき)
  ///   2. `_onKoFinished` (KO 演出が終わってゲートが開いたとき)
  ///
  /// 🔴 2 が要る理由: `ref.listen` は session が動いたときにしか走らない。
  /// `_sendFinish` は `status = won` の時点で即発火するので、**API が
  /// 300ms で返れば `finishCompleted` は演出の途中で true になる**。その通知を
  /// ゲートで弾いた後、ゲートが開いた側から再評価しないとモーダルが永久に出ない。
  /// ローカルの速い backend ほど再現しやすく、本番で初めて直るように見える
  /// 種類のバグなので、経路を 2 本明示しておく (指示書 Pre-mortem #1)。
  void _maybeShowBattleEnd(BattleSession session) {
    final state = session.state;
    if (state == null) return;
    final status = state.status;
    // 【FEAT-296 hotfix 2026-05-24】_sendFinish の API 応答完了
    // （finishCompleted = true）を待ってからモーダル発火。
    // 旧実装は status == won/lost だけで即発火していたため、
    // rewardCoinsGained = 0 のまま「+0 coins / +0 EXP」表示される
    // バグがあった。Backend 失敗時も catch 経路で finishCompleted
    // = true に設定されるためフリーズしない設計。
    if (status != BattleStatus.won && status != BattleStatus.lost) return;
    if (!session.finishCompleted) return;
    // 【FEAT-526】KO 演出が終わるまでモーダルを出さない。
    // 敗北時は KO 演出そのものが無い (`koEvent` を立てない) ので再生されず、
    // ゲートは常に開いている = 従来どおり即座に出る。
    if (!_koGateOpen) return;
    // 【FEAT-297 Pre-mortem #3】BattlePage と WorldFrameSection の二重発火を防ぐため、
    // `markModalShown()` で「最初の listener が独占的に true を取りに行く」設計。
    // 既に true ならスキップ（他で発火済）。
    final won = ref.read(battleSessionProvider.notifier).markModalShown();
    if (!won) return; // 他で発火済 → BattlePage 側はスキップ
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _handleBattleEnd(status, session);
    });
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
    this.enableMotion = false,
  });

  final Combatant combatant;
  final double spriteSize;
  final bool flipHorizontal;
  final AttackDirection attackDirection;
  final SpriteAction action;
  final DamageEvent? damageEvent;

  /// 【FEAT-403 (2026-06-01)】敵側 (ボス) パネルは ATB 表示を廃止し HP 全幅化。
  final bool isEnemy;

  /// 【FEAT-527】攻撃フレームの再生を許可する。**味方側のみ true**。
  /// 敵側の素材は未着手 (味方が固まってから着手する方針)。
  final bool enableMotion;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      // 【2026-08-08】`MainAxisSize.min` との組み合わせなので、この
      // `mainAxisAlignment` は**実質効いていない** (分配する余白が無い)。
      // 縦位置は呼び出し元 `_buildBattleArena` の `Stack(alignment: center)` が
      // 決めている。`MainAxisSize.max` に変えるときだけ意味を持つので残置。
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
                enableMotion: enableMotion,
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
/// 2. `battleSpeedPreferenceProvider.setSpeed` で永続化（次回バトル開始時に restore）
///
/// 【FEAT-528】表示側 (`isSelected`) は変更しない。**バトル中は
/// `battleSessionProvider.state.speedMultiplier` が実際に走っている値**であり、
/// そちらが真実値（永続設定はまだ次のバトルの話でしかない）。
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
        // 🔴 【FEAT-528】直接 prefs.setDouble を書かない。
        // 書き手が 2 つあると BUG-79 と同型の「二重の真実値」に戻る
        // (「1x をハイライトしているのに実速度は 3x」)。永続化は notifier に一本化。
        ref.read(battleSpeedPreferenceProvider.notifier).setSpeed(value);
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

