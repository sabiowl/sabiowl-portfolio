import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';

/// 【FEAT-438 (2026-06-17)】月間 21 日達成 SSR 確定チケット獲得演出ダイアログ。
///
/// FEAT-433 で Backend 実装済の「当月 21 日達成で SSR 確定チケット +1 配布」の
/// Mobile UI を SnackBar からポップアップに昇格させたもの。シンプル演出
/// (LoginBonusCalendarDialog と同等水準) を採用。
///
/// 表示シグナル: `monthlyTicketAwardedNotifierProvider` が true になると
/// RestackApp の global listener が showDialog する。表示完了後に provider を
/// false に戻すフローは listener 側で管理 (本 widget は表示のみ担当)。
class MonthlyTicketAwardedDialog extends StatefulWidget {
  const MonthlyTicketAwardedDialog({super.key});

  @override
  State<MonthlyTicketAwardedDialog> createState() =>
      _MonthlyTicketAwardedDialogState();
}

class _MonthlyTicketAwardedDialogState extends State<MonthlyTicketAwardedDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _iconScale;
  late final Animation<double> _fadeOpacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _iconScale = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _fadeOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.2, 1.0)),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Dialog(
      backgroundColor: AppTheme.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── タイトル ───────────────────────────
            Text(
              l10n.habitMonthlyTicketHeader,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 20),

            // ── 中央演出: SSR チケットアイコン + scale-in ─────
            ScaleTransition(
              scale: _iconScale,
              child: Container(
                width: 88,
                height: 88,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppTheme.primary.withValues(alpha: 0.45),
                    width: 2,
                  ),
                ),
                child: const Text('🎫', style: TextStyle(fontSize: 44)),
              ),
            ),
            const SizedBox(height: 20),

            // ── 報酬カード ────────────────────────
            FadeTransition(
              opacity: _fadeOpacity,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 18, vertical: 12),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppTheme.primary.withValues(alpha: 0.40),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('🎫', style: TextStyle(fontSize: 22)),
                    const SizedBox(width: 10),
                    Text(
                      l10n.habitMonthlyTicketLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),

            // ── サビ口調メッセージ ─────────────────
            FadeTransition(
              opacity: _fadeOpacity,
              child: Text(
                l10n.habitMonthlyTicketSabi_message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  height: 1.6,
                ),
              ),
            ),
            const SizedBox(height: 18),

            // ── 受け取るボタン ────────────────────
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  HapticFeedback.mediumImpact();
                  Navigator.of(context).pop();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  l10n.habitMonthlyTicketReceiveButton,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
