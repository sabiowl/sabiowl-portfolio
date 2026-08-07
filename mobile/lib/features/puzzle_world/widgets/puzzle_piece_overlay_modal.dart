import 'dart:async' show Completer;
import 'dart:math' as math;
import 'dart:ui' as ui show Image;

import 'package:flutter/material.dart';

import '../../../core/router/app_router.dart' show rootNavigatorKey;  // 【2026-07-08 hotfix】
import '../../../core/theme/app_theme.dart';
// 【2026-07-09】背景画像を popup 内に切り抜き描画するために scene 画像 path を解決。
import '../../../l10n/app_localizations.dart';
import '../../habits/services/world_background_service.dart';
import '../utils/piece_grid_layout.dart';  // 【gameplay_review 20260709 §A-2】3 site 単一真実値化
import 'puzzle_progress_mini_view.dart';

/// 【FEAT-479 Phase 3 (2026-07-06)】Task piece / Quest piece 演出モーダル。
///
/// 指示書 §4.3.1-4.3.3 に準拠:
/// - **フルスクリーンモーダル** (画面遷移を物理的にブロック、演出完全視聴を保証)
/// - `showGeneralDialog` + `barrierDismissible: false`
///   + `barrierColor: Colors.black.withValues(alpha: 0.35)` (背景 dim)
/// - 【2026-07-06 hotfix】auto-dismiss を廃止 → アニメ完了後は静止状態を維持し、
///   ユーザーが X ボタン (右上) or 戻るジェスチャで **明示的に close** するまで
///   表示継続。旧仕様の「Task 800ms/Quest 1200ms で自動 pop」は Sabi 「静かな
///   聖域」哲学と整合せず、後続 popup (LoginBonusCalendarDialog 等) と唐突に
///   切替わる問題があった。演出時間 (アニメ) はそのまま、close はユーザー主導。
/// - 【2026-07-06 hotfix】canPop: false → true。閉じる X ボタン追加と併せて
///   Android システム戻るも許容 (ユーザー safety net)。
/// - BUG-65 遵守: モーダル閉じる → 呼び出し元で `await Future.delayed(300ms)` は
///   caller responsibility (listener 側で対応)
/// - BUG-66 遵守: 演出用 AnimationController は dispose() で cancel、setState 呼ばない
///
/// **Task piece** (§4.3.2、~800ms):
/// - ピースが grid 上端から 200ms 直線飛来 → 該当マスへ収束 (400ms、easeOutCubic)
/// - 到達時に軽微な光 (white alpha 0.4 blur 6 → 0 の 300ms fade)
///
/// **Quest piece** (§4.3.3、~1200ms):
/// - 対象マスが薄墨 → 彩色 に 800ms 遷移 (grayscale → sepia → full color)
/// - 呼吸するような光 (boxShadow alpha 0 → 0.3 → 0、1000ms)
///
/// **完成モーダル**: **Phase 4a-4b で実装済 (`puzzle_completion_modal.dart`)**。
/// quest 完成時 (`scene_completed=true`) は `puzzle_piece_listener.dart:
/// _handleSceneCompletion` が本 overlay 後に `showPuzzleCompletionOverlay`
/// を PopupSerializer 経由で起動 (白フェード + 中央 fadeIn + hasNextScene
/// 分岐 + 「見守る」単一ボタン、BUG-138 単一情報ダイアログ例外)。
class PuzzlePieceOverlayModal extends StatefulWidget {
  const PuzzlePieceOverlayModal.taskAwarded({
    super.key,
    required this.pieceStates,
    required this.pieceIndex,
    required this.sceneName,
    this.backgroundKey,
  })  : _mode = _OverlayMode.taskAwarded;

  const PuzzlePieceOverlayModal.questColored({
    super.key,
    required this.pieceStates,
    required this.pieceIndex,
    required this.sceneName,
    this.backgroundKey,
  })  : _mode = _OverlayMode.questColored;

  final _OverlayMode _mode;

  /// 演出時点のピース状態 (演出前、つまり task なら未取得の 0、quest なら grey の 1)。
  /// 演出後は listener が provider invalidate で最新化する想定。
  final List<int> pieceStates;

