import 'dart:async' show Completer;
import 'dart:ui' as ui show Image;

import 'package:flutter/material.dart';

// 【gameplay_review 20260709 §A-2】3 site (WorldFrame / popup / SceneDetail) が
// 参照する grid layout の共通 util (真実値)。
import '../../../puzzle_world/utils/piece_grid_layout.dart';

// ─────────────────────────────────────────────────────────────────────────────
// パズルピース枠線 overlay (FEAT-479 hotfix / hybrid hotfix 2026-07-07)
// ─────────────────────────────────────────────────────────────────────────────

/// 【FEAT-479 hotfix (2026-07-06 → v1 pivot 2026-07-07 → hybrid hotfix 2026-07-07)】
/// ワールドフレーム内のピース分割 overlay。CustomPainter で描画:
///  ① 各セル state 別描画:
///     state=0 (未取得)      : 暗い grey 塗り (下 L1 を完全に隠す)
///     state=1 (輪郭/task)   : mono 画像を該当セルに切り抜き描画 (`drawImageRect`)
///     state=2 (彩り/quest)  : color 画像を該当セルに切り抜き描画 (下 L1 と実質同じ
///                            見た目だが、セル境界の罫線でハッキリした「収穫感」を演出)
///  ② 罫線描画 (盤面感維持)
///
/// 【piece_count 混在対応 (v1 pivot 2026-07-07)】:
///   pieceStates.length == 3  → 3 列 × 1 行 (3 vertical strips、目覚めの山頂)
///   pieceStates.length == 30 → 6 列 × 5 行 (既存 30-piece シーン用)
///   その他                    → 6×5 fallback + head-truncate/pad で安全描画
///
/// 3 ピース用のアスペクトは 3 vertical strips (WorldFrame 1.43:1 内で 3 分割 →
/// 各 strip 幅 ~ 0.48, 高さ = 1.0 の縦長領域)。3-piece 完成で「curtain が横に
/// 3 枚並んで剥がれてゆく」演出になる。
///
/// 【hybrid hotfix 2026-07-07】メモリ最適化 (state 変換 StatelessWidget → StatefulWidget):
/// `ResizeImage(AssetImage(path), width: 512, height: 360)` で decode 時に縮小し、
/// 2 画像で ~1.5MB (フルサイズだと ~32MB)。async ロード完了後 setState で
/// `ui.Image?` を Painter に渡す。ロード中は fallback (state=1 は白 tint、
/// state=2 は下 L1 の color 画像がそのまま見える) で挙動維持。
///
/// 【FEAT-487 (2026-07-08)】旧 `world_frame_section.dart` 内 private class
/// `_PuzzleGridOverlay` / `_PuzzleGridPainter` から public 昇格。
class PuzzleGridOverlay extends StatefulWidget {
  const PuzzleGridOverlay({
    required this.pieceStates,
    required this.monoPath,
    required this.colorPath,
    super.key,
  });

  final List<int> pieceStates;

  /// state=1 セル切り抜き用モノクロ画像 asset path。null なら fallback 描画
  /// (半透明白 tint)、ロード失敗時も同じ fallback。
  final String? monoPath;

  /// state=2 セル切り抜き用カラー画像 asset path (L1 と同じ画像)。
  /// null は理論上ないが defensive に空文字扱い。ロード失敗時は下 L1 が透過。
  final String colorPath;

  /// 【hybrid hotfix】ResizeImage の decode 目標サイズ。WorldFrame 実サイズ
  /// (~344×240 論理 × DPR 3 ≈ 1032×720 物理) より小さいが、cell 単位描画で
  /// srcRect / dstRect の解像度は落ちない (drawImageRect の GPU shader で滑らか
  /// 補間される)。512×360 は 1.43 aspect 比率に合わせた妥当な upper bound。
  static const int _kDecodeWidth = 512;
  static const int _kDecodeHeight = 360;

  @override
  State<PuzzleGridOverlay> createState() => _PuzzleGridOverlayState();
}

