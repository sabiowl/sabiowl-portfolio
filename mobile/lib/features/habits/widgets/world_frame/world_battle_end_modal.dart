import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../battle/dialogs/post_battle_rewards.dart';           // 【gameplay_review 20260803 §2-2 a】
import '../../../battle/providers/battle_provider.dart';             // FEAT-297 (BattleSession)

// ─────────────────────────────────────────────────────────────────────────────
// showWorldBattleEndModal — 戦闘終了時のモーダル表示 (ホーム経路)
// ─────────────────────────────────────────────────────────────────────────────

/// 【FEAT-297 Pre-mortem #3】戦闘終了モーダル発火（ホーム経路）。
///
/// BattlePage と同じパターンで「dialog 内は Navigator.pop のみ / caller-decides-
/// navigation」。caller (ホーム) では既に /home にいるため、モーダル閉じた後の
/// 追加遷移は不要（context.go は呼ばない）。
///
/// 【FEAT-487 (2026-07-08)】旧 `_WorldFrameSectionState._showBattleEndModal` から
/// 分離。呼出元 (WorldFrameListeners 経由の battleSessionProvider ref.listen) は
/// `mounted` チェック済のため、本関数内では追加の mounted チェックは不要
/// (context の validity は caller 側で担保)。ただし defense-in-depth として
/// `context.mounted` の一次チェックのみ残す。
Future<void> showWorldBattleEndModal(
  BuildContext context,
  bool isWin,
  BattleSession session,
) async {
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppTheme.card,
      title: Text(
        isWin ? l10n.habitWorldBattleWinTitle : l10n.habitWorldBattleLoseTitle,
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
      content: Text(
        isWin
            ? l10n.habitWorldBattleWinReward(session.rewardCoinsGained, session.rewardExpGained)
                + (session.leveledUp ? '\n${l10n.habitWorldBattleWinLevelUp(session.newLevel ?? 0)}' : '')
            : l10n.habitWorldBattleLoseSabi_message,
        style: const TextStyle(
          color: Colors.white70, fontSize: 14, height: 1.5,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.habitWorldBattleCloseButton),
        ),
      ],
    ),
  );
  // ホーム経路はそのまま /home に留まる（追加遷移なし、CLAUDE.md 準拠）
  //
  // 【gameplay_review 20260803 §2-2 a】旧実装はここで first-diamond トーストだけを、
  // しかも BattlePage とは別の文言 key で出していた。結果、FEAT-513 でホームが
  // 主戦場になった後も **武器ドロップ (10%) と熟練度 Max がホーム経路では無音**
  // だった。BattlePage と共通の `showPostBattleRewards` に一本化する。
  if (!context.mounted) return;
  await showPostBattleRewards(context, session);
}
