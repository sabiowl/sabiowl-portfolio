import 'dart:math' as math;  // 【新規 (2026-07-05)】ランダム開始位置 + sin 波揺れ

import 'package:flutter/material.dart';

import 'world_animated_layer_base.dart';

/// 【新規 (2026-06-25)】雲レイヤーウィジェット (汎用、左方向ゆっくり横断スクロール)。
///
/// 透過 PNG (`cloud_layer.png` 等) を背景画像と同じサイズで配置し、
/// `Transform.translate` で左方向にスクロールさせる。シームレスループは
/// 「同一画像を 2 枚水平に並べて両方を同じ速度で左へ移動 → 画像幅 1 つ分
/// スクロールしたらリセット」の古典パターン (継ぎ目が見えない)。
///
/// ## Gemini world_frame_camp.md 仕様
///
/// - 移動方向: 左のみ
/// - 移動速度: 40〜80 秒で画面横断 (default 60 秒)
/// - 動画 (GIF/WebP) を使わず Transform.translate でリアルタイム描画
///
/// ## 拡張性: Cloud Layer 1 / Cloud Layer 2 への分割
///
/// 本ウィジェットは [assetPath] / [crossDurationSec] / [opacity] を引数化
/// しているため、Stack に複数並べることで「奥 (遅い・薄い) と 手前 (速い・濃い)」
/// の視差スクロール (パララックス) を実現可能:
///
/// ```dart
/// Stack(children: [
///   // 奥 (遅い、薄い)
///   CloudLayerWidget(
///     assetPath: 'assets/images/backgrounds/world/cloud_layer_2.webp',
///     crossDurationSec: 80.0,
///     opacity: 0.6,
///   ),
///   // 手前 (速い、はっきり)
///   CloudLayerWidget(
///     assetPath: 'assets/images/backgrounds/world/cloud_layer.webp',
///     crossDurationSec: 50.0,
///   ),
/// ])
/// ```
///
/// ## パフォーマンス
///
/// - `WorldAnimatedLayerBase` 継承で App lifecycle に追従 (background 時 stop)
/// - `RepaintBoundary` は呼び出し側 (world_frame_section.dart) で wrap 済
/// - `FilterQuality.none` でピクセルアートのドット感を保つ
/// - 画像未配置時は `errorBuilder` で `SizedBox.shrink` にフォールバック
class CloudLayerWidget extends WorldAnimatedLayerBase {
  /// 画像が画面を 1 回横断するのにかかる秒数 (40〜80 推奨)。
  final double crossDurationSec;

  /// 雲レイヤー画像 path (background と同サイズの透過 PNG、ピクセルアート維持)。
  final String assetPath;

  /// 不透明度 (Cloud Layer 2 を遠景として薄く表示する用途を想定)。
  final double opacity;

  /// 【新規 (2026-06-26)】縦方向のシフト量 (フレーム高さに対する割合)。
  ///   -1.0..+1.0、default 0.0 (シフトなし、画像中央が フレーム中央に来る)
  ///   負の値: 画像を上にシフト (= 画像中央の雲が フレーム上部に来る)
  ///   正の値: 画像を下にシフト
  ///
  /// 用途: cloud_layer.png の雲が画像縦中央に描かれているとき、フレームの
  /// 上空エリアに雲を寄せるための microadjust。例: noon_castle_town は
  /// 城下町が下部にあるため雲は上部に寄せたい → verticalShiftPct = -0.30。
  final double verticalShiftPct;

  /// 【新規 (2026-07-05)】起動時にランダムな開始位置を採用するか。
  ///
  /// 複数の CloudLayerWidget を Stack で重ねる場合、全て同じ位置から始まると
  /// 「同期して動いている」不自然さが生じる。true にすると起動時に横位相 +
  /// 縦揺れ位相をランダム化する。default false で既存呼び出し (noon_castle_town)
  /// への後方互換を維持。
  final bool randomStartPhase;

  /// 【新規 (2026-07-05)】縦方向 sin 波揺れの振幅 (px)。
  ///
  /// 0.0 で sin 波揺れ無効 (default、既存挙動と同じ)。要件は ±1〜2px 程度で、
  /// 「風に微かに揺られる」自然な雰囲気を演出する。振幅が大きすぎると
  /// 「上下に跳ねている」不自然さになるため、2px を上限目安とする。
  final double verticalSwayAmplitudePx;

  /// 【新規 (2026-07-05)】縦方向 sin 波揺れの周期 (秒)。
  ///
  /// 8〜15 秒推奨 (default 12s)。周期が短いほど揺れがせわしなく見え、
  /// 長いほど「風の揺らぎ」らしくなる。同じシーン内の複数レイヤーで
  /// 微妙に異なる値を使うと「別々の風」感が出る (Layer1 10s / Layer2 14s 等)。
  final double verticalSwayPeriodSec;

