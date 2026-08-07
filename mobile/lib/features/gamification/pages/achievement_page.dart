import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/services/toast_center.dart';            // FEAT-314
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/sabi_loading_skeleton.dart';   // FEAT-230
import '../models/achievement_models.dart';
import '../providers/achievement_provider.dart';

class AchievementPage extends ConsumerWidget {
  const AchievementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final achievementsAsync = ref.watch(achievementsProvider);
    final l10n = AppLocalizations.of(context)!;

    // 【FEAT-314】 新規 unlock した称号があり +20 ダイヤが付与された場合、
    // サビ口調トーストを emit する。`ref.listen` は state 変化のみ反応するため
    // ページ再描画で重複発火しない（複数 unlock 時は合計値表示）。
    ref.listen<AsyncValue<AchievementsData>>(achievementsProvider, (prev, next) {
      final d = next.valueOrNull;
      if (d == null || d.titleDiamond <= 0) return;
      ToastCenter.showSuccess(l10n.gamifAchievementTitleDiamondToastSabi_message(d.titleDiamond));
    });

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: Text(l10n.gamifAchievementPageTitle, style: const TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: achievementsAsync.when(
        loading: () =>
            SabiWaitingPanel(message: l10n.gamifAchievementPageLoadingSabi_message),
        error: (e, _) =>
            Center(child: Text(l10n.gamifAchievementPageErrorSabi_message, style: const TextStyle(color: Colors.white70))),
        data: (data) => _buildBody(context, ref, data),
      ),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref, AchievementsData data) {
    final l10n = AppLocalizations.of(context)!;
    final unlocked = data.achievements.where((a) => a.unlocked).length;
    final total    = data.achievements.length;

    return CustomScrollView(
      slivers: [
        // ── 進捗サマリー ──────────────────────────────────
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: AppTheme.cardBackground,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.primary.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                const Text('🏅', style: TextStyle(fontSize: 32)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.gamifAchievementUnlockedCount(unlocked, total),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: total > 0 ? unlocked / total : 0,
                          minHeight: 6,
                          backgroundColor: Colors.white.withValues(alpha: 0.1),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                              AppTheme.primary),
                        ),
                      ),
                    ],
                  ),
                ),
                if (data.unclaimedCount > 0) ...[
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.expColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.expColor.withValues(alpha: 0.6)),
                    ),
                    child: Text(
                      l10n.gamifAchievementClaimBadge(data.unclaimedCount),
                      style: const TextStyle(
                        color: AppTheme.expColor,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        // ── 実績グリッド ───────────────────────────────────
        // 【2026-05-28 UX 修正】画面下部までスクロールできない問題を解消、
        // 既存 16 + safe area に +24px 追加で確実に余白確保。
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            16, 0, 16, 40 + MediaQuery.of(context).padding.bottom,
          ),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.78,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildBadge(context, ref, data.achievements[index]),
              childCount: data.achievements.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBadge(BuildContext context, WidgetRef ref, Achievement achievement) {
    final isUnlocked = achievement.unlocked;
    final isClaimed  = achievement.isClaimed;

    return GestureDetector(
      // FEAT-124: ロック中もタップで達成条件を表示する
      onTap: () => _showDetail(context, ref, achievement),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          color: isUnlocked
              ? AppTheme.cardBackground
              : AppTheme.cardBackground.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isUnlocked
                ? AppTheme.primary.withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.1),
            width: isUnlocked ? 1.5 : 1,
          ),
          boxShadow: isUnlocked
              ? [
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha: 0.15),
                    blurRadius: 8,
                    spreadRadius: 1,
                  )
                ]
              : null,
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // アイコン
                  Text(
                    isUnlocked ? achievement.icon : '🔒',
                    style: TextStyle(
                      fontSize: 32,
                      color: isUnlocked ? null : Colors.white.withValues(alpha: 0.3),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 名前
                  Text(
                    achievement.name,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isUnlocked
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.35),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // ダイヤ報酬
                  Text(
                    '💎 ${achievement.rewardDiamonds}',
                    style: TextStyle(
                      color: isUnlocked
                          ? Colors.white.withValues(alpha: 0.7)
                          : Colors.white.withValues(alpha: 0.25),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            // 未受取バッジ
            if (isUnlocked && !isClaimed)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: AppTheme.expColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showDetail(BuildContext context, WidgetRef ref, Achievement achievement) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.cardBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _AchievementDetailSheet(achievement: achievement),
    );
  }
}

// ─────────────────────────────────────────────────
// 実績詳細シート
// ─────────────────────────────────────────────────
class _AchievementDetailSheet extends ConsumerStatefulWidget {
  final Achievement achievement;

  const _AchievementDetailSheet({
    required this.achievement,
  });

  @override
  ConsumerState<_AchievementDetailSheet> createState() =>
      _AchievementDetailSheetState();
}

class _AchievementDetailSheetState
    extends ConsumerState<_AchievementDetailSheet> {
  bool _claiming = false;

  Future<void> _claim() async {
    setState(() => _claiming = true);
    try {
      final service = ref.read(achievementServiceProvider);
      final result  = await service.claimAchievement(widget.achievement.key);
      if (!mounted) return;
      // プロバイダーを更新
      ref.invalidate(achievementsProvider);
      Navigator.of(context).pop();
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message'] as String? ?? l10n.gamifAchievementClaimSuccessToast),
          backgroundColor: AppTheme.expColor,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.gamifAchievementClaimErrorSabi_message),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _claiming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.achievement;
    // FEAT-124: ロック中はロック専用 UI を表示
    if (!a.unlocked) return _buildLockedSheet(a);
    return _buildUnlockedSheet(a);
  }

  // ── ロック中シート ──────────────────────────────────────────────────────────
  Widget _buildLockedSheet(Achievement a) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24, 24, 24, 24 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '🔒',
            style: TextStyle(
              fontSize: 56,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            a.name,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontWeight: FontWeight.bold,
              fontSize: 20,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            a.description,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            l10n.gamifAchievementEmptyLabel,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.3),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ── アンロック済みシート（既存 UI をメソッドに切り出し）──────────────────────
  Widget _buildUnlockedSheet(Achievement a) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24, 24, 24, 24 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(a.icon, style: const TextStyle(fontSize: 56)),
          const SizedBox(height: 12),
          Text(
            a.name,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 20,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            a.description,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 16),
          // 報酬表示
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.expColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.expColor.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('💎', style: TextStyle(fontSize: 20)),
                const SizedBox(width: 6),
                Text(
                  l10n.gamifAchievementRewardDiamonds(a.rewardDiamonds),
                  style: const TextStyle(
                    color: AppTheme.expColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // クレームボタン（未受取の場合のみ表示）
          if (!a.isClaimed)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _claiming ? null : _claim,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _claiming
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : Text(l10n.gamifAchievementClaimButton,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            )
          else
            Text(
              l10n.gamifAchievementClaimedLabel,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 14,
              ),
            ),
        ],
      ),
    );
  }
}
