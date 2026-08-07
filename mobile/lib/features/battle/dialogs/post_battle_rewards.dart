import 'package:flutter/material.dart';

import '../../../core/services/toast_center.dart';
import '../../../l10n/app_localizations.dart';
import '../../gamification/widgets/job_mastery_maxed_dialog.dart';  // 【FEAT-511 Phase A】
import '../providers/battle_provider.dart' show BattleSession;

/// 【gameplay_review 20260803 §2-2 a】戦闘終了モーダルの「後」に出す報酬演出を
/// **1 箇所に集約**する。
///
/// ## なぜ集約するか
///
/// 旧実装では BattlePage (`_handleBattleEnd`) だけがこの 3 つを出していた:
///
///   1. 木製武器ドロップ トースト (FEAT-443、10%)
///   2. その日初勝利の +5 ダイヤ トースト (FEAT-314)
///   3. ジョブ熟練度 Max 到達 dialog (FEAT-511 Phase A)
///
/// 一方ホーム経路 (`showWorldBattleEndModal`) は 2 だけを、しかも別の文言 key で
/// 出していた。FEAT-513 Ambient Auto Battle が **ホームを主戦場に格上げ**した結果、
/// 「主経路で戦い続けた人には武器ドロップも Max 到達も一切通知されない」状態に
/// なっていた (10% のドロップが常に無音 / 157 戦の果ての Max が無音)。
///
/// 「戦闘後に何を見せるか」を 2 箇所に別々の順序で書いている限り同じ漏れが再発するので、
/// 本関数を唯一の定義とし、BattlePage / ホーム経路の双方から呼ぶ。
///
/// ## 呼び出し規約
///
/// - **戦闘終了モーダルを閉じた後**に呼ぶ (モーダルと重ねない)。
/// - `await` すること。Max dialog を挟むため完了まで数百 ms 以上かかる。
/// - 呼出後に navigation する場合は本関数の await 完了後に行う
///   (CLAUDE.md「caller-decides-navigation」)。
Future<void> showPostBattleRewards(
  BuildContext context,
  BattleSession session,
) async {
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context)!;

  // 【FEAT-443 (2026-06-20)】10% 確率の木製武器ドロップ。
  // battleFirstDiamond より先に発火 (武器入手の方が体感的にハイライト性が高い)。
  final drop = session.weaponDropped;
  if (drop != null) {
    ToastCenter.showSuccess(
      l10n.battlePageWeaponDropToastSabi_message(drop.weaponName),
    );
  }

  // 【FEAT-314】その日初の勝利で +5 ダイヤ。ToastCenter は ScaffoldMessengerKey
  // 経由なので画面遷移と独立して届く。
  if (session.battleFirstDiamond) {
    ToastCenter.showSuccess(l10n.battlePageFirstVictoryDiamondSabi_message);
  }

  // 【FEAT-511 Phase A (2026-07-30)】ジョブ熟練度 Max 到達。トーストより後に出し、
  // 「積み重ねの実感」を静かに伝える。
  final maxedJobName = session.jobMasteryMaxedJobName;
  if (maxedJobName == null) return;
  await Future.delayed(const Duration(milliseconds: 300));
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => JobMasteryMaxedDialog(jobName: maxedJobName),
  );
  if (!context.mounted) return;
  await Future.delayed(const Duration(milliseconds: 300));
}