  /// 【新規 (2026-07-05)】雲画像の表示倍率 (default 1.0 = フル表示)。
  ///
  /// 1.0 未満で画像を Transform.scale で縮小し、雲を「小さく」「まばらに」
  /// 見せる。縮小分は透明地に変わるため、雲間の空エリアが広がり「遠くの
  /// 小さな雲」感が強調される。要件「雲を少し小さく」用途に 0.5〜0.8 推奨。
  ///
  /// 注意: BoxFit が cover の場合、先に画像をフル表示にストレッチしてから
  /// scale が適用されるため、内部のタイリング (2 枚並列で継ぎ目ゼロ) は維持
  /// される。fitWidth の場合、画像は aspect 比を保ちつつ幅に合わせて表示され、
  /// scale はその上に適用される。
  final double imageScale;

  /// 【新規 (2026-07-05 v2)】雲画像の BoxFit 戦略 (default BoxFit.cover)。
  ///
  /// - **BoxFit.cover** (default): 画像を tile の縦横両方に fit させ、余った
  ///   方向をトリミング。noon_castle_town など画像 aspect が tile と近い場合
  ///   に有効。ただし wide/short な画像 (5:1 等) を landscape な tile に
  ///   cover させると縦に細長くトリミングされ、トリミング境界が「vertical
  ///   split」として視覚化されるため注意。
  ///
  /// - **BoxFit.fitWidth**: 画像 aspect を保ちつつ tile 幅に合わせて表示。
  ///   高さは aspect 比で決まり、tile の上下に余白 (透明地) が生まれる。
  ///   wide/short な雲画像に最適 (トリミングなし、雲は自然な形で表示)。
  ///   morning_grassland 等でトリミング境界を回避したい場合に使用。
  final BoxFit cloudFit;

  const CloudLayerWidget({
    super.key,
    this.crossDurationSec = 60.0,
    this.assetPath = 'assets/images/backgrounds/world/cloud_layer.webp',
    this.opacity = 1.0,
    this.verticalShiftPct = 0.0,
    this.randomStartPhase = false,
    this.verticalSwayAmplitudePx = 0.0,
    this.verticalSwayPeriodSec = 12.0,
    this.imageScale = 1.0,
    this.cloudFit = BoxFit.cover,
  })  : assert(crossDurationSec >= 1.0, 'crossDurationSec must be >= 1 sec'),
        assert(opacity >= 0.0 && opacity <= 1.0,
            'opacity must be between 0.0 and 1.0'),
        assert(verticalShiftPct >= -1.0 && verticalShiftPct <= 1.0,
            'verticalShiftPct must be between -1.0 and 1.0'),
        assert(verticalSwayAmplitudePx >= 0.0,
            'verticalSwayAmplitudePx must be >= 0'),
        assert(verticalSwayPeriodSec >= 1.0,
            'verticalSwayPeriodSec must be >= 1 sec'),
        assert(imageScale > 0.0 && imageScale <= 1.0,
            'imageScale must be in (0.0, 1.0]');

  @override
  State<CloudLayerWidget> createState() => _CloudLayerWidgetState();
}