class _PuzzleGridOverlayState extends State<PuzzleGridOverlay> {
  ui.Image? _monoImage;
  ui.Image? _colorImage;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  @override
  void didUpdateWidget(PuzzleGridOverlay old) {
    super.didUpdateWidget(old);
    // path 変更時のみ再ロード (同じ path の再指定は ImageCache がヒット、Widget
    // 再 build で無駄な load が走らないよう保守)。
    if (old.monoPath != widget.monoPath || old.colorPath != widget.colorPath) {
      _monoImage = null;
      _colorImage = null;
      _loadImages();
    }
  }

  Future<void> _loadImages() async {
    final futures = <Future<ui.Image?>>[
      widget.monoPath != null ? _resolveResizedImage(widget.monoPath!) : Future.value(null),
      _resolveResizedImage(widget.colorPath),
    ];
    final results = await Future.wait(futures);
    if (!mounted) return;
    setState(() {
      _monoImage = results[0];
      _colorImage = results[1];
    });
  }

  /// `ResizeImage(AssetImage)` で decode し `ui.Image` に変換。
  /// ImageStream を listener 経由で受け取り、ロード完了で Completer を complete。
  /// 失敗時は null を返して fallback 描画に委ねる (defense-in-depth)。
  Future<ui.Image?> _resolveResizedImage(String assetPath) async {
    try {
      final provider = ResizeImage(
        AssetImage(assetPath),
        width: PuzzleGridOverlay._kDecodeWidth,
        height: PuzzleGridOverlay._kDecodeHeight,
      );
      final completer = Completer<ui.Image>();
      final stream = provider.resolve(ImageConfiguration.empty);
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (ImageInfo info, bool _) {
          if (!completer.isCompleted) completer.complete(info.image);
          stream.removeListener(listener);
        },
        onError: (Object error, StackTrace? stack) {
          if (!completer.isCompleted) completer.completeError(error);
          stream.removeListener(listener);
        },
      );
      stream.addListener(listener);
      return await completer.future;
    } catch (_) {
      return null;
    }
  }

  // 【gameplay_review 20260709 §A-2 対応】旧 static _resolveLayout は共通 util
  // `puzzle_world/utils/piece_grid_layout.dart` の resolvePieceGridLayout() に
  // 移設済 (3 site 単一真実値化)。本 widget では import 経路経由で参照する。

  @override
  Widget build(BuildContext context) {
    final (columns, rows) = resolvePieceGridLayout(widget.pieceStates.length);
    final expectedLength = columns * rows;

    // 長さ不一致は safe-fall (未着手 seed 未反映等) で足りない cell は state=0 相当。
    // 3 と 30 の合致ケースはそのまま使用、想定外長さ (7/15/50 等) のみ pad/truncate。
    final normalized = widget.pieceStates.length == expectedLength
        ? widget.pieceStates
        : List<int>.generate(
            expectedLength,
            (i) => i < widget.pieceStates.length ? widget.pieceStates[i] : 0,
          );

    return CustomPaint(
      painter: PuzzleGridPainter(
        pieceStates: normalized,
        columns: columns,
        rows: rows,
        monoImage: _monoImage,
        colorImage: _colorImage,
      ),
      size: Size.infinite,
    );
  }
}

/// 【FEAT-479 hotfix (2026-07-06 → hybrid hotfix 2026-07-07)】
/// piece grid + state 別塗り分けを一括描画。
///
/// hybrid hotfix (2026-07-07):
///   - state=0: 暗い grey で塗りつぶし (下 L1 を完全に隠す、alpha 0.88)
///   - state=1: mono 画像を該当セルに `drawImageRect` で切り抜き描画
///     (画像未ロード時は fallback として半透明白 tint、旧挙動維持)
///   - state=2: color 画像を該当セルに `drawImageRect` で切り抜き描画
///     (画像未ロード時は何も描画しない、下 L1 が透過して見える = 旧挙動)
///
/// これで state=1 (タスク達成) と state=2 (クエスト達成) の視覚差が明確に:
///   - state=1: モノクロ画像がその部分だけ浮かぶ (「輪郭のかけら」)
///   - state=2: カラー画像がその部分だけ浮かぶ (「彩りのかけら」)
///
/// 【FEAT-487 (2026-07-08)】旧 `world_frame_section.dart` 内 private class
/// `_PuzzleGridPainter` から public 昇格。
class PuzzleGridPainter extends CustomPainter {
  PuzzleGridPainter({
    required this.pieceStates,
    required this.columns,
    required this.rows,
    this.monoImage,
    this.colorImage,
  });

