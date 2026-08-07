import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'sabi_icon.dart';  // 【FEAT-415 (2026-06-01)】sabi_unified.png 統一

/// 準備中画面の共通ウィジェット。
/// 機能・コンテンツが未公開の画面で使用する。
class SabiComingSoonWidget extends StatelessWidget {
  const SabiComingSoonWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 【FEAT-415 (2026-06-01)】絵文字 🪶 → sabi_unified.png に統一。
          // SabiEmotion.wise (賢者) = 「準備中、もう少しお待ちを」の意味。
          const SabiIcon(emotion: SabiEmotion.wise, size: 56),
          const SizedBox(height: 16),
          Text(
            l10n.sharedSabiComingSoonTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.sharedSabiComingSoonSubtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 13,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}