  /// アニメーション対象のピース index (0-based)。
  final int pieceIndex;

  /// シーン名 (画面上部に控えめに表示)。
  final String sceneName;

  /// 【2026-07-09】アクティブシーンの `background_key` (Backend `PuzzleWorldScene`)。
  /// non-null なら popup 内に実際の背景画像を切り抜き描画 (state=1 は mono、state=2
  /// は color を該当セルにピンポイント表示、WorldFrame と同じ視覚パターン)。
  /// null (旧経路 / seed 未反映 edge case) の場合は従来通り抽象色ブロック描画。
  final String? backgroundKey;

  @override
  State<PuzzlePieceOverlayModal> createState() =>
      _PuzzlePieceOverlayModalState();
}

enum _OverlayMode { taskAwarded, questColored }

class _PuzzlePieceOverlayModalState extends State<PuzzlePieceOverlayModal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  // 【2026-07-09】非同期でロードした mono / color 背景画像。
  // null = 未ロード or backgroundKey null → _PopupPieceGridPainter が抽象色 fallback で描画。
  // WorldFrame の PuzzleGridOverlay と同じ ResizeImage による decode 縮小 pattern。
  ui.Image? _monoImage;
  ui.Image? _colorImage;

  Duration get _totalDuration => switch (widget._mode) {
        _OverlayMode.taskAwarded => const Duration(milliseconds: 800),
        _OverlayMode.questColored => const Duration(milliseconds: 1200),
      };

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _totalDuration,
    );
    _controller.forward();
    // 【2026-07-06 hotfix】auto-dismiss ロジックを撤去。
    // 旧: `_controller.addStatusListener((status) { ... maybePop() })` で
    //     アニメ完了 (Task 800ms / Quest 1200ms) と同時に強制 close。
    // 問題: ユーザーが piece 獲得を認識する暇なく後続 popup
    //      (LoginBonusCalendarDialog 等) に切替 → 演出見損ね + 唐突感。
    // 現行: アニメ完了後は静止状態を維持、ユーザーが X ボタン or 戻る
    //       ジェスチャで明示的に close するまで表示継続。
    //       PopupSerializer が Future 完了を待つ設計のため、手動 close で
    //       resolve → 次の queue アイテムに正しく進む。
    //       Sabiowl 世界観「静かな聖域」原則 (ユーザー主導のペース) と整合。

    // 【2026-07-09】背景画像を非同期ロード。ロード中は抽象色 fallback で描画される。
    // popup 表示直後の一瞬 (通常 <100ms) は fallback、ImageCache がヒットする 2 回目
    // 以降は同期的に取れるため 実質瞬間で切替。
    if (widget.backgroundKey != null) {
      _loadImages();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadImages() async {
    final key = widget.backgroundKey!;
    final monoPath  = WorldBackgroundService.monoPathForBackgroundKey(key);
    final colorPath = WorldBackgroundService.pathForBackgroundKey(key);
    final results = await Future.wait([
      if (monoPath != null) _loadImageResized(monoPath) else Future.value(null),
      if (colorPath != null) _loadImageResized(colorPath) else Future.value(null),
    ]);
    if (!mounted) return;
    setState(() {
      _monoImage  = results[0];
      _colorImage = results[1];
    });
  }

  /// AssetImage を ResizeImage で decode 縮小してから ui.Image を取得。
  /// popup は WorldFrame より小さいため 256×180 で十分 (memory 節約)。
  static Future<ui.Image?> _loadImageResized(String assetPath) async {
    final completer = Completer<ui.Image?>();
    final provider = ResizeImage(
      AssetImage(assetPath),
      width: 256,
      height: 180,
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, sync) {
        if (!completer.isCompleted) completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (e, st) {
        if (!completer.isCompleted) completer.complete(null);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 【FEAT-479 hotfix (2026-07-06)】canPop: false → true。
      // 閉じるボタン (X) を追加したため、Android システム戻るも許容 (auto-dismiss と
      // 併存)。auto-dismiss タイマー未完了時のユーザー安全策。
      canPop: true,
      child: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Container(
              margin: const EdgeInsets.all(20),
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              decoration: BoxDecoration(
                color: AppTheme.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.4),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha: 0.15),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── ヘッダ (シーン名 + 閉じる X) ────────
                  // 【UX Review 2026-07-06 P1-1】 close IconButton の
                  // タップ対象を Apple HIG 44pt / Material 48dp 基準まで
                  // 拡大 (旧 32×32 → 44×44)、左スペーサも合わせて 44px。
                  // 演出中のミスタップ率を下げる。
                  Row(
                    children: [
                      const SizedBox(width: 44),  // 左バランス spacer (X ボタンと同幅)
                      Expanded(
                        child: Text(
                          widget.sceneName,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context, rootNavigator: true).maybePop(),
                        icon: Icon(
                          Icons.close,
                          color: Colors.white.withValues(alpha: 0.65),
                          size: 20,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                        splashRadius: 22,
                        tooltip: AppLocalizations.of(context)!
                            .puzzleWorldPieceOverlayCloseTooltip,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // ── グリッド (WorldFrame と同寸法比 = AspectRatio 1.43) ─
                  AspectRatio(
                    aspectRatio: 1.43,
                    child: AnimatedBuilder(
                      animation: _controller,
                      builder: (context, _) => _buildAnimatedGrid(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    switch (widget._mode) {
                      _OverlayMode.taskAwarded => AppLocalizations.of(context)!
                          .puzzleWorldPieceAwardedSabi_message,
                      _OverlayMode.questColored => AppLocalizations.of(context)!
                          .puzzleWorldPieceColoredSabi_message,
                    },
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      height: 1.6,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAnimatedGrid() {
    final progress = _controller.value;

    return switch (widget._mode) {
      _OverlayMode.taskAwarded => _buildTaskAnimation(progress),
      _OverlayMode.questColored => _buildQuestAnimation(progress),
    };
  }

  // ── 【FEAT-479 v1 pivot 追従 hotfix (2026-07-09) + §A-2 util 化 (2026-07-09)】──
  //
  // 旧: static const 6 列 × 5 行 (30 マス固定)。
  // 問題: 2026-07-07 の morning_grassland (目覚めの山頂) piece_count 30 → 3
  //       pivot (migration 0178) に追従漏れで残り 27 マスが空白描画されていた。
  // 修正: 共通 util (../utils/piece_grid_layout.dart) の
  //       resolvePieceGridLayout(pieceStates.length) を使って 3 site
  //       (WorldFrame / popup / SceneDetail) で同期。
  //
  // 参照実装 (真実値): utils/piece_grid_layout.dart:resolvePieceGridLayout()。
  static const double _gridSpacing = 4.0;

  /// AspectRatio 内で pieceSize を動的算出。
  /// 縦横それぞれの制約から min を取り、grid が container に確実に収まる形。
  double _computePieceSize(BoxConstraints constraints, int columns, int rows) {
    final maxByW =
        (constraints.maxWidth - _gridSpacing * (columns - 1)) / columns;
    final maxByH =
        (constraints.maxHeight - _gridSpacing * (rows - 1)) / rows;
    return math.min(maxByW, maxByH).floorToDouble();
  }

  /// Task piece 演出 (800ms):
  /// - 0-25% (0-200ms): ピースが grid 上から飛来 (opacity 0→1、Y 相対 -1.2→0)
  /// - 25-75% (200-600ms): grid 到達 + 光 (opacity 0.4→0)
  /// - 75-100% (600-800ms): 静止 + 定着
  Widget _buildTaskAnimation(double t) {
    final flyPhase = (t / 0.25).clamp(0.0, 1.0);
    final flyOpacity = flyPhase;
    final glowPhase = ((t - 0.25) / 0.5).clamp(0.0, 1.0);
    final glowAlpha = 0.4 * (1 - glowPhase);

    final displayStates = List<int>.from(widget.pieceStates);
    if (flyPhase >= 0.5 && widget.pieceIndex < displayStates.length) {
      displayStates[widget.pieceIndex] = 1;
    }

    // 【2026-07-09 fix】WorldFrame 側 _resolveLayout と同じ動的分岐。
    // 3-piece scene (目覚めの山頂) では 3×1 になり、旧 6×5 固定時の
    // 「残り 27 マス空白」問題を解消する。
    final (columns, rows) = resolvePieceGridLayout(widget.pieceStates.length);
    return LayoutBuilder(
      builder: (context, constraints) {
        final pieceSize = _computePieceSize(constraints, columns, rows);
        // 飛来オフセット: pieceSize の 1.2 倍だけ上から降る (画面サイズに追従)
        final flyOffset = -pieceSize * 1.2 * (1 - flyPhase);
        return Center(
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Transform.translate(
                offset: Offset(0, flyOffset * 0.15),
                child: Opacity(
                  opacity: 0.6 + 0.4 * flyPhase,
                  child: _buildPieceGrid(
                    displayStates: displayStates,
                    columns: columns,
                    rows: rows,
                    pieceSize: pieceSize,
                  ),
                ),
              ),
              if (glowAlpha > 0.01)
                IgnorePointer(
                  child: Container(
                    // 光の広がりは grid 面積の平方根ベース (6×5 で 5, 3×1 で 2 前後)、
                    // 3-piece でも極端に大きくならないよう控えめに算出。
                    width: pieceSize * math.max(3, math.sqrt(columns * rows) + 1),
                    height: pieceSize * math.max(3, math.sqrt(columns * rows) + 1),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: glowAlpha * 0.35),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.white.withValues(alpha: glowAlpha * 0.6),
                          blurRadius: 6 * (1 - glowPhase) + 4,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ),
              if (flyPhase < 1.0)
                Positioned(
                  top: flyOffset,
                  child: Opacity(
                    opacity: flyOpacity,
                    child: Container(
                      width: pieceSize,
                      height: pieceSize,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.6),
                          width: 1,
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 【2026-07-09】背景画像がロード済なら image-based 描画、未ロード or backgroundKey
  /// null なら従来通り抽象 `PuzzleProgressMiniView` にフォールバック。
  ///
  /// image-based は WorldFrame と同じ「セル単位切り抜き」パターン (下記 _PopupPieceGridPainter):
  ///   - state=0: 暗い grey で完全に隠す (未取得の空白マス感)
  ///   - state=1: mono 画像を該当セルに切り抜き (輪郭のかけら)
  ///   - state=2: color 画像を該当セルに切り抜き (彩りのかけら)
  /// popup では `_gridSpacing: 4.0` を維持 (パズルピース感を優先)。
  Widget _buildPieceGrid({
    required List<int> displayStates,
    required int columns,
    required int rows,
    required double pieceSize,
  }) {
    // 背景画像が有効: image-based CustomPaint。
    if (_monoImage != null || _colorImage != null) {
      final totalW = pieceSize * columns + _gridSpacing * (columns - 1);
      final totalH = pieceSize * rows    + _gridSpacing * (rows - 1);
      return SizedBox(
        width:  totalW,
        height: totalH,
        child: CustomPaint(
          painter: _PopupPieceGridPainter(
            pieceStates: displayStates,
            columns: columns,
            rows: rows,
            spacing: _gridSpacing,
            monoImage:  _monoImage,
            colorImage: _colorImage,
          ),
        ),
      );
    }
    // Fallback: 抽象色ブロック (旧経路 or ロード中 / backgroundKey 未指定)。
    return PuzzleProgressMiniView(
      pieceStates: displayStates,
      pieceSize: pieceSize,
      spacing: _gridSpacing,
      columns: columns,
    );
  }

  /// Quest piece 演出 (1200ms):
  /// - 0-66% (0-800ms): 対象マスが grey → colored に遷移 (色補間)
  /// - 33-100% (400-1200ms): 呼吸光 (alpha 0→0.3→0)
  Widget _buildQuestAnimation(double t) {
    final colorPhase = (t / 0.66).clamp(0.0, 1.0);
    final breathPhase = ((t - 0.33) / 0.67).clamp(0.0, 1.0);
    final breathAlpha = breathPhase < 0.5
        ? 0.3 * (breathPhase * 2)
        : 0.3 * (1 - (breathPhase - 0.5) * 2);

    final displayStates = List<int>.from(widget.pieceStates);
    if (colorPhase >= 0.5 && widget.pieceIndex < displayStates.length) {
      displayStates[widget.pieceIndex] = 2;
    }

    // 【2026-07-09 fix】task 経路と同じく pieceStates.length から動的解決。
    final (columns, rows) = resolvePieceGridLayout(widget.pieceStates.length);
    return LayoutBuilder(
      builder: (context, constraints) {
        final pieceSize = _computePieceSize(constraints, columns, rows);
        return Center(
          child: Stack(
            alignment: Alignment.center,
            children: [
              _buildPieceGrid(
                displayStates: displayStates,
                columns: columns,
                rows: rows,
                pieceSize: pieceSize,
              ),
              if (breathAlpha > 0.01)
                IgnorePointer(
                  child: Container(
                    // 呼吸光の外枠 = grid の実寸に padding 16 を加えたサイズ。
                    // 6×5 でも 3×1 でも grid ピッタリを包む形になる。
                    width: pieceSize * columns +
                        _gridSpacing * (columns - 1) + 16,
                    height: pieceSize * rows +
                        _gridSpacing * (rows - 1) + 16,
                    decoration: BoxDecoration(
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primary.withValues(alpha: breathAlpha),
                          blurRadius: 20,
                          spreadRadius: 6,
                        ),
                      ],
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// 【2026-07-09】popup 用 CustomPainter: 実際のシーン背景を切り抜き描画。
// ─────────────────────────────────────────────────────────────────────────────
//
// WorldFrame の `PuzzleGridPainter` を popup 用に再実装 (spacing 対応版)。
// WorldFrame 側は spacing=0 で「連続画像」感を優先、popup 側は spacing=4.0 で
// 「パズルピース」感を優先するため、painter を別実装した。
//
// 描画ルール (WorldFrame と一致):
//   - state=0: 暗い grey で塗りつぶし (未取得の空白マス、alpha 0.88)
//   - state=1: mono 画像を該当セルに `drawImageRect` で切り抜き描画
//     (画像未ロード時 fallback: 半透明白 tint)
//   - state=2: color 画像を該当セルに切り抜き描画
//     (画像未ロード時 fallback: 何も描画しない)
//
// srcRect の計算:
//   - popup grid は spacing で分割されるが、画像は「連続した 1 枚絵」を保つ意味で
//     srcRect は spacing を考慮せず、画像全体を columns × rows で等分する。
//   - dstRect は spacing 込みで各セル位置に配置。
//   - 結果: 各セルに「本来隣接する部分」の画像が入り、user 視点では「一枚絵を
//     spacing で切り分けたパズルピース」に見える。
class _PopupPieceGridPainter extends CustomPainter {
  _PopupPieceGridPainter({
    required this.pieceStates,
    required this.columns,
    required this.rows,
    required this.spacing,
    this.monoImage,
    this.colorImage,
  });

  final List<int> pieceStates;
  final int columns;
  final int rows;
  final double spacing;
  final ui.Image? monoImage;
  final ui.Image? colorImage;

  // 塗り Paint (state 別、再利用)
  static final Paint _fillEmpty = Paint()
    ..color = const Color(0xFF404040).withValues(alpha: 0.88);
  static final Paint _fillGrey = Paint()
    ..color = Colors.white.withValues(alpha: 0.06);
  static final Paint _imagePaint = Paint()
    ..filterQuality = FilterQuality.medium;

  @override
  void paint(Canvas canvas, Size size) {
    // dstRect 用のセルサイズ = 全体幅から spacing 分を引いて等分
    final cellW = (size.width  - spacing * (columns - 1)) / columns;
    final cellH = (size.height - spacing * (rows    - 1)) / rows;

    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < columns; col++) {
        final state = pieceStates[row * columns + col];
        final dstLeft = col * (cellW + spacing);
        final dstTop  = row * (cellH + spacing);
        final dstRect = Rect.fromLTWH(dstLeft, dstTop, cellW, cellH);

        if (state == 0) {
          canvas.drawRect(dstRect, _fillEmpty);
        } else if (state == 1) {
          if (monoImage != null) {
            _drawImageCell(canvas, monoImage!, col, row, dstRect);
          } else {
            canvas.drawRect(dstRect, _fillGrey);
          }
        } else if (state == 2) {
          if (colorImage != null) {
            _drawImageCell(canvas, colorImage!, col, row, dstRect);
          }
        }
      }
    }
  }

  /// 画像を「連続 1 枚絵として column/row 等分」して切り抜き、dstRect に描画。
  /// srcRect は spacing を考慮せず、画像全体を columns × rows で等分。
  void _drawImageCell(Canvas canvas, ui.Image img, int col, int row, Rect dstRect) {
    final srcCellW = img.width  / columns;
    final srcCellH = img.height / rows;
    final srcRect = Rect.fromLTWH(
      col * srcCellW,
      row * srcCellH,
      srcCellW,
      srcCellH,
    );
    canvas.drawImageRect(img, srcRect, dstRect, _imagePaint);
  }

  @override
  bool shouldRepaint(_PopupPieceGridPainter old) {
    // ui.Image は同一 instance 判定で十分 (差し替わったら再描画)。
    return old.pieceStates != pieceStates ||
        old.monoImage != monoImage ||
        old.colorImage != colorImage ||
        old.columns != columns ||
        old.rows != rows ||
        old.spacing != spacing;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// showPuzzlePieceOverlay: 呼び出し側からの entry point
// ─────────────────────────────────────────────────────────────────────────────

/// Task piece 演出を発火。await で「モーダル完全 close」まで待てる。
/// caller は BUG-65 遵守で await 後に Future.delayed(300ms) を挟んでから
/// navigation 等の副作用を発火する想定。
Future<void> showPuzzlePieceTaskOverlay(
  BuildContext context, {
  required List<int> pieceStates,
  required int pieceIndex,
  required String sceneName,
  String? backgroundKey,
}) async {
  // 【2026-07-08 hotfix】caller の context (PuzzlePieceListener State.context) は
  // MaterialApp.router.builder 内 = go_router の Router/Navigator の祖先に位置し、
  // `Navigator.of(context, rootNavigator: true)` が祖先探索で null crash
  // ("TypeError: Null check operator used on a null value") を起こす経路。
  // rootNavigatorKey.currentContext は Navigator 内側の context のため、
  // 直接そこから showGeneralDialog を叩けば構造的に crash しない (fallback で
  // caller context も許可し、rootNavigatorKey が万が一 null の起動直後もカバー)。
  // 参考: 旧「global hotfix 2026-07-07」の `useRootNavigator: true` は祖先に
  // Navigator が居ることが前提で、本 caller の位置では成立しなかった。
  final navContext = rootNavigatorKey.currentContext ?? context;
  await showGeneralDialog<void>(
    context: navContext,
    // navContext は既に Navigator 内側 = rootNavigator 走査は不要 (false)。
    useRootNavigator: false,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (_, __, ___) => PuzzlePieceOverlayModal.taskAwarded(
      pieceStates: pieceStates,
      pieceIndex: pieceIndex,
      sceneName: sceneName,
      backgroundKey: backgroundKey,
    ),
  );
}

/// Quest piece 演出を発火。
Future<void> showPuzzlePieceQuestOverlay(
  BuildContext context, {
  required List<int> pieceStates,
  required int pieceIndex,
  required String sceneName,
  String? backgroundKey,
}) async {
  // 【2026-07-08 hotfix】task overlay と同構造 (詳細は showPuzzlePieceTaskOverlay 参照)。
  final navContext = rootNavigatorKey.currentContext ?? context;
  await showGeneralDialog<void>(
    context: navContext,
    useRootNavigator: false,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (_, __, ___) => PuzzlePieceOverlayModal.questColored(
      pieceStates: pieceStates,
      pieceIndex: pieceIndex,
      sceneName: sceneName,
      backgroundKey: backgroundKey,
    ),
  );
}

/// 【使用側 responsibility】overlay dismiss と provider 状態変化の順序をぶらさない。
/// - モーダル完全 dispose を待つ: `Future.delayed(300ms)` (Material transition + マージン)
/// - listener が次アクション (invalidate / navigation) を発火するのはこの後
///
/// 詳細は CLAUDE.md「dialog から navigation する時は caller が showDialog の結果で分岐」参照。
const Duration puzzleOverlayDismissBuffer = Duration(milliseconds: 300);