  final List<int> pieceStates;
  final int columns;
  final int rows;

  /// 【hybrid hotfix 2026-07-07】state=1 セル切り抜き用 mono 画像。
  /// null なら fallback (半透明白 tint) で挙動維持。
  final ui.Image? monoImage;

  /// 【hybrid hotfix 2026-07-07】state=2 セル切り抜き用 color 画像。
  /// null なら描画しない (下 L1 が透過して見える)。
  final ui.Image? colorImage;

  // 塗り Paint (state 別、再利用)
  static final Paint _fillEmpty = Paint()
    ..color = const Color(0xFF404040).withValues(alpha: 0.88);
  static final Paint _fillGrey = Paint()
    ..color = Colors.white.withValues(alpha: 0.06);
  // 画像描画用 Paint (色調整なし、再利用)。
  static final Paint _imagePaint = Paint()
    ..filterQuality = FilterQuality.medium;

  @override
  void paint(Canvas canvas, Size size) {
    final cellW = size.width / columns;
    final cellH = size.height / rows;

    // ── ① セル描画 (state 別) ─────────────────────────────
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < columns; col++) {
        final state = pieceStates[row * columns + col];
        final dstRect = Rect.fromLTWH(col * cellW, row * cellH, cellW, cellH);

        if (state == 0) {
          // 未取得: 暗い grey で完全に隠す
          canvas.drawRect(dstRect, _fillEmpty);
        } else if (state == 1) {
          // 輪郭 (タスク達成): mono 画像をセルに切り抜き描画
          if (monoImage != null) {
            _drawImageCell(canvas, monoImage!, col, row, dstRect);
          } else {
            // 画像未ロード時 fallback: 半透明白 tint (旧挙動)
            canvas.drawRect(dstRect, _fillGrey);
          }
        } else if (state == 2) {
          // 彩り (クエスト達成): color 画像をセルに切り抜き描画
          if (colorImage != null) {
            _drawImageCell(canvas, colorImage!, col, row, dstRect);
          }
          // colorImage null: 何も描画しない (下 L1 が見える、旧挙動)
        }
      }
    }

    // ── ② 罫線 (縦横グリッド、全セル一律で盤面感維持) ────────────
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.45)
      ..strokeWidth = 0.9
      ..style = PaintingStyle.stroke;

    // 縦線 (0 〜 columns 本、両端含む)
    for (var col = 0; col <= columns; col++) {
      final x = col * cellW;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    // 横線 (0 〜 rows 本、両端含む)
    for (var row = 0; row <= rows; row++) {
      final y = row * cellH;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  /// 【hybrid hotfix 2026-07-07】画像の該当セル部分だけを dstRect に切り抜き描画。
  ///
  /// srcRect: 画像全体を columns × rows で分割した「(col, row) のセル」領域。
  /// dstRect: canvas 上のセル領域 (caller が計算済)。
  ///
  /// これで 1 枚の画像を 30 分割 (or 3 分割) して、state に該当するセルだけを
  /// 見せる = 「モノクロ画像/カラー画像がその部分だけ見える」体験を実現。
  void _drawImageCell(
    Canvas canvas,
    ui.Image image,
    int col,
    int row,
    Rect dstRect,
  ) {
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();
    final srcCellW = imgW / columns;
    final srcCellH = imgH / rows;
    final srcRect = Rect.fromLTWH(
      col * srcCellW,
      row * srcCellH,
      srcCellW,
      srcCellH,
    );
    canvas.drawImageRect(image, srcRect, dstRect, _imagePaint);
  }

  @override
  bool shouldRepaint(PuzzleGridPainter old) {
    if (old.columns != columns || old.rows != rows) return true;
    // 【hybrid hotfix 2026-07-07】画像参照変化も再描画対象
    if (old.monoImage != monoImage || old.colorImage != colorImage) return true;
    if (old.pieceStates.length != pieceStates.length) return true;
    for (var i = 0; i < pieceStates.length; i++) {
      if (old.pieceStates[i] != pieceStates[i]) return true;
    }
    return false;
  }
}
