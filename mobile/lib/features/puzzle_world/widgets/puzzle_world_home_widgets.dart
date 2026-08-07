import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../providers/puzzle_world_provider.dart';
import 'puzzle_progress_mini_view.dart';

/// 【FEAT-479 Phase 2c (2026-07-06)】ホーム画面用の 2 widget:
///
/// - [PuzzleWorldMiniStrip]: アクティブシーンの進捗をカード状に表示
///   (WorldFrameSection 直下に配置予定、needsOnboarding 時は null 返し)
/// - [PuzzleWorldOnboardingBanner]: needsOnboarding 時にのみ表示される
///   controlled banner。タップで SceneSelectionPage 遷移。


// ─────────────────────────────────────────────────────────────────────────────
// PuzzleWorldMiniStrip: アクティブシーンの 30 マス進捗ミニビュー
// ─────────────────────────────────────────────────────────────────────────────

/// アクティブシーンの 30 マス進捗を表示するカード。
///
/// - `activeScene == null` (onboarding 未完了) → 描画しない (Widget 返さない)
/// - `activeScene != null` → シーン名 + tagline + 30 マス mini view
/// - タップで /puzzle-world/scene/:sceneKey (詳細画面) へ遷移
///
/// **home_body への埋込想定**: WorldFrameSection の直下 (Sliver 経路)。
/// autoDispose のため、ホーム画面から離れると自動的にリソース解放。
class PuzzleWorldMiniStrip extends ConsumerWidget {
  const PuzzleWorldMiniStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncStatus = ref.watch(puzzleWorldStatusProvider);
    return asyncStatus.when(
      // Loading / error 時は無表示 (ホームは他コンテンツで賑わっているので気配りゼロ)
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (status) {
        final active = status.activeScene;
        if (active == null) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => context.push(
              '${AppRoutes.puzzleWorld}/scene/${active.scene.key}',
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: AppTheme.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.2),
                ),
              ),
              // 【FEAT-479 (2026-07-06)】旧 Row (text 左 / mini 右) を Column
              // (text 上 / 進捗バー下) に再構成。3 行×10 列 = 30 マスを card 幅
              // いっぱいに広げ、「横長の空きスペース」を進捗表示で埋める。
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          active.scene.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${active.coloredCount} / ${active.scene.pieceCount}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 11,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    AppLocalizations.of(context)!.puzzleWorldProgressBreakdown(
                      active.ownedCount - active.coloredCount,
                      active.coloredCount,
                      active.scene.pieceCount - active.ownedCount,
                    ),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // ── 3 行 × 10 列 = 30 マスの進捗バー (card 幅一杯に stretch) ─
                  LayoutBuilder(
                    builder: (context, constraints) {
                      const columns = 10;
                      const spacing = 3.0;
                      // 有効幅から piece 幅を逆算 (10 マス + 9 gap を fit)
                      final pieceSize =
                          (constraints.maxWidth - spacing * (columns - 1)) /
                              columns;
                      return PuzzleProgressMiniView(
                        pieceStates: active.pieceStates,
                        pieceSize: pieceSize.floorToDouble(),
                        spacing: spacing,
                        columns: columns,
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// PuzzleWorldOnboardingBanner: needsOnboarding 時のみ表示される薄い banner
// ─────────────────────────────────────────────────────────────────────────────

/// Onboarding 未完了 (active_scene == null) のときのみ表示される controlled banner。
///
/// - 表示条件: `puzzleWorldStatusProvider.needsOnboarding == true`
///             AND session 内で未 dismiss
/// - タップで SceneSelectionPage 遷移 (onboarding モード)
/// - × で 1 セッション dismiss (Provider で状態保持、re-open で復活)
///
/// **home_body への埋込想定**: WorldFrameSection の**上** (SabiSpeechPanel 相当の
/// 温度、上部の余白に control-flow で挿入)。
///
/// **Sabi 静穏原則**: 派手にしない。1 行 + アイコンで軽量、× で dismiss 可能。
class PuzzleWorldOnboardingBanner extends ConsumerStatefulWidget {
  const PuzzleWorldOnboardingBanner({super.key});

  @override
  ConsumerState<PuzzleWorldOnboardingBanner> createState() =>
      _PuzzleWorldOnboardingBannerState();
}

class _PuzzleWorldOnboardingBannerState
    extends ConsumerState<PuzzleWorldOnboardingBanner> {
  // Session-scoped dismiss (widget 再構築で消える、restart で再表示)。
  // 恒久 dismiss (SharedPreferences) は「Sabi は諦めず、また声をかけてくれる」
  // 設計哲学と合わないため意図的に採用しない。
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();

    final asyncStatus = ref.watch(puzzleWorldStatusProvider);
    return asyncStatus.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (status) {
        if (!status.needsOnboarding) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Container(
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppTheme.primary.withValues(alpha: 0.35),
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => context.push(AppRoutes.puzzleWorld),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                  child: Row(
                    children: [
                      Icon(
                        Icons.extension_outlined,
                        color: AppTheme.primary,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(context)!
                              .puzzleWorldHomePromptSabi_message,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.close,
                          color: Colors.white.withValues(alpha: 0.55),
                          size: 16,
                        ),
                        onPressed: () {
                          setState(() => _dismissed = true);
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
