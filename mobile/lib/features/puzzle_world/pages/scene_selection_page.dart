import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/toast_center.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_loading_skeleton.dart';
import '../../habits/services/world_background_service.dart';  // 【FEAT-479】mono thumbnail path
import '../models/puzzle_world.dart';
import '../providers/puzzle_world_provider.dart';
import '../widgets/puzzle_progress_mini_view.dart';

/// 【FEAT-479 Phase 2b (2026-07-06)】パズル世界シーン選択画面。
///
/// **2 モードの UI を 1 画面で担う**:
///
/// 1. **Onboarding (active_scene == null)**: 初回訪問、サビの語りかけ +
///    3 シーンを並べて「最初に手を伸ばしたい景色」を選ばせる。「この景色を救う」
///    ボタン 1 種のみ (drawer は薄い、選択のみに集中)。
/// 2. **通常 (active_scene != null)**: 3 シーンの一覧、各カードに 2 種のトグル:
///    - 「この世界を救う」(アクティブ切替、完成シーンでは disabled)
///    - 「フレンドに飾る」(displayed 切替、着手済 or 完成済のみ有効)
///
/// 【CLAUDE.md サビ口調準拠】文言は指示書 §4.4 の Sabi 台詞集をそのまま採用。
/// エラー時は `mounted` チェック + サビ口調 SnackBar (「今回はうまくいきませんでした 🪶」)。
class SceneSelectionPage extends ConsumerWidget {
  const SceneSelectionPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final scenesAsync = ref.watch(puzzleScenesProvider);
    final statusAsync = ref.watch(puzzleWorldStatusProvider);

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        // 【FEAT-479 rename (2026-07-06)】旧「パズル世界」→「眠る世界」。
        // Sabi 静穏原則 (聖域トーン) + 「まだ眠っているかけら」既存語彙との呼応。
        title: Text(l10n.puzzleWorldSceneSelectionPageTitle),
        backgroundColor: AppTheme.surface,
        foregroundColor: Colors.white,
      ),
      body: scenesAsync.when(
        loading: () => SabiWaitingPanel(
            message: l10n.puzzleWorldSceneSelectionLoadingSabi_message),
        error: (_, __) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              l10n.puzzleWorldGenericErrorSabi_message,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (list) {
          final isOnboarding =
              statusAsync.valueOrNull?.needsOnboarding ?? false;
          // 【FEAT-479 hotfix (2026-07-06)】ShellRoute の BottomNav が Stack overlay
          // で重なるため、Scaffold.bottomNavigationBar による自動 body 縮小が効かない。
          // MediaQuery.padding.bottom には _ScaffoldWithBottomNav が kNavBarHeight を
          // 加算済 → ListView 末尾の余白として明示的に反映しないと最後のカードが
          // ナビバー下に隠れる (ChallengePage 同パターン)。
          final navClearance = MediaQuery.of(context).padding.bottom + 16;
          return RefreshIndicator(
            color: AppTheme.primary,
            onRefresh: () async {
              ref.invalidate(puzzleScenesProvider);
              ref.invalidate(puzzleWorldStatusProvider);
            },
            child: ListView(
              padding: EdgeInsets.fromLTRB(12, 16, 12, navClearance),
              children: [
                const _FeatureDescription(),
                // 【FEAT-479 hotfix (2026-07-06)】旧 _HeroCopy の通常時文言
                // 「あなたが手をかける景色を、選び直してみましょうか 🪶」を
                // 削除 (ユーザー要件、_FeatureDescription と冗長)。
                // Onboarding 時のみ「3 つの景色があります…」ガイドを保持。
                if (isOnboarding) ...[
                  const SizedBox(height: 12),
                  const _HeroCopy(isOnboarding: true),
                ],
                const SizedBox(height: 16),
                for (final entry in list.scenes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _SceneCard(
                      entry: entry,
                      isOnboarding: isOnboarding,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 【FEAT-479 rename (2026-07-06)】機能説明バナー。
///
/// 画面全体の "What / How" を 1 段落で伝える。仕組み (かけら収集 → 彩り宿す →
/// 世界が動き始める) を Sabi 口調で優しく案内する。onboarding かどうかを問わず
/// 常時表示 (返訪ユーザーが「そういえばこの機能は…」を思い出せる利点)。
///
/// スタイル: primary 系の薄い背景 + 12sp / height 1.6 で "囁く落ち着き" を保つ。
class _FeatureDescription extends StatelessWidget {
  const _FeatureDescription();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.22),
        ),
      ),
      child: Text(
        AppLocalizations.of(context)!.puzzleWorldFeatureDescriptionSabi_message,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          height: 1.7,
        ),
      ),
    );
  }
}

/// 上部の hero copy。onboarding かどうかで文言が変わる (サビ口調)。
class _HeroCopy extends StatelessWidget {
  const _HeroCopy({required this.isOnboarding});
  final bool isOnboarding;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = isOnboarding
        ? l10n.puzzleWorldHeroCopyOnboardingSabi_message
        : l10n.puzzleWorldHeroCopyReturningSabi_message;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          height: 1.6,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _SceneCard: 1 シーン分のカード
// ─────────────────────────────────────────────────────────────────────────────

class _SceneCard extends ConsumerWidget {
  const _SceneCard({required this.entry, required this.isOnboarding});

  final SceneListEntry entry;
  final bool isOnboarding;

  bool get _isCompleted => entry.status == SceneStatus.completed;
  bool get _isUnstarted => entry.status == SceneStatus.unstarted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final scene = entry.scene;

    // active 切替可 = is_active=True (Backend で保証) かつ未完成
    final canBeActive = !_isCompleted;
    // displayed 切替可 = active or 完成済 (未着手は不可)
    final canBeDisplayed = entry.isActive || _isCompleted;

    // 未着手シーンのカードはタップ無効 (詳細を見る意味が薄い)、
    // 着手済 or 完成済のみ詳細画面遷移可能。
    // 【FEAT-479 hotfix (2026-07-06)】旧 InkWell(全カード) → 廃止。
    // 「再生中 / ホームに表示 / ホームに表示中」ボタンタップ時に InkWell
    // にも onTap 伝播していた誤タップ問題を解消。詳細画面遷移は下記
    // ミニグリッド (マス目) タップに限定 = 意図明示化。
    final canTapForDetail = entry.status != SceneStatus.unstarted;

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: entry.isActive
              ? AppTheme.primary.withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: 0.08),
          width: entry.isActive ? 1.8 : 1.0,
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── ヘッダ: シーン名 + tagline + サムネ + 状態バッジ ─────
          // 【FEAT-479 (2026-07-06)】右上に完成イメージ thumbnail (モノクロ /
          // 完成済はカラー) を配置してモチベを喚起。tap で拡大 BottomSheet。
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      scene.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      scene.tagline,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _StatusBadge(status: entry.status),
                  const SizedBox(height: 6),
                  _SceneThumbnail(
                    scene: scene,
                    isCompleted: _isCompleted,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),

          // ── 進捗テキスト (右端に 割合、fontFeatures で数字幅固定) ─
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.puzzleWorldProgressBreakdown(
                    entry.ownedCount - entry.coloredCount,
                    entry.coloredCount,
                    entry.totalCount - entry.ownedCount,
                  ),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.65),
                    fontSize: 11,
                  ),
                ),
              ),
              Text(
                '${entry.coloredCount} / ${entry.totalCount}',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 11,
                ),
              ),
            ],
          ),
          // 【FEAT-479 hotfix (2026-07-06)】ミニビューをカード幅一杯に stretch、
          // 6 列 × 5 行 (WorldFrame overlay と同レイアウト) で LayoutBuilder
          // による動的 pieceSize 算出。旧 5×6 固定 pieceSize=10 だと card 中央
          // に細長い島となり空白感が強かった。未着手シーンは進捗ゼロなので
          // 描画を省略。
          // 【FEAT-479 hotfix (2026-07-06)】ミニグリッド (マス目) タップで
          // 詳細画面遷移。旧 InkWell(全カード) → 廃止したため、詳細への動線を
          // ここに限定 (マス目を触る = 中身を覗きに行く、の意図明示)。
          if (!_isUnstarted) ...[
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: canTapForDetail
                  ? () => context.push(
                      '${AppRoutes.puzzleWorld}/scene/${scene.key}',
                    )
                  : null,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const columns = 10;
                  const spacing = 2.5;
                  final pieceSize =
                      (constraints.maxWidth - spacing * (columns - 1)) / columns;
                  return _MiniProgressForScene(
                    scene: scene,
                    ownedCount: entry.ownedCount,
                    coloredCount: entry.coloredCount,
                    totalCount: entry.totalCount,
                    pieceSize: pieceSize.floorToDouble(),
                    columns: columns,
                    spacing: spacing,
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 16),

          // ── アクションボタン ───────────────────────────
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  // 【FEAT-479 rename (2026-07-06)】ユーザー確定案:
                  //   救う → 生命を宿す (Sabi「静かな聖域」トーンに整合)
                  //   集中中 → 再生中 (「◯◯中」の処理中感を回避、"生命が
                  //                     宿っていく最中" を示す)
                  label: entry.isActive
                      ? l10n.puzzleWorldStateActive
                      : (isOnboarding
                          ? l10n.puzzleWorldActionMakeActiveOnboarding
                          : l10n.puzzleWorldActionMakeActive),
                  onPressed: canBeActive && !entry.isActive
                      ? () => _handleSelectActive(context, ref, scene.key)
                      : null,
                  isPrimary: true,
                  disabledHint: _isCompleted
                      ? l10n.puzzleWorldActionDisabledCompletedSabi_message
                      : null,
                ),
              ),
              if (!isOnboarding) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: _ActionButton(
                    // 【FEAT-479 rename (2026-07-06)】ユーザー確定案:
                    //   額縁に飾る → ホームに表示 (機能明示)
                    label: entry.isDisplayed
                        ? l10n.puzzleWorldActionDisplayed
                        : l10n.puzzleWorldActionDisplay,
                    onPressed: canBeDisplayed && !entry.isDisplayed
                        ? () => _handleSelectDisplayed(context, ref, scene.key)
                        : null,
                    isPrimary: false,
                    disabledHint: _isUnstarted
                        ? l10n.puzzleWorldActionDisabledUnstartedSabi_message
                        : null,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _handleSelectActive(
    BuildContext context,
    WidgetRef ref,
    String sceneKey,
  ) async {
    // 【FEAT-489 Phase 2E】await をまたぐので l10n は先に capture する。
    final l10n = AppLocalizations.of(context)!;
    try {
      await ref.read(puzzleWorldCommandProvider).selectActive(sceneKey);
      if (!context.mounted) return;
      ToastCenter.showSuccess(l10n.puzzleWorldSelectActiveSuccessSabi_message);
    } catch (_) {
      if (!context.mounted) return;
      ToastCenter.showSuccess(l10n.puzzleWorldCommandErrorSabi_message);
    }
  }

  Future<void> _handleSelectDisplayed(
    BuildContext context,
    WidgetRef ref,
    String sceneKey,
  ) async {
    // 【FEAT-489 Phase 2E】await をまたぐので l10n は先に capture する。
    final l10n = AppLocalizations.of(context)!;
    try {
      await ref.read(puzzleWorldCommandProvider).selectDisplayed(sceneKey);
      if (!context.mounted) return;
      ToastCenter.showSuccess(l10n.puzzleWorldSelectDisplayedSuccessSabi_message);
    } catch (_) {
      if (!context.mounted) return;
      ToastCenter.showSuccess(l10n.puzzleWorldCommandErrorSabi_message);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 補助 widget
// ─────────────────────────────────────────────────────────────────────────────

/// 【FEAT-479 (2026-07-06)】シーン完成イメージの thumbnail。
///
/// 完成モチベを喚起する視覚要素。
/// - 未完成 (unstarted / in_progress / active): **モノクロ** preview
///   (Sabi「まだ眠っている景色」の暗示)
/// - 完成済 (completed): **カラー** の実物 (「救った証」として明るく表示)
///
/// tap で BottomSheet を開いて拡大版 (画面幅) を静かに提示。
/// asset 未配置時は errorBuilder で icon placeholder に degrade。
///
/// サイズ: 78×54 px (aspect 1.44:1、カード右上に収まる控えめサイズ)。
class _SceneThumbnail extends StatelessWidget {
  const _SceneThumbnail({required this.scene, required this.isCompleted});

  final PuzzleScene scene;
  final bool isCompleted;

  static const double _width  = 78;
  static const double _height = 54;

  @override
  Widget build(BuildContext context) {
    // 【FEAT-479 hotfix (2026-07-06)】mono 未配置時の graceful fallback:
    // - 完成済: color 版 → placeholder
    // - 未完成: mono 版 → color 版 (mono 未配置なら color で代替) → placeholder
    // これにより mono 3 枚を配置していない現状でも SceneCard は色付き
    // サムネで動作、v1.1 で mono 配置後は自動的に mono に切り替わる。
    final colorPath = WorldBackgroundService.pathForBackgroundKey(scene.backgroundKey);
    final monoPath = WorldBackgroundService.monoPathForBackgroundKey(scene.backgroundKey);
    final primaryPath = isCompleted ? colorPath : monoPath;

    return GestureDetector(
      onTap: (primaryPath == null && colorPath == null)
          ? null
          : () => _showLargePreview(context, primaryPath ?? colorPath!),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width:  _width,
          height: _height,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.35),
            border: Border.all(
              color: isCompleted
                  ? Colors.amber.withValues(alpha: 0.55)
                  : Colors.white.withValues(alpha: 0.20),
              width: 0.8,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: _buildThumbImage(primaryPath, colorPath),
        ),
      ),
    );
  }

  /// primary → color (mono 未配置時 fallback) → placeholder の 3 段 fallback。
  Widget _buildThumbImage(String? primaryPath, String? colorFallback) {
    if (primaryPath == null) {
      if (colorFallback == null) return const _ThumbPlaceholder();
      return Image.asset(
        colorFallback,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.none,
        errorBuilder: (_, __, ___) => const _ThumbPlaceholder(),
      );
    }
    return Image.asset(
      primaryPath,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.none,
      errorBuilder: (_, __, ___) {
        // mono 未配置 → color 版で代替 (v1.1 mono 配置後は不発火)
        if (colorFallback != null && colorFallback != primaryPath) {
          return Image.asset(
            colorFallback,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.none,
            errorBuilder: (_, __, ___) => const _ThumbPlaceholder(),
          );
        }
        return const _ThumbPlaceholder();
      },
    );
  }

  void _showLargePreview(BuildContext context, String path) {
    final l10n = AppLocalizations.of(context)!;
    final colorFallback = WorldBackgroundService.pathForBackgroundKey(scene.backgroundKey);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.card,
      showDragHandle: true,
      // 【FEAT-479 hotfix (2026-07-06)】isScrollControlled=true で BottomSheet の
      // 最大高制限 (default 50%) を解除 + SingleChildScrollView で溢れた場合の
      // 保険。旧: AspectRatio(1.43) の拡大画像 (240px) + テキスト (~94px) +
      // padding で 53px OVERFLOW していた。
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  scene.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  isCompleted
                      ? l10n.puzzleWorldThumbnailCompletedSabi_message
                      : l10n.puzzleWorldThumbnailIncompleteSabi_message,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.80),
                    fontSize: 12,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AspectRatio(
                    aspectRatio: 1.43,
                    child: Image.asset(
                      path,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.none,
                      errorBuilder: (_, __, ___) {
                        // mono 未配置 → color 版で代替
                        if (colorFallback != null && colorFallback != path) {
                          return Image.asset(
                            colorFallback,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.none,
                            errorBuilder: (_, __, ___) => const _ThumbPlaceholder(),
                          );
                        }
                        return const _ThumbPlaceholder();
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// thumbnail asset 未配置時の placeholder (Sabi 語彙の呼応維持)。
class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.03),
            Colors.white.withValues(alpha: 0.08),
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.image_outlined,
          color: Colors.white.withValues(alpha: 0.35),
          size: 20,
        ),
      ),
    );
  }
}