class _CloudLayerWidgetState
    extends WorldAnimatedLayerBaseState<CloudLayerWidget> {
  late final AnimationController _ctrl;

  /// 【新規 (2026-07-05)】sin 波揺れ計算用の経過時間カウンタ。
  ///
  /// AnimationController の value (0..1) は `crossDurationSec` 周期でリセット
  /// されるため sin 波揺れの独立した周期には使えない。Stopwatch で純粋な
  /// 経過秒を追跡し、`math.sin(2π × elapsed / period + phase)` を毎フレーム計算する。
  ///
  /// pauseAnimations / resumeAnimations で stop / start して App が background に
  /// 移った時に時間進行を止める (バッテリー節約 + 復帰時のジャンプ回避)。
  late final Stopwatch _swayElapsed;

  /// 【新規 (2026-07-05)】起動時ランダム位相 (0.0..1.0)。
  ///
  /// `randomStartPhase=true` のとき初期化。`_ctrl.value = _horizontalPhase` で
  /// 横スクロールの初期位置を、`_swayPhaseRad` で sin 波の初期位相を決定。
  /// `randomStartPhase=false` のときは 0.0 (既存挙動と同じ)。
  double _horizontalPhase = 0.0;
  double _swayPhaseRad = 0.0;

  @override
  void initState() {
    super.initState();

    // 【新規 (2026-07-05)】ランダム開始位相 (複数レイヤーの同期不自然さ解消)。
    // math.Random() は毎回 seed 変化 (時計依存)、テスト時は Golden test で
    // ランダム性を許容する前提。強い再現性が必要な場合は seed 引数化を検討。
    if (widget.randomStartPhase) {
      final rnd = math.Random();
      _horizontalPhase = rnd.nextDouble();               // 横位相 0.0-1.0
      _swayPhaseRad = rnd.nextDouble() * 2 * math.pi;    // 縦揺れ位相 0-2π
    }

    _ctrl = AnimationController(
      vsync: this,
      duration:
          Duration(milliseconds: (widget.crossDurationSec * 1000).round()),
    );
    _ctrl.value = _horizontalPhase;  // 初期位置設定 (default 0.0 で既存挙動)
    _ctrl.repeat();  // 0.0 → 1.0 → 0.0 → ... を delay なしで繰り返し

    _swayElapsed = Stopwatch()..start();
  }

  @override
  void pauseAnimations() {
    if (_ctrl.isAnimating) _ctrl.stop();
    _swayElapsed.stop();
  }

  @override
  void resumeAnimations() {
    if (mounted && !_ctrl.isAnimating) {
      _ctrl.repeat();
    }
    if (!_swayElapsed.isRunning) _swayElapsed.start();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _swayElapsed.stop();
    super.dispose();
  }

  /// 【新規 (2026-07-05)】現在の sin 波揺れ Y オフセット (px) を計算する。
  ///
  /// `verticalSwayAmplitudePx == 0.0` (default) のとき即 0.0 を返し、
  /// math 計算コストをゼロにする (既存呼び出しへの影響を排除)。
  ///
  /// 計算式: `A × sin(2π × t / T + φ)` where
  ///   A = 振幅 (px)、T = 周期 (秒)、t = 経過秒、φ = 初期位相 (rad)
  double _computeSwayY() {
    if (widget.verticalSwayAmplitudePx == 0.0) return 0.0;
    final tSec = _swayElapsed.elapsedMilliseconds / 1000.0;
    final period = widget.verticalSwayPeriodSec;
    return widget.verticalSwayAmplitudePx *
        math.sin(2 * math.pi * tSec / period + _swayPhaseRad);
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          // 【新規 (2026-06-26)】縦シフトをフレーム高さに対する割合で算出。
          // 負値で画像が上にシフト → 中央の雲が上空に表示される。
          final verticalShift =
              constraints.maxHeight * widget.verticalShiftPct;
          return Opacity(
            opacity: widget.opacity,
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) {
                // ── シームレスループ計算 ────────────────────────────────
                // controller value: 0.0 → 1.0 で画像幅 1 つ分左へスクロール。
                // 2 枚並べた画像帯 (合計幅 2W) を [0..-W] の範囲でスライド。
                // controller が 1.0 に達してリセットされた時点で、画像帯の
                // 位置が左に -W → 0 に戻るが、両画像とも同じ画像なので
                // 視覚的に「リセットが見えない (継ぎ目ゼロ)」状態を実現。
                final offset = -_ctrl.value * width;
                // 【新規 (2026-07-05)】縦方向 sin 波揺れ (±verticalSwayAmplitudePx)。
                // verticalShift (静的、フレーム中央からの相対) に加算するため、
                // 雲全体が「風に微かに揺られる」ように見える。
                // AnimatedBuilder は _ctrl が毎フレーム tick するため、追加の
                // Ticker を作らずに sin 波再計算のタイミングを取れる。
                final swayY = _computeSwayY();
                final totalY = verticalShift + swayY;
                return Stack(
                  fit: StackFit.expand,
                  clipBehavior: Clip.hardEdge,
                  children: [
                    // 1 枚目 (開始時に画面と一致、左へ消える)
                    Transform.translate(
                      offset: Offset(offset, totalY),
                      child: _CloudImage(
                        assetPath: widget.assetPath,
                        imageScale: widget.imageScale,
                        cloudFit: widget.cloudFit,
                      ),
                    ),
                    // 2 枚目 (開始時に画面右外、左から入ってきて画面中央へ)
                    Transform.translate(
                      offset: Offset(offset + width, totalY),
                      child: _CloudImage(
                        assetPath: widget.assetPath,
                        imageScale: widget.imageScale,
                        cloudFit: widget.cloudFit,
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// 個別の雲画像 (Image.asset の共通設定をまとめた private widget)。
///
/// - `BoxFit.cover` で背景画像と同じ aspect で表示
/// - `FilterQuality.none` でピクセルアートを保持 (アンチエイリアスなし)
/// - 画像未配置時は `SizedBox.shrink` フォールバック (PM が画像を後から
///   配置するワークフローに対応)
class _CloudImage extends StatelessWidget {
  const _CloudImage({
    required this.assetPath,
    this.imageScale = 1.0,
    this.cloudFit = BoxFit.cover,
  });

  final String assetPath;
  final double imageScale;
  final BoxFit cloudFit;

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      assetPath,
      fit: cloudFit,
      filterQuality: FilterQuality.none,
      // gaplessPlayback で 2 枚目ロード時のフラッシュを防ぐ
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
    if (imageScale >= 1.0) return image;
    // 【新規 (2026-07-05)】imageScale < 1.0 のとき Transform.scale で縮小。
    // alignment: center で画像中央を基準に縮小。cloudFit=fitWidth と組み合わせて
    // 使うと、トリミングされない小さな雲帯が中央付近に配置される (「vertical split」
    // として見えていたトリミング境界を回避)。
    return Transform.scale(
      scale: imageScale,
      alignment: Alignment.center,
      child: image,
    );
  }
}
