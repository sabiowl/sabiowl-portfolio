import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../l10n/app_localizations.dart';
import 'sabi_icon.dart';  // 【FEAT-415 (2026-06-01)】sabi_unified.png 統一

/// レベルアップ後にゲストユーザーへアカウント登録を促すシート。
///
/// 「バックアップする（無料）」→ 登録画面へ遷移（シートは自動で閉じる）
/// 「今はいいや」→ シートを閉じるだけ
class BackupPromptSheet extends StatelessWidget {
  const BackupPromptSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: const BoxDecoration(
        color:        AppTheme.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
        24,
        16,
        24,
        24 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── ドラッグハンドル ────────────────────────────────────────────
          Container(
            width:  40,
            height: 4,
            decoration: BoxDecoration(
              color:        Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),

          // ── サビの吹き出し ──────────────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 【FEAT-415 (2026-06-01)】絵文字 🪶 → sabi_unified.png に統一。
              // SabiEmotion.pity (寄り添い) = 「データを守りませんか」の優しい誘い。
              const SabiIcon(emotion: SabiEmotion.pity, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.08),
                    borderRadius: const BorderRadius.only(
                      topLeft:     Radius.circular(4),
                      topRight:    Radius.circular(16),
                      bottomLeft:  Radius.circular(16),
                      bottomRight: Radius.circular(16),
                    ),
                    border: Border.all(
                        color: AppTheme.primary.withValues(alpha: 0.2)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'SABI',
                        style: TextStyle(
                          fontSize:      9,
                          fontWeight:    FontWeight.bold,
                          color:         AppTheme.primaryLight,
                          letterSpacing: 3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10n.sharedBackupPromptSheetSabiMessage,
                        style: TextStyle(
                          fontSize: 13,
                          color:    Colors.white.withValues(alpha: 0.85),
                          height:   1.65,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // ── メリットリスト ──────────────────────────────────────────────
          _BenefitRow(icon: '☁️', text: l10n.sharedBackupPromptSheetBenefit1),
          const SizedBox(height: 10),
          _BenefitRow(icon: '📱', text: l10n.sharedBackupPromptSheetBenefit2),
          const SizedBox(height: 10),
          _BenefitRow(icon: '👥', text: l10n.sharedBackupPromptSheetBenefit3),
          const SizedBox(height: 28),

          // ── ボタン ──────────────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                // 【FEAT-243】サインイン画面 (/register) ではなく、マイページの
                // アカウント連携シートを自動展開する動線に統一。
                // go_router の context.go を使うと Navigator が不安定になるため
                // pop してから microtask で go する（FEAT-220/FEAT-232 で確立した
                // 「sheet → microtask → navigation」パターン維持）。
                Future.microtask(
                  () {
                    if (context.mounted) {
                      context.go(
                          '${AppRoutes.settings}?openAccountLink=true');
                    }
                  },
                );
              },
              style: ElevatedButton.styleFrom(
                padding:   const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600),
              ),
              child: Text(l10n.sharedBackupPromptSheetBackupButton),
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              l10n.sharedBackupPromptSheetLaterButton,
              style: const TextStyle(color: Colors.white38),
            ),
          ),
        ],
      ),
    );
  }
}

class _BenefitRow extends StatelessWidget {
  final String icon;
  final String text;

  const _BenefitRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(icon, style: const TextStyle(fontSize: 18)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color:    Colors.white.withValues(alpha: 0.75),
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }
}
