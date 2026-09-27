import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';

/// 【FEAT-513】Ambient Auto Battle の敗北通知 dialog。
///
/// 🔴 **【BUG-148 (2026-08-24)】ボタンを「閉じる」1 つに畳んだ。**
///
/// 旧実装は「休む」(左) と「続ける」(右) の 2 択だったが、どちらも実質
/// 機能していなかった:
///
/// - **「休む」を押しても休めない。** 回数が残っているので次にホームへ来た
///   時点で自動的に再開する。「続ける」との差は *今すぐ* 再開するか
///   *次にホームへ来たとき* 再開するかだけで、ユーザーには区別が付かない
///   (実機報告「『休む』は何のためにありますか?」)。
/// - **「続ける」は仕様どおりに動いていなかった。** FEAT-513 Q7 は
///   「続ける → 次の敵に進む」と決めていたが、実装は
///   `maybeStartAutoBattle()` を呼び直すだけで、キューを先頭から読み直す。
///   tier 降順ソートなので **いま負けた同じ敵に戻り、ほぼ確実にまた負ける**。
///
/// 本当に「次の敵に進む」を実装すると、それは「**この敵は諦める**」=
/// 残り回数の破棄であって「続ける」とは別の操作になる。必要なら v1.2 で
/// 独立に設計する。
///
/// 🔵 **BUG-138 (左 = Cancel / 右 = Action) はボタンが 2 つ以上のときの規則**
/// なので、1 つに畳むこと自体は抵触しない。**2 つに戻すときは必ず従うこと。**
///
/// FEAT-215 準拠: builder 引数の dialogContext で Navigator.pop を呼ぶ。
class AmbientBattleDefeatDialog extends StatelessWidget {
  const AmbientBattleDefeatDialog({
    super.key,
    required this.enemyName,
    required this.remainingBattles,
    required this.onClose,
  });

  final String enemyName;

  /// 【BUG-148】**この敵の**残り回数。0 なら「予定していた出陣は終わり」を出す。
  ///
  /// ボタンを 1 つに畳んだぶん、**閉じた後どうなるかが分からなくなる**ので、
  /// 本文で明示する。
  final int remainingBattles;

  /// ダイアログを閉じる。**オートバトルは再開しない**
  /// (回数が残っていれば次にホームへ来たときに自然に再開する)。
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      backgroundColor: AppTheme.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Row(
        children: [
          const Text('🛡️', style: TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          Text(
            l10n.battleAmbientDefeatTitle,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.battleAmbientDefeatBodySabi_message,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 13,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            remainingBattles > 0
                ? l10n.battleAmbientDefeatEnemyLabel(
                    enemyName, remainingBattles)
                : l10n.battleAmbientDefeatQueueDoneLabel(enemyName),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 11,
            ),
          ),
        ],
      ),
      actions: [
        // 【BUG-148】「閉じる」1 つだけ。理由は class の doc コメント参照。
        ElevatedButton(
          onPressed: onClose,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary,
            foregroundColor: Colors.white,
          ),
          child: Text(l10n.battleAmbientDefeatCloseButton),
        ),
      ],
    );
  }
}
