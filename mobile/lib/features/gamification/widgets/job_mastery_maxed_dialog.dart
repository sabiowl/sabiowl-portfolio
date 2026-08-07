/// 【FEAT-511 Phase A (v1.1、2026-07-30)】ジョブ熟練度 Max 到達サビ dialog。
///
/// BUG-138 準拠: 単一 action は右のみ。
/// サビ口調: 穏やかな確信、「地層」比喩使用、🪶 マーカー。
library;

import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';

import '../../../core/theme/app_theme.dart';

class JobMasteryMaxedDialog extends StatelessWidget {
  const JobMasteryMaxedDialog({super.key, required this.jobName});
  final String jobName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      backgroundColor: AppTheme.card,
      title: Row(
        children: [
          const Text('👑 ', style: TextStyle(fontSize: 24)),
          Flexible(
            child: Text(
              l10n.gamifJobMasteryMaxedTitle(jobName),
              style: const TextStyle(color: Colors.white, fontSize: 16),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: Text(
        l10n.gamifJobMasteryMaxedBodySabi_message(jobName),
        style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.6),
      ),
      // BUG-138 準拠: 単一 action は右
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            l10n.gamifJobMasteryMaxedCloseButton,
            style: const TextStyle(color: AppTheme.primary),
          ),
        ),
      ],
    );
  }
}
