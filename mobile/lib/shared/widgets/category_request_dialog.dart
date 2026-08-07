import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../l10n/app_localizations.dart';
import 'sabi_icon.dart';  // 【FEAT-415 (2026-06-01)】sabi_unified.png 統一

/// カテゴリ追加リクエストのポップアップダイアログ。
///
/// カテゴリ選択画面の「もっと追加する？」リンクからタップされた際に表示する。
/// お問い合わせ機能へのナビゲーションボタンと閉じるボタンを持つ。
///
/// 使用例:
/// ```dart
/// CategoryRequestDialog.show(context);
/// ```
class CategoryRequestDialog extends StatelessWidget {
  const CategoryRequestDialog._({required this.onContact});

  final VoidCallback onContact;

  /// ダイアログを表示する。
  /// [onContact] タップ時: ダイアログを閉じてから contact 画面に遷移する。
  static void show(BuildContext context) {
    // Navigator.pop と context.push が混在しないよう、
    // outer context を保持してからダイアログを表示する
    final outerContext = context;
    showDialog<void>(
      context: context,
      builder: (_) => CategoryRequestDialog._(
        onContact: () {
          Navigator.of(outerContext, rootNavigator: true).pop();
          outerContext.push(AppRoutes.contact);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Dialog(
      backgroundColor: AppTheme.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── フクロウアイコン ──────────────────────────────────
            // 【FEAT-415 (2026-06-01)】絵文字 🪶 → sabi_unified.png に統一。
            // SabiEmotion.wise (賢者) = 「お問い合わせの案内、教えますね」の意味。
            const SabiIcon(emotion: SabiEmotion.wise, size: 48),
            const SizedBox(height: 14),

            // ── タイトル ──────────────────────────────────────────
            Text(
              l10n.sharedCategoryRequestDialogTitle,
              style: const TextStyle(
                color:      Colors.white,
                fontSize:   17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),

            // ── メッセージ ─────────────────────────────────────────
            Text(
              l10n.sharedCategoryRequestDialogMessage,
              style: TextStyle(
                color:    Colors.white.withValues(alpha: 0.62),
                fontSize: 13,
                height:   1.6,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 22),

            // ── お問い合わせボタン ────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onContact,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: Text(
                  l10n.sharedCategoryRequestDialogContactButton,
                  style: const TextStyle(
                    fontSize:   14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),

            // ── 閉じるボタン ──────────────────────────────────────
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white38,
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              child: Text(l10n.commonClose, style: const TextStyle(fontSize: 14)),
            ),
          ],
        ),
      ),
    );
  }
}