/// カード右上の状態バッジ (色分け)。
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final SceneStatus status;

  @override
  Widget build(BuildContext context) {
    // 【FEAT-479 v1 (2026-07-07)】バッジ用語をボタンラベルと語彙統一:
    //   救っている → 再生中     (ボタン active 状態と一致)
    //   救った     → 命が宿った (ボタン disabledHint「もう命が宿った景色です」と一致)
    // inProgress / unstarted は既存維持 (別軸の状態)。
    final l10n = AppLocalizations.of(context)!;
    final (label, color) = switch (status) {
      SceneStatus.active =>     (l10n.puzzleWorldStateActive,     AppTheme.primary),
      SceneStatus.completed =>  (l10n.puzzleWorldStateCompleted,  Colors.amber),
      SceneStatus.inProgress => (l10n.puzzleWorldStateInProgress, Colors.white70),
      SceneStatus.unstarted =>  (l10n.puzzleWorldStateUnstarted,  Colors.white38),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 0.8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// SceneListEntry には piece_states がないため、progress 数から擬似 mini view を描画。
/// active_scene の詳細は puzzleWorldStatusProvider 経由で別途取得可能だが、
/// Phase 2b では簡素化のため owned/colored を色分けで表現するだけに留める。
class _MiniProgressForScene extends StatelessWidget {
  const _MiniProgressForScene({
    required this.scene,
    required this.ownedCount,
    required this.coloredCount,
    required this.totalCount,
    this.pieceSize = 10,
    this.columns = 5,
    this.spacing = 2,
  });

  final PuzzleScene scene;
  final int ownedCount;
  final int coloredCount;
  final int totalCount;
  final double pieceSize;
  final int columns;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    // 30 マス擬似生成 (colored 数だけ 2、owned-colored だけ 1、残り 0)
    final states = <int>[
      ...List.filled(coloredCount, 2),
      ...List.filled(ownedCount - coloredCount, 1),
      ...List.filled(totalCount - ownedCount, 0),
    ];
    return PuzzleProgressMiniView(
      pieceStates: states,
      pieceSize: pieceSize,
      spacing: spacing,
      columns: columns,
    );
  }
}

/// アクションボタン (primary / secondary、disabled 時は tooltip 相当のヒントを SnackBar 表示)。
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.onPressed,
    required this.isPrimary,
    this.disabledHint,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool isPrimary;
  final String? disabledHint;

  @override
  Widget build(BuildContext context) {
    // 【UX Review 2026-07-06 P2-1】タップ対象高を 40pt → 44pt に昇格
    // (Apple HIG 44pt / Material 48dp 準拠、小型端末での誤タップ抑制)。
    if (onPressed == null && disabledHint != null) {
      // disabled 時: タップで SnackBar でヒント表示 (Sabi 口調)
      return GestureDetector(
        onTap: () => ToastCenter.showSuccess(disabledHint!),
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.40),
              fontSize: 12,
            ),
          ),
        ),
      );
    }

    if (isPrimary) {
      return ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 44),
          disabledBackgroundColor: Colors.white.withValues(alpha: 0.04),
          disabledForegroundColor: Colors.white.withValues(alpha: 0.30),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.primary,
        minimumSize: const Size(0, 44),
        side: BorderSide(
          color: onPressed != null
              ? AppTheme.primary.withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: 0.15),
        ),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}
