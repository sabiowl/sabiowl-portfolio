import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../battle/models/battle_state.dart';                   // FEAT-297
import '../../../battle/providers/battle_provider.dart';             // FEAT-297
import '../../../battle/services/ambient_auto_battle_orchestrator.dart';  // 【gameplay_review 20260803 §2-2 d】
import '../../providers/completion_effect_provider.dart';
import 'world_battle_end_modal.dart';

// ─────────────────────────────────────────────────────────────────────────────
// WorldFrameListeners — WorldFrame 系 ref.listen を集約する listener-only widget
// ─────────────────────────────────────────────────────────────────────────────

/// 【FEAT-487 (2026-07-08)】WorldFrameSection の ref.listen 集約 widget。
///
/// FEAT-452 (`FriendGiftPopupListener`) / FEAT-458 (`AnnouncementPopupListener`)
/// / FEAT-473 (`HomeListeners`) で確立した「listener-only widget pattern」を
/// WorldFrameSection にも適用する。旧 `_WorldFrameSectionState.build` 内に
/// 直書きされていた以下の side effect を本 widget に集約:
///
/// 1. `worldFrameGlowProvider` 監視 → 親 `WorldFrameSection` の
///    `_glowCtrl.forward(from: 0)` を呼び出し (state-specific なため
///    `onGlowTriggered` callback で親に委譲)。
/// 2. `battleSessionProvider` 監視 → 以下 2 系統を発火:
///    - 日次出陣上限到達 (`daily_battle_limit_reached:` prefix errorMessage)
///      → `AlertDialog` (Sabi 口調 わかりました 単一ボタン)
///    - 戦闘終了 (won/lost) → `showWorldBattleEndModal` (`markModalShown()` で
///      BattlePage と の 二重発火防止、Pre-mortem #3)
/// 3. `pendingEnemyKey != null && !isBattleRunning` → auto `startBattle()`
///    (FEAT-297 Phase 3 + FEAT-325 バグ修正、ギルド→ホーム遷移時の自動戦闘開始)
///
/// FEAT-452 の `FriendGiftPopupListener` は `SizedBox.shrink()` を返す設計だが、
/// 本 widget は Stack 内の実体ではなく AnimatedBuilder ラッパー配置のため、
/// `child` をラップする設計 (FEAT-473 `HomeListeners` パターン踏襲)。
///
/// **Pre-mortem #4 対応**: 本 widget が発火する `ref.listen` は WorldFrameSection
/// 側からは全て削除する。親 widget の `build` 内で **grep で `ref.listen` が
/// 0 件になる** ことで二重発火を構造的に排除。
class WorldFrameListeners extends ConsumerStatefulWidget {
  const WorldFrameListeners({
    required this.child,
    required this.onGlowTriggered,
    super.key,
  });

  final Widget child;

  /// `worldFrameGlowProvider` が true に転じた瞬間に呼ばれるコールバック。
  /// 呼出元 (`WorldFrameSection`) は `_glowCtrl.forward(from: 0)` を実行する。
  /// State-specific な `AnimationController` に触れる必要があるため callback で
  /// 親に委譲する (prop drilling を最小化するための切り出し方針、Pre-mortem #1)。
  final VoidCallback onGlowTriggered;

  @override
  ConsumerState<WorldFrameListeners> createState() =>
      _WorldFrameListenersState();
}

