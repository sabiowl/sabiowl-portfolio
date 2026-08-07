import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';

/// 【FEAT-513】Ambient Auto Battle の敗北通知 dialog。
///
/// BUG-138 準拠: 左 = 休む (Cancel 系)、右 = 続ける (Action 系)。
/// FEAT-215 準拠: builder 引数の dialogContext で Navigator.pop を呼ぶ。
class AmbientBattleDefeatDialog extends StatelessWidget {
  const AmbientBattleDefeatDialog({
    super.key,
    required this.enemyName,
    required this.onRest,
    required this.onContinue,
  });

  final String enemyName;

  /// 「休む」(左ボタン) コールバック。オートバトルを再開しない。
  final VoidCallback onRest;

  /// 「続ける」(右ボタン) コールバック。オートバトルを再開する。
  final VoidCallback onContinue;

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
            l10n.battleAmbientDefeatEnemyLabel(enemyName),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 11,
            ),
          ),
        ],
      ),
      actions: [
        // 【BUG-138】左 = Cancel 系 (休む = オートバトルを再開しない)
        TextButton(
          onPressed: onRest,
          child: Text(
            l10n.battleAmbientDefeatRestButton,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
          ),
        ),
        // 【BUG-138】右 = Action 系 (続ける = オートバトルを再試行する)
        ElevatedButton(
          onPressed: onContinue,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary,
            foregroundColor: Colors.white,
          ),
          child: Text(l10n.battleAmbientDefeatContinueButton),
        ),
      ],
    );
  }
}
