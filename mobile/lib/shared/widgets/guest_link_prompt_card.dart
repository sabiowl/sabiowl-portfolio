import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../l10n/app_localizations.dart';

/// FEAT-180: ゲストモード時に「Google または Apple との連携を促す」誘導カード。
///
/// タイムライン・ガチャ・フレンド・通知 画面で共通利用する。
/// 【FEAT-243】「連携する」ボタンタップでマイページ（`AppRoutes.settings`）に遷移し、
/// `?openAccountLink=true` クエリでアカウント連携シートを自動展開する。
/// ホーム上部バナー / バックアップシート と動線統一。
class GuestLinkPromptCard extends StatelessWidget {
  const GuestLinkPromptCard({
    super.key,
    required this.title,
    required this.description,
    this.icon = Icons.lock_outline,
  });

  /// 例: 'タイムラインは、連携してから'
  final String title;

  /// サビの紳士的なトーンの説明文
  final String description;

  /// カード上部に表示するアイコン（画面ごとに差し替え可能）
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.card,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
          ),
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 48,
                color: AppTheme.primary.withValues(alpha: 0.85),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                description,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  height: 1.6,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () {
                  HapticFeedback.lightImpact();
                  // 【FEAT-243】マイページ遷移後にアカウント連携シートを自動展開
                  // （ホーム上部バナー / バックアップシートと動線統一、4 経路すべて
                  // 「マイページ + アカウント連携シート」へ収束）。
                  context.go('${AppRoutes.settings}?openAccountLink=true');
                },
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32, vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(l10n.sharedGuestLinkPromptCardLinkButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