class _WorldFrameListenersState extends ConsumerState<WorldFrameListeners> {
  @override
  Widget build(BuildContext context) {
    // ── グロウトリガーを監視 ─────────────────────────────────────────────────
    ref.listen<bool>(worldFrameGlowProvider, (_, shouldGlow) {
      if (shouldGlow && mounted) {
        widget.onGlowTriggered();
      }
    });

    // 【FEAT-297 Phase 3】ギルド画面で `selectEnemyForNextBattle(...)` 経由で予約された
    // pending enemyKey を検出 → ホームに戻ってきたタイミングで自動 startBattle。
    // 設計: WorldFrameSection はホーム画面常駐のため、ギルド画面 → ホーム遷移 (context.go)
    // 直後の build で必ず通る → ここで pending を検出すれば確実に発火する。
    //
    // 【FEAT-325 (2026-05-27) バグ修正】旧実装は `!notifier.hasActiveSession` で
    // 多重起動防止していたが、`hasActiveSession` は終了済 (won/lost) でも true を
    // 返す (FEAT-296 で autoDispose 外し、_orchestrator が残存)。結果、2 戦目以降:
    //   - 1 戦目 終了 → _orchestrator 残存 (status=won/lost)
    //   - ギルドで slime 再選択 → pendingEnemyKey='slime' セット
    //   - context.go(home) → WorldFrameSection rebuild
    //   - pendingEnemyKey != null ✅ かつ hasActiveSession=true ❌ で発火しない
    //   - → 「戦闘が開始されない」ユーザー体験バグ
    // 修正: `isBattleRunning` (running 中のみ true) を新規追加し、終了済を
    // 「新規開始の障害物にしない」契約を担保。startBattle() 内部に「終了済なら破棄
    // して新規開始」ロジック完備のため、running でなければ呼んで OK。
    //
    // 【FEAT-487】旧 WorldFrameSection.build 内 inline block から移行。build 中の
    // 発火はリスクがあるため postFrame に逃がす経路も維持 (Riverpod 内部 state
    // 変更が build 連鎖を引き起こすのを回避)。
    // ここで `ref.watch(battleSessionProvider)` を呼ぶと build 連鎖が発生するため、
    // 従前どおり `ref.read` で notifier を取得する。
    final notifier = ref.read(battleSessionProvider.notifier);
    if (notifier.pendingEnemyKey != null && !notifier.isBattleRunning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        notifier.startBattle();
      });
    }

    // 【FEAT-297 Pre-mortem #3】戦闘終了 → モーダル発火（BattlePage と同パターン）。
    // `markModalShown()` で「最初の listener が独占的に true を取りに行く」設計。
    // BattlePage が同時に開いていれば BattlePage 側が発火、ホーム画面のみなら
    // ここで発火する（どちらが先かは Riverpod の listener 順序 = build 順）。
    ref.listen<BattleSession>(battleSessionProvider, (prev, next) {
      if (!mounted) return;

      // 【FEAT-398】日次出陣上限到達 → Sabi 口調 Dialog
      final errMsg = next.errorMessage;
      if (errMsg != null && errMsg.startsWith('daily_battle_limit_reached:')) {
        final message = errMsg.substring('daily_battle_limit_reached:'.length);
        // errorMessage をクリア (再発火防止)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(battleSessionProvider.notifier).clearBattleError();
          showDialog<void>(
            context: context,
            builder: (dialogContext) {
              final l10n = AppLocalizations.of(context)!;
              return AlertDialog(
                backgroundColor: const Color(0xFF2A2A3E),
                title: Text(
                  l10n.habitWorldBattleLimitTitle,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                content: Text(
                  message,
                  style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.6),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: Text(l10n.habitWorldBattleLimitConfirmButton),
                  ),
                ],
              );
            },
          );
        });
        return;
      }

      if (next.state == null) return;
      final status = next.state!.status;
      if ((status == BattleStatus.won || status == BattleStatus.lost)
          && next.finishCompleted) {
        // 【gameplay_review 20260803 §2-2 d】ambient auto battle の queue 実行中は
        // per-battle モーダルを出さない。
        //
        // FEAT-513 の Pre-mortem S7 は「通知は subtle indicator、SnackBar は勝敗の
        // transition 時 1 回のみ (**連続勝利中は表示しない**)」と自ら決めていたが、
        // 実装は FEAT-297 の既存経路をそのまま通るため 1 戦ごとに
        // `barrierDismissible: false` のダイアログが出ていた。オーケストレータは
        // status 変化の 2 秒後に次戦を開始するので、**ユーザーが「閉じる」を押す前に
        // 2 戦目が始まっている**。「ながら見できる自動戦闘」を作りながら 1 戦ごとに
        // タップを要求してブロックしていた。
        //
        // 敗北も同じく抑止する。抑止しないと `showWorldBattleEndModal` (lose) の
        // 直後に `AmbientBattleDefeatDialog` が続き、**1 回の敗北にサビが 2 回
        // 慰めてくる**状態になる (要素 C-2)。敗北は敗北 dialog に一本化する。
        //
        // 戦果は queue 終了時に `AmbientBattleState.summary` として 1 回だけ通知する
        // (HomePage が消化)。`markModalShown()` の**前**に return することが重要:
        // ここで排他ロックを取ってしまうと、user が自分でワールドフレームを tap して
        // BattlePage を開いているケースで BattlePage 側のモーダルまで消える。
        if (ref.read(ambientAutoBattleProvider).isRunning) return;

        final won = ref
            .read(battleSessionProvider.notifier)
            .markModalShown();
        if (!won) return; // 他で発火済 → スキップ
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          showWorldBattleEndModal(context, status == BattleStatus.won, next);
        });
      }
    });

    return widget.child;
  }
}
