import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// 【FEAT-479 Phase 2a (2026-07-06)】30 ピース (5x6) の静的ミニビュー。
///
/// 使用箇所 (Phase 2b で組込予定):
/// - ホーム画面: WorldFrameSection 直下、`displayed_scene` に対応した進捗表示
/// - SceneSelectionPage: 各シーンカードのサムネイル
/// - PuzzleSceneDetailPage: 拡大表示 (`pieceSize` を大きくする)
///
/// 【FEAT-479 Sabi 呼称ルール準拠】:
/// - 灰色 (grey / state=1) = 「輪郭のかけら」
/// - 彩色 (colored / state=2) = 「彩りのかけら」
/// - 未取得 (state=0) = 「まだ眠っているかけら」
///
/// 内部表現は state 0/1/2 の int を維持、UI 表示上は色で分岐 (Sabi 語彙は台詞側で使う)。
class PuzzleProgressMiniView extends StatelessWidget {
  const PuzzleProgressMiniView({
    super.key,
    required this.pieceStates,
    this.pieceSize = 12.0,
    this.spacing = 2.0,
    this.columns = 5,
  });

  /// [0..2] の整数リスト、length = 30 想定。
  final List<int> pieceStates;

  /// 1 ピースの縦横サイズ (px)。ホームは小さく、詳細画面は大きく。
  final double pieceSize;

  /// ピース間の gap (px)。
  final double spacing;

  /// grid の列数 (default 5、30 ピース = 5x6)。
  final int columns;

  @override
  Widget build(BuildContext context) {
    if (pieceStates.isEmpty) {
      return const SizedBox.shrink();
    }

    // 【FEAT-479 (2026-07-06)】columns を実際に反映する explicit Column>Row 構造。
    // 旧 Wrap ベース (幅任せ) だと親の maxWidth に依存してしまい、10 列指定でも
    // 幅不足で強制折り返しが起こり得た。全 usage が columns=5 (default) 前提の
    // 5×6 grid だったので既存 UX 維持しつつ、新設の 10-col MiniStrip 経路を
    // 支援する。
    final rowCount = (pieceStates.length + columns - 1) ~/ columns;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var row = 0; row < rowCount; row++)
          Padding(
            padding: EdgeInsets.only(top: row == 0 ? 0 : spacing),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var col = 0; col < columns; col++)
                  if (row * columns + col < pieceStates.length)
                    Padding(
                      padding: EdgeInsets.only(left: col == 0 ? 0 : spacing),
                      child: _Piece(
                        state: pieceStates[row * columns + col],
                        size: pieceSize,
                      ),
                    ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 個別ピース (state ごとに色分け)。
class _Piece extends StatelessWidget {
  const _Piece({required this.state, required this.size});

  final int state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (color, border) = switch (state) {
      // 彩り (colored) — active primary で明るく
      2 => (
        AppTheme.primary.withValues(alpha: 0.85),
        AppTheme.primary,
      ),
      // 輪郭 (grey / 取得済だが未着色) — 淡い白でエッジのみ
      1 => (
        Colors.white.withValues(alpha: 0.15),
        Colors.white.withValues(alpha: 0.60),
      ),
      // まだ眠っているかけら — ほぼ透明、輪郭も薄い
      _ => (
        Colors.white.withValues(alpha: 0.03),
        Colors.white.withValues(alpha: 0.15),
      ),
    };

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: border, width: 0.8),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
