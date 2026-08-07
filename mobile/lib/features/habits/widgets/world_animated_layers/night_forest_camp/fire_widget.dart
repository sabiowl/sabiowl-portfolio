import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../world_animated_layer_base.dart';

/// 【新規 (2026-06-25)】焚火スプライトシート再生ウィジェット (L2)。
///
/// fire_sheet.png (1536 × 1024、横一列 8 frame = 192 × 1024/frame) を
/// 10 FPS で連続切替してループ表示する。`rootBundle` で `ui.Image` に
/// 一度だけデコードし、`CustomPainter.drawImageRect` でフレーム抜き出し。
///
/// 動画 (GIF/WebP) を使わない実装 ([Gemini 指示]: SpriteSheet/CustomPainter)。
///
/// 表示位置とサイズ:
///   - [_kFirePosition]: 背景画像内の焚火位置 (TUNABLE、実機で要調整)
///   - [_kFireDisplaySize]: 表示サイズ (高さ基準、アスペクトはスプライト追従)
///
/// パフォーマンス:
///   - Timer.periodic(100ms) で `_frame` カウンタ更新、`setState` で
///     `CustomPaint` の `shouldRepaint` 経路を駆動
///   - dispose / pauseAnimations で確実に Timer cancel
class FireWidget extends WorldAnimatedLayerBase {
  const FireWidget({super.key});

  @override
  State<FireWidget> createState() => _FireWidgetState();
}

class _FireWidgetState extends WorldAnimatedLayerBaseState<FireWidget> {
  // ── 焚火スプライト定数 (10FPS / Loop) ──────────────────────────────────
  // 【更新 (2026-07-18 #9)】user が fire_sheet.png を再々修正 (低解像度版
  // 707×353、8 frame)。石は bg PNG 側で描画される想定。
  static const String _kSpritePath =
      'assets/images/backgrounds/world/fire_sheet.webp';
  static const int _kFrameCount = 8;
  static const Duration _kFrameDuration = Duration(milliseconds: 100);

  // ── スプライトソース矩形クロップ (炎本体のみ抽出) ─────────────────────
  //
  // 【更新 (2026-07-18 #9)】新 sprite (8 frame, 707×353) の実測に合わせて再設計。
  //
  // 【実測: 各 frame の炎中心 x】(sheet 全体座標)
  //   [50, 140, 222, 313, 396, 484, 570, 661]
  //   間隔 ~87 px、絵柄は等間隔ではなく作画上の揺れあり。
  // 【炎 y 範囲 (全 frame 統合)】: y=139..237 = height 98
  // 【炎 x 範囲 (frame ごと)】: 48-54 px (最大 54) → crop 幅 60 で安全
  //
  // per-frame src.x を lookup table から取り、幅 60 のクロップを常に flame
  // 中心に配置 → 全 frame で炎中心が dst 中央に自動的に揃う (per-frame
  // オフセット補正が不要)。
  static const List<double> _kFrameCenterX = [
    50.0, 140.0, 222.0, 313.0, 396.0, 484.0, 570.0, 661.0,
  ];
  static const double _kSpriteFrameEffWidth = 60.0;   // 炎最大幅 54 + 両端余裕
  static const double _kSpriteSrcCropTop    = 139.0;  // 全 frame 炎 top
  static const double _kSpriteSrcCropHeight = 98.0;   // 全 frame 炎 height

  // ── フレーム間位置揃え方式 (2026-07-18 #7) ────────────────────────────
  //
  // 新 sprite は _kFrameCenterX から flame 中心を lookup して 130 幅で crop
  // するため、per-frame の dst.x シフト補正は不要。中心が自動的に揃う。

