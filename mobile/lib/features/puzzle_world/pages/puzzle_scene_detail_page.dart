import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_loading_skeleton.dart';
import '../models/puzzle_world.dart';
import '../providers/puzzle_world_provider.dart';
import '../utils/piece_grid_layout.dart';  // 【gameplay_review 20260709 §A-2】3 site 単一真実値化
import '../widgets/puzzle_progress_mini_view.dart';

/// 【FEAT-479 Phase 2c (2026-07-06)】シーン詳細画面 (30 マス拡大 + 完成履歴)。
///
/// SceneSelectionPage からシーンカードタップで遷移。ルート:
///   /puzzle-world/scene/:sceneKey
///
/// 表示内容:
/// - シーン名 + tagline (サビ台詞)
/// - 30 マス拡大 grid (piece_size を大きめに)
/// - 進捗テキスト (輪郭 / 彩り / 未着手)
/// - 完成日時 (completed 時のみ)
///
/// **注**: 現状 Backend の `/scenes/` は piece_states を返さないため、
/// active シーンのみ拡大表示可能 (`puzzleWorldStatusProvider` 経由)。
/// 非 active シーンの詳細ピース状態は Phase 3 以降で扱う (現状は
/// SceneSelectionPage の擬似 mini view で暫定確認可能)。
class PuzzleSceneDetailPage extends ConsumerWidget {
  const PuzzleSceneDetailPage({super.key, required this.sceneKey});

  final String sceneKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final statusAsync = ref.watch(puzzleWorldStatusProvider);
    final scenesAsync = ref.watch(puzzleScenesProvider);

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        title: Text(l10n.puzzleWorldSceneDetailPageTitle),
        backgroundColor: AppTheme.surface,
        foregroundColor: Colors.white,
      ),
      body: (statusAsync.isLoading || scenesAsync.isLoading)
          ? SabiWaitingPanel(
              message: l10n.puzzleWorldSceneDetailLoadingSabi_message)
          : (statusAsync.hasError || scenesAsync.hasError)
              ? const _ErrorState()
              : _buildContent(
                  context,
                  status: statusAsync.value!,
                  sceneList: scenesAsync.value!,
                ),
    );
  }

  Widget _buildContent(
    BuildContext context, {
    required PuzzleWorldStatus status,
    required PuzzleSceneList sceneList,
  }) {
    final l10n = AppLocalizations.of(context)!;
    // scenes リストから該当シーンを取得 (SceneListEntry には status/progress を含む)
    SceneListEntry? entry;
    for (final e in sceneList.scenes) {
      if (e.scene.key == sceneKey) {
        entry = e;
        break;
      }
    }
    if (entry == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            AppLocalizations.of(context)!
                .puzzleWorldSceneDetailNotFoundSabi_message,
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final scene = entry.scene;
    // active シーンの詳細 piece_states は status 側にある。
    final activeDetail =
        (status.activeScene != null && status.activeScene!.scene.key == sceneKey)
            ? status.activeScene
            : null;

    // 表示用 piece_states を組立:
    // - active シーン → 実 piece_states (state 0/1/2 の混合)
    // - 非 active シーン → owned/colored 数から擬似生成 (色は正しく、順序は不明)
    final List<int> pieceStates = activeDetail != null
        ? activeDetail.pieceStates
        : [
            ...List.filled(entry.coloredCount, 2),
            ...List.filled(entry.ownedCount - entry.coloredCount, 1),
            ...List.filled(entry.totalCount - entry.ownedCount, 0),
          ];

    // 完成履歴から該当エントリ検索
    PuzzleHistoryEntry? historyEntry;
    for (final h in status.history) {
      if (h.sceneKey == sceneKey) {
        historyEntry = h;
        break;
      }
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // ── シーン名 + tagline ──────────────────
        Text(
          scene.name,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          scene.tagline,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.75),
            fontSize: 13,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 24),

        // ── 30 マス grid (WorldFrame と同寸法比 = AspectRatio 1.43、6×5) ─
        // 【FEAT-479 hotfix (2026-07-06)】旧 5×6 固定 pieceSize=34 (縦長 島) →
        // WorldFrame overlay と同じ 6 列 × 5 行、AspectRatio(1.43) 内で
        // pieceSize を動的算出。ホームで見ている盤面と同一 UI 語彙で統一。
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: AspectRatio(
            aspectRatio: 1.43,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 【gameplay_review 20260709 §A-2 対応 (2026-07-09)】
                // 旧 columns=6/rows=5 固定は 3-piece シーン (目覚めの山頂) で
                // 「30 マス分の余白の中に 3 マスだけ浮く」問題があった。
                // 3 site (WorldFrame / popup / 本画面) を単一真実値 (utils/piece_grid_layout.dart)
                // の resolvePieceGridLayout に集約、pieceStates.length で動的解決。
                final (columns, rows) = resolvePieceGridLayout(pieceStates.length);
                const spacing = 5.0;
                final maxByW = (constraints.maxWidth - spacing * (columns - 1)) / columns;
                final maxByH = (constraints.maxHeight - spacing * (rows - 1)) / rows;
                final pieceSize = math.min(maxByW, maxByH).floorToDouble();
                return Center(
                  child: PuzzleProgressMiniView(
                    pieceStates: pieceStates,
                    pieceSize: pieceSize,
                    spacing: spacing,
                    columns: columns,
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 20),

        // ── 進捗テキスト ─────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppTheme.card,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _StatPill(
                label: l10n.puzzleWorldStatPillOutline,
                value: entry.ownedCount - entry.coloredCount,
                color: Colors.white.withValues(alpha: 0.7),
              ),
              _StatPill(
                label: l10n.puzzleWorldStatPillColored,
                value: entry.coloredCount,
                color: AppTheme.primary,
              ),
              _StatPill(
                label: l10n.puzzleWorldStatPillUnstarted,
                value: entry.totalCount - entry.ownedCount,
                color: Colors.white.withValues(alpha: 0.3),
              ),
            ],
          ),
        ),

        // ── 完成履歴 ─────────────────────────────
        if (historyEntry != null) ...[
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.puzzleWorldCompletionRecordTitle,
                  style: const TextStyle(
                    color: Colors.amber,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _formatDate(l10n, historyEntry.completedAt),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  '+${historyEntry.rewardExpGained} EXP / '
                  '+${historyEntry.rewardDiamondsGained} 💎',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],

        // ── Hero copy (指示書 §4.4) ───────────────
        const SizedBox(height: 24),
        Text(
          l10n.puzzleWorldSceneDetailHeroCopySabi_message,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.65),
            fontSize: 12,
            height: 1.6,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// 【FEAT-489 Phase 2E】locale ごとの日付表記に対応するため l10n を受け取る。
  String _formatDate(AppLocalizations l10n, DateTime dt) {
    final local = dt.toLocal();
    return l10n.puzzleWorldCompletedDate(local.year, local.month, local.day);
  }
}

class _StatPill extends StatelessWidget {
  const _StatPill({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          '$value',
          style: TextStyle(
            color: color,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: color.withValues(alpha: 0.75),
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          AppLocalizations.of(context)!.puzzleWorldGenericErrorSabi_message,
          style: const TextStyle(color: Colors.white70),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
