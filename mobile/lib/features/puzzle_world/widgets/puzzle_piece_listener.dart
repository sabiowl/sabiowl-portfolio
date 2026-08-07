import 'package:flutter/material.dart';
import 'package:flutter/services.dart';  // 【gameplay_review 20260708】HapticFeedback
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/popup_serializer.dart';
import '../models/puzzle_world.dart';
import '../providers/puzzle_world_provider.dart';
import 'puzzle_completion_modal.dart';
import 'puzzle_piece_overlay_modal.dart';

/// 【FEAT-479 Phase 3 (2026-07-06) → v1 hotfix 2026-07-07 → global hotfix 2026-07-07】
/// Puzzle piece 演出発火 listener。
///
/// `puzzlePieceAwardedProvider` / `puzzlePieceColoredProvider` の変化を watch し、
/// non-null 値が set された瞬間に overlay モーダルを起動する。
///
/// **配置 (global hotfix 2026-07-07)**: `main.dart` の `MaterialApp.router.builder`
/// 内、`MaintenanceOverlay` の子として配置する **wrapper widget**。
/// 旧配置 (home_body.dart の Positioned) では、user が Guild / Timeline / Battle
/// 等のホーム外画面にいる時に `ref.listen` が edge-triggered で状態変化を
/// 検知できず、quest piece 演出が発火しない bug があった:
///
/// ```
/// 旧: [home_body.dart:88 Positioned(PuzzlePieceListener())]
///     - ホーム以外の画面 (Guild / Timeline / Calendar / Battle) では非 mount
///     - Battle 終了時に puzzlePieceColoredProvider に set しても listener が
///       登録されていない → 演出発火せず = 「クエスト達成で何も起きない」bug
///
/// 新: main.dart の builder 内で常時 mount
///     - どの画面にいても状態変化を確実に検知
///     - showGeneralDialog は useRootNavigator: true で root Navigator に描画
///       (画面遷移中でも overlay が正しく表示される)
/// ```
///
/// **設計方針**:
/// - `PopupSerializer` 経由で他 popup (LoginBonus / FriendGift 等) との直列化 (BUG-138 系対策)
/// - **【v1 hotfix 2026-07-07】演出リズム制御**: PopupSerializer.enqueue 内の task
///   先頭で [_kOverlayShowDelay] (2 秒) 待機し、RewardToast (1.7s) を先に完全表示させる。
///   旧挙動では task listener が同フレームで enqueue → PopupSerializer をロック
///   → RewardToast が次フレームで発火してもすでに overlay に隠される
///   → 「タスク達成 → 5秒沈黙 → いきなり piece overlay」体感 bug。
///   task 内 delay で queue 順序 (piece → LoginBonus) は保持しつつ、EXP 演出の
///   時間帯を確保する。
/// - Task 発火 → 完了 → 300ms 待機 → provider null リセット → 状態更新 (invalidate)
///   の順で処理し、Quest が続いていれば 次サイクルで検出 → 起動 (自動連続表示)
/// - completion (scene_completed=true) は Phase 4 で追加モーダル起動を実装、
///   本 listener は quest overlay 完了後に puzzleWorldStatusProvider を invalidate するだけ
///
/// **【v1 hotfix】期待フロー**:
/// ```
/// t=0.0s: タスクタップ (Backend API 応答後)
///          → RewardToast (+X EXP) 表示開始 (次フレーム、addPostFrameCallback)
///          → PuzzlePieceListener が PopupSerializer.enqueue で task 登録 (同フレーム)
///          → task 内で 2 秒 delay 開始
/// t=1.7s: RewardToast 自動消滅 (OverlayEntry の Future.delayed で remove)
/// t=2.0s: piece overlay 表示 (showPuzzlePieceTaskOverlay 発火)
///          → ユーザー確認 → X で close
/// t=Nsec: LoginBonus dialog 表示 (PopupSerializer 直列で piece の後)
/// ```
///
/// [_kOverlayShowDelay] は RewardToast の 1.7 秒 + マージン 0.3s を確保。
class PuzzlePieceListener extends ConsumerStatefulWidget {
  /// 【global hotfix 2026-07-07】wrapper 化に伴い child を受け取る。
  /// build 内で listener を登録した上で child を素通しで返す。
  const PuzzlePieceListener({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<PuzzlePieceListener> createState() =>
      _PuzzlePieceListenerState();
}

class _PuzzlePieceListenerState extends ConsumerState<PuzzlePieceListener> {
  bool _handling = false;

  /// 【v1 hotfix 2026-07-07】piece overlay 表示前の待機時間。
  ///
  /// - RewardToast (home_listeners.dart:207 の `_showRewardToast`) の
  ///   表示時間 1700ms + マージン 300ms = 2000ms。
  /// - Task 達成 → EXP toast (1.7s) → piece overlay (2.0s 以降) の演出リズムを
  ///   確保する。任意のフィードバックを先に処理させて視認性を保つ。
  /// - 変更する場合は RewardToast の `Future.delayed(const Duration(milliseconds: 1700))`
  ///   と連動して調整すること (home_listeners.dart)。
  static const Duration _kOverlayShowDelay = Duration(seconds: 2);

  @override
  Widget build(BuildContext context) {
    // Task piece
    ref.listen<PuzzlePieceAwarded?>(puzzlePieceAwardedProvider, (prev, next) {
      if (next == null || _handling) return;
      _handleTask(next);
    });
    // Quest piece
    ref.listen<PuzzlePieceColored?>(puzzlePieceColoredProvider, (prev, next) {
      if (next == null || _handling) return;
      _handleQuest(next);
    });
    // 【global hotfix 2026-07-07】wrapper 化: SizedBox.shrink 廃止、child 素通し。
    // これで main.dart の builder に挿入するだけで全画面で listener が有効化される。
    return widget.child;
  }

  Future<void> _handleTask(PuzzlePieceAwarded piece) async {
    _handling = true;
    try {
      final status = ref.read(puzzleWorldStatusProvider).valueOrNull;
      final active = status?.activeScene;
      // 演出前 piece_states = active の現状 (piece_index のマスは 0 = 未取得の想定)
      final pieceStates = active?.pieceStates ?? List<int>.filled(30, 0);
      final sceneName = active?.scene.name ?? '';
      // 【2026-07-09】popup 内に scene 背景画像を切り抜き描画するため backgroundKey を渡す。
      // active が null (edge case) の場合は null 経由で popup 側 fallback (抽象色) が発動。
      final backgroundKey = active?.scene.backgroundKey;

      await PopupSerializer.enqueue(() async {
        // 【v1 hotfix 2026-07-07】RewardToast (1.7s) を先に完全表示させるため
        // 2 秒待機してから piece overlay を出す。task_listener が同フレームで
        // enqueue し PopupSerializer をロックする挙動は保持しつつ、演出リズム
        // (task 達成 → EXP toast → 2s 後に piece overlay) を実現。
        await Future.delayed(_kOverlayShowDelay);
        if (!mounted) return;
        // 【gameplay_review 20260708】かけら取得の触覚 FB (軽い一振動)。
        // 「輪郭のかけら」= 輪郭が現れる控えめな瞬間、lightImpact で軽く鳴らす。
        // バトル攻撃の playNormalHit (15ms/振幅80) と同じ強度感。
        HapticFeedback.lightImpact();
        await showPuzzlePieceTaskOverlay(
          context,
          pieceStates: pieceStates,
          pieceIndex: piece.pieceIndex,
          sceneName: sceneName,
          backgroundKey: backgroundKey,
        );
        // モーダル dispose 完了待ち (Material transition 150ms + マージン)
        await Future.delayed(puzzleOverlayDismissBuffer);
      });
    } finally {
      if (mounted) {
        // provider をリセット + status invalidate で 30 マス最新化
        ref.read(puzzlePieceAwardedProvider.notifier).state = null;
        ref.invalidate(puzzleWorldStatusProvider);
      }
      _handling = false;
    }
  }

  Future<void> _handleQuest(PuzzlePieceColored piece) async {
    _handling = true;
    try {
      final status = ref.read(puzzleWorldStatusProvider).valueOrNull;
      final active = status?.activeScene;
      // 演出前 piece_states = active の現状 (piece_index のマスは 1 = grey の想定)
      final pieceStates = active?.pieceStates ?? List<int>.filled(30, 0);
      final sceneName = active?.scene.name ?? '';
      // 【2026-07-09】task 経路と同じ、popup 内に scene 背景を切り抜き描画するため。
      final backgroundKey = active?.scene.backgroundKey;

      await PopupSerializer.enqueue(() async {
        // 【v1 hotfix 2026-07-07】task 経路と同様、RewardToast (バトル勝利報酬)
        // を先に見せるため 2 秒待機。バトルは戦闘終了 → 勝利モーダル → piece
        // の流れで、間に勝利モーダルが挟まる場合はそちらが優先表示されるが、
        // 直接遷移経路 (勝利モーダル無し) でも RewardToast との重なりを回避。
        await Future.delayed(_kOverlayShowDelay);
        if (!mounted) return;
        // 【gameplay_review 20260708】かけら彩色の触覚 FB (やや長め)。
        // 「彩りのかけら」= 灰色から色付きへの遷移という「上位段階」の瞬間、
        // task piece (light) より 1 段強い mediumImpact で差別化する。
        // バトル攻撃の playCriticalHit (60ms/振幅200) と同じ強度感。
        HapticFeedback.mediumImpact();
        await showPuzzlePieceQuestOverlay(
          context,
          pieceStates: pieceStates,
          pieceIndex: piece.pieceIndex,
          sceneName: sceneName,
          backgroundKey: backgroundKey,
        );
        await Future.delayed(puzzleOverlayDismissBuffer);
      });

      // 【FEAT-479 Phase 4 (2026-07-06)】scene_completed=true のときは完成モーダルを
      // 追加で起動。1.5 秒静止 → 白フェード発光 → 中央モーダル + 「見守る」ボタン
      // → next_scene_hint あれば SceneSelectionPage 遷移。
      // (WorldAnimatedLayers 完成時起動連携は Phase 4c で別途対応、指示書 S4)
      if (piece.sceneCompleted) {
        await _handleSceneCompletion(piece, sceneName);
      }
    } finally {
      if (mounted) {
        ref.read(puzzlePieceColoredProvider.notifier).state = null;
        ref.invalidate(puzzleWorldStatusProvider);
      }
      _handling = false;
    }
  }

  /// 【Phase 4】完成モーダル発火 + 次シーン誘導フロー (指示書 §3.6 完成後の遷移フロー)。
  ///
  /// 1. 1.5 秒静止 (quest overlay dispose 完了後、余韻を残す)
  /// 2. PopupSerializer.enqueue で完成モーダル (白フェード + 中央モーダル)
  /// 3. ユーザーが「見守る」タップ → モーダル閉じる
  /// 4. 300ms buffer (BUG-65 遵守、dispose 完了待機)
  /// 5. next_scene_hint あれば SceneSelectionPage 遷移 (未着手シーンが残っている)
  ///    next_scene_hint なし → エンドコンテンツ、ホームに留まる (全 3 シーン完成)
  Future<void> _handleSceneCompletion(
    PuzzlePieceColored piece,
    String sceneName,
  ) async {
    // 1. 1.5 秒静止 (指示書 §4.3.3 の 1.5 秒静止に相当)
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;

    // 2. 完成モーダル起動
    final hasNextScene = piece.nextSceneHint != null;
    await PopupSerializer.enqueue(() async {
      if (!mounted) return;
      // 【gameplay_review 20260708】シーン完成の触覚 FB (強めの一撃)。
      // 「景色が復元される」祝祭的瞬間、task/quest より明確に強い heavyImpact。
      // task=light / quest=medium / completion=heavy の 3 段階強度分離で
      // 「積み重ね → 開花 → 完成」のリズムを触覚でも表現する。
      HapticFeedback.heavyImpact();
      await showPuzzleCompletionOverlay(
        context,
        sceneName: sceneName,
        rewardExp: piece.rewardExp ?? 0,
        rewardDiamonds: piece.rewardDiamonds ?? 0,
        hasNextScene: hasNextScene,
        nextSceneName: piece.nextSceneHint?.name,
      );
      // 3. dispose 完了待機 (Material transition + マージン)
      await Future.delayed(puzzleOverlayDismissBuffer);
    });

    // 4. next_scene_hint あれば SceneSelectionPage 遷移
    // (未着手シーンが残っている → 次に救う世界を選んでもらう動線)
    if (!mounted) return;
    if (hasNextScene) {
      context.push(AppRoutes.puzzleWorld);
    }
    // hasNextScene=false: エンドコンテンツ (全 3 シーン完成)、ホーム留まる。
    // 完成した世界の余韻をホーム画面 (WorldFrameSection) で味わう時間になる。
  }
}