  // ── 焚火表示位置 / サイズ (TUNABLE、背景の静止炎をオーバーレイ) ─────────
  //
  // Alignment(-1..+1, -1..+1) 系で背景内の焚火位置を指定。
  //   x = 0 (横中央)、y = +1 (下端)、y = -1 (上端)
  //
  // 【方針変更 v4 (2026-06-25)】background (world_night_forest_camp.png) に
  // 焚火が焼き込まれているため、sprite は「炎部分」を完全に覆って静止炎を
  // アニメーション炎で置き換える設計。薪部分は背景に残してそちらを流用。
  //
  // 【再計測 (2026-07-18)】bg PNG (255×196) の warm pixel 分布から実測:
  //   - 炎中心 bg px (107, 142) → x_pct ≈ 0.42, y_pct ≈ 0.72
  //   - 親 AspectRatio 1.43 vs bg 1.30 の BoxFit.cover 上下 4.5% トリム補正込みで
  //     x_alignment = -0.16, y_alignment = 0.41
  //   - 炎の幅 ≈ 44% × 高さ ≈ 27% (warm 発光を含む、実炎本体はより小さい)
  //
  // 旧 tune (0.10, 0.08) は古い bg PNG 用で、bg 差替え時に追随忘れ。
  // 結果として sprite (中央上) と背景静止炎 (左下) が別位置で表示 =
  // 「焚火が 2 つ、片方が動く」問題の原因。
  //
  // 【更新 (2026-07-18)】bg PNG を高解像度 no-fire 版 (1431×1099) に差替後、
  // 目視で焚火円 (テント下端 + log 前の "地面円") 位置に合わせて y を下方向
  // にシフト。
  // 【再調整 (2026-07-18 #2)】目視 iter#2: sprite がテント左寄りに寄って
  // いたため x を +0.20 右シフト、y も +0.10 下シフトして center-bottom へ。
  // 【再調整 (2026-07-18 #10)】user 修正 bg PNG (石囲み描画済) に対して炎が
  // 石囲みより上に位置していたため、y を +0.15 下シフトして石囲み内に着地。
  static const Alignment _kFirePosition = Alignment(0.19, 0.68);

  // 表示サイズ (px):
  // 【更新 (2026-07-18 #9)】新 crop 60×98 aspect 1:1.63 に合わせて 55×90。
  static const double _kFireDisplayWidth  = 55.0;
  static const double _kFireDisplayHeight = 90.0;

  // ── 内部状態 ─────────────────────────────────────────────────────────
  ui.Image? _sprite;
  int _frame = 0;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _loadSprite();
    _start();
  }

  Future<void> _loadSprite() async {
    try {
      final data = await rootBundle.load(_kSpritePath);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final fi = await codec.getNextFrame();
      if (!mounted) {
        fi.image.dispose();
        return;
      }
      setState(() => _sprite = fi.image);
    } catch (e) {
      debugPrint('[FireWidget] sprite load failed: $e');
      // フォールバック: sprite 未ロードのまま SizedBox.shrink を返す。
    }
  }

  void _start() {
    _ticker?.cancel();
    _ticker = Timer.periodic(_kFrameDuration, (_) {
      if (!mounted) return;
      setState(() => _frame = (_frame + 1) % _kFrameCount);
    });
  }

  void _stop() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void pauseAnimations() {
    _stop();
  }

  @override
  void resumeAnimations() {
    if (_ticker == null && mounted) _start();
  }

  @override
  void dispose() {
    _stop();
    _sprite?.dispose();
    _sprite = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sprite = _sprite;
    if (sprite == null) return const SizedBox.shrink();

    return Align(
      alignment: _kFirePosition,
      child: SizedBox(
        width: _kFireDisplayWidth,
        height: _kFireDisplayHeight,
        child: CustomPaint(
          painter: _FireSpritePainter(image: sprite, frame: _frame),
        ),
      ),
    );
  }
}

class _FireSpritePainter extends CustomPainter {
  _FireSpritePainter({required this.image, required this.frame});

  final ui.Image image;
  final int frame;

  @override
  void paint(Canvas canvas, Size size) {
    // 【更新 (2026-07-18 #7)】per-flame 中心 x を lookup、幅 130 の crop を
    // その中心に配置。全 frame で炎中心が sub-rect 中央に揃うため、per-frame
    // dst.x シフト補正が不要。
    final centerX = _FireWidgetState._kFrameCenterX[frame];
    final srcW = _FireWidgetState._kSpriteFrameEffWidth;  // 130
    final srcH = _FireWidgetState._kSpriteSrcCropHeight;  // 217
    final srcX = centerX - srcW / 2;
    final srcY = _FireWidgetState._kSpriteSrcCropTop;     // 368
    final src = Rect.fromLTWH(srcX, srcY, srcW, srcH);
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    // filterQuality.none = ピクセルアートの輪郭を保つ (BUG-12b 系の経験則)
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.none,
    );
  }

  @override
  bool shouldRepaint(covariant _FireSpritePainter old) =>
      old.frame != frame || !identical(old.image, image);
}
