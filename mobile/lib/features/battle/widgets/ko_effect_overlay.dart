import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../constants/battle_constants.dart';
import 'ultimate_hit_effect_overlay.dart' show ExplosionRingPainter;

/// 【FEAT-526 (2026-08-21)】KO 演出 overlay ——「最後の一撃で決めた」を返す。
///
/// 参考にしているのはスマブラ SP の Finish Zoom / ブラウンダストの KO 演出で、
/// どちらも「敵が倒れたことを知らせる」のではなく **最後の一撃が当たった瞬間を
/// 一時的に引き伸ばして見せる** タイプの演出である。
///
/// ```
/// ✅ 最後の攻撃が命中 → 一瞬止める →「決めた」と強調 → 敵が倒れる
/// ❌ 敵が倒れる → KO 演出
/// ```
///
/// ## 構成
///
/// 🔴 **長さの真実値は [BattleConstants] にしかない。ここに数字を書き戻さないこと。**
/// 以前この表は「等速 650ms / 「K.O.」320ms」と書いており、実機フィードバックで
/// ラベル区間を伸ばした後もそのまま残っていた。ゲームプレイレビュー 20260824 の
/// レビュアーは **この表を読んで古い値を引用し、本文に誤りを出している**
/// (同レビュー §8-4)。**数字は腐るが、参照は腐らない。**
///
/// | 区間 | 長さ | 中身 |
/// |---|---|---|
/// | ヒットストップ | [BattleConstants.koHitStopDuration] | 何も動かさない (ATB は `_atb.pause()` で既に停止済) |
/// | ズームイン | [BattleConstants.koZoomInDuration] | 等倍 → 1.20 倍 + 暗転 + インパクトリング |
/// | 「K.O.」 | [BattleConstants.koLabelDuration] | ラベル表示、ズームは 1.20 倍を保持 |
/// | ズームアウト | [BattleConstants.koZoomOutDuration] | 1.20 倍 → 等倍 + 暗転解除 |
///
/// 合計は [BattleConstants.koTotalDuration]、倍速適用後は
/// [BattleConstants.koScaledTotal]。**「K.O.」ラベルだけは倍速で縮まない**
/// ([BattleConstants.koScaledLabel] が常に [BattleConstants.koLabelDuration] を返す)。
///
/// 画面シェイクは先頭 180ms に 1 回だけ。
///
/// ## 🔴 wrap するのは「戦闘エリアだけ」
///
/// ズームは対峙している 2 体に掛けたい。`UltimateHitEffectOverlay` のように
/// 画面全体を wrap すると、下半分のログ / 作戦パネルまで拡大されて
/// レイアウトが破綻する。**battle_page では戦闘エリア (`Expanded(flex: 6)` の
/// 中身) を wrap すること。**
///
/// ## ⚠️ アンビエントバトル (ホーム額縁) では使わない
///
/// 額縁は「ながら見」の前景で、習慣チェック中に画面が拡大 / 暗転すると邪魔になる
/// (指示書 決定事項 2)。`mini_battle_arena.dart` から本 widget を参照しないこと。
/// `ko_effect_contract_test.dart` がソース走査で縛っている。
///
/// ## 「モーダル手動 close 原則」との関係
///
/// CLAUDE.md は祝祭系 popup の auto-dismiss を禁じているが、本演出は
/// **ユーザーの操作を待つ popup ではなく通り過ぎる演出**なので同ルールの
/// 例外 (SnackBar / Toast と同じ扱い) に当たる。閉じるボタンを付けたら演出として
/// 成立しない。既存の `UltimateHitEffectOverlay` も同じ扱い。
/// **ただし演出の後に出る報酬モーダルは原則の対象** —— そちらに auto-dismiss を
/// 足さないこと。
/// 【FEAT-526】KO 演出の「強さ」——**空間方向のパラメータだけ**を持つ。
///
/// 🔴 **時間は含めない。** 演出の長さ (`koTotalDuration` と内訳) は全画面でも
/// 額縁でも同じで、変えるのはズーム量 / 暗転量 / 文字サイズ / 揺れ幅 / リング径。
/// 時間まで可変にすると「どの画面で見ているか」でテンポが変わり、同じ演出だと
/// 認識できなくなる。
class KoEffectStyle {
  const KoEffectStyle({
    required this.maxZoom,
    required this.dimOpacity,
    required this.labelFontSize,
    required this.shakeAmplitude,
    required this.impactSize,
  });

  final double maxZoom;
  final double dimOpacity;
  final double labelFontSize;
  final double shakeAmplitude;
  final double impactSize;

  /// バトル画面 (全画面)。
  static const fullscreen = KoEffectStyle(
    maxZoom: BattleConstants.koMaxZoom,
    dimOpacity: BattleConstants.koDimOpacity,
    labelFontSize: BattleConstants.koLabelFontSize,
    shakeAmplitude: BattleConstants.koShakeAmplitude,
    impactSize: BattleConstants.koImpactSize,
  );

  /// ホーム額縁 (アンビエントバトル) の縮小版。
  ///
  /// 額縁は約 344 x 240px しかなく、WorldFrameSection の暗幕 (55%) と
  /// 敵背景オーバーレイ (25%) が既に乗っている。全画面の値をそのまま使うと
  /// 「K.O.」がはみ出し、暗転の合計がほぼ真っ黒になる。
  static const ambient = KoEffectStyle(
    maxZoom: BattleConstants.koAmbientMaxZoom,
    dimOpacity: BattleConstants.koAmbientDimOpacity,
    labelFontSize: BattleConstants.koAmbientLabelFontSize,
    shakeAmplitude: BattleConstants.koAmbientShakeAmplitude,
    impactSize: BattleConstants.koAmbientImpactSize,
  );
}

class KoEffectController {
  KoEffectController();

  _KoEffectOverlayState? _state;

  /// KO 演出を起動する。
  ///
  /// 戻り値 `false` = **overlay が居なくて演出できなかった**。
  /// caller はこの場合 `onFinished` を待たずに自前でゲートを開けること
  /// —— 待つと敵が永久に消えず、報酬モーダルも出ない (指示書 Pre-mortem #1)。
  ///
  /// [speedMultiplier] は `BattleState.speedMultiplier`。演出時間はこれで割られ、
  /// `BattleConstants.koMinDuration` を下限とする。
  bool fire({required double speedMultiplier}) {
    final state = _state;
    if (state == null) return false;
    return state._fire(speedMultiplier);
  }

  /// 演出中かどうか (テスト / デバッグ用)。
  bool get isPlaying => _state?._isPlaying ?? false;

  void _attach(_KoEffectOverlayState state) => _state = state;

  void _detach(_KoEffectOverlayState state) {
    if (_state == state) _state = null;
  }
}

class KoEffectOverlay extends StatefulWidget {
  const KoEffectOverlay({
    super.key,
    required this.controller,
    required this.onFinished,
    required this.child,
    this.style = KoEffectStyle.fullscreen,
  });

  final KoEffectController controller;

  /// 演出の強さ。額縁では [KoEffectStyle.ambient] を渡す。
  final KoEffectStyle style;

  /// 演出が最後まで再生されたときに 1 回だけ呼ばれる。
  ///
  /// battle_page はこれを受けて「KO 演出が終わった」**ローカル**フラグを立て、
  /// 敵の `fadeOut` と報酬モーダルを解禁する。
  final VoidCallback onFinished;

  final Widget child;

  @override
  State<KoEffectOverlay> createState() => _KoEffectOverlayState();
}

class _KoEffectOverlayState extends State<KoEffectOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final math.Random _rng = math.Random();

  double _shakeSeed = 0;
  bool _isPlaying = false;

  /// 発火時の倍速。区間の割合計算に使う (下限が効くと割合が変わるため)。
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: BattleConstants.koTotalDuration,
    );
    widget.controller._attach(this);
  }

  @override
  void didUpdateWidget(covariant KoEffectOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._detach(this);
      widget.controller._attach(this);
    }
  }

  @override
  void dispose() {
    // 【Pre-mortem #4】演出中に戻るジェスチャで離脱してもここで確実に破棄する。
    // 🔴 `dispose()` の中で `setState()` を呼ばないこと (BUG-66 v3)。
    // `_isPlaying` は素の代入で、フレームを要求しない。
    widget.controller._detach(this);
    _isPlaying = false;
    _ctrl.dispose();
    super.dispose();
  }

  bool _fire(double speedMultiplier) {
    if (!mounted) return false;
    _speed = speedMultiplier > 0 ? speedMultiplier : 1.0;
    _shakeSeed = _rng.nextDouble() * math.pi * 2;
    _isPlaying = true;
    // 🔴 区間を積み上げた値を使う (2026-08-22)。全体を単純割りすると
    // **区間ごとの下限が無効化される** —— ⏭ Skip (50x) では演出全体が 40ms に
    // 潰れ、「K.O.」は 10ms しか出ないので実質見えない。
    _ctrl.duration = BattleConstants.koScaledTotal(_speed);
    // 【Pre-mortem #6】連戦: `from: 0.0` で毎回頭から再生する。
    // 前バトルの進捗が残っていると 2 戦目が途中から始まる。
    _ctrl.forward(from: 0.0).whenComplete(() {
      // 離脱済みなら onFinished を呼ばない (すでに画面が無い)。
      if (!mounted) return;
      _isPlaying = false;
      widget.onFinished();
    });
    return true;
  }

  // ── 区間の割合 ─────────────────────────────────────────────────────────
  //
  // 各区間は個別に下限 (`koMinDuration`) が掛かるため、**倍速では割合そのものが
  // 変わる**。合計を取り直して正規化しないと、3 倍速でヒットストップだけが
  // 下限に張り付いたときに区間がずれる。

  ({double hitStop, double zoomIn, double label}) _phases() {
    int ms(Duration d) => BattleConstants.koScaled(d, _speed).inMilliseconds;
    final hitStop = ms(BattleConstants.koHitStopDuration);
    final zoomIn = ms(BattleConstants.koZoomInDuration);
    // 🔴 ラベルだけ `koScaledLabel` (下限 400ms)。ここで `ms()` を使うと
    // ⏭ Skip で 40ms になり、**読む前に消える** (2026-08-22 実機報告)。
    // `koScaledTotal` 側も同じ関数を使っているので、揃えないと区間がずれる。
    final label = BattleConstants.koScaledLabel(_speed).inMilliseconds;
    final zoomOut = ms(BattleConstants.koZoomOutDuration);
    final total = hitStop + zoomIn + label + zoomOut;
    if (total <= 0) return (hitStop: 0.0, zoomIn: 0.0, label: 0.0);
    return (
      hitStop: hitStop / total,
      zoomIn: (hitStop + zoomIn) / total,
      label: (hitStop + zoomIn + label) / total,
    );
  }

  /// ズーム倍率 (等倍 → [BattleConstants.koMaxZoom] → 等倍)。
  double _zoom(double progress) {
    final p = _phases();
    final maxZoom = widget.style.maxZoom;
    if (progress <= p.hitStop) return 1.0; // ヒットストップ中は等倍で静止
    if (progress < p.zoomIn) {
      final t = (progress - p.hitStop) / (p.zoomIn - p.hitStop);
      return 1.0 + (maxZoom - 1.0) * Curves.easeOutCubic.transform(t);
    }
    if (progress < p.label) return maxZoom; // 「K.O.」表示中は保持
    final t = ((progress - p.label) / (1.0 - p.label)).clamp(0.0, 1.0);
    return maxZoom - (maxZoom - 1.0) * Curves.easeInCubic.transform(t);
  }

  /// 暗転の alpha (ズームと同じ出入りにする)。
  double _dim(double progress) {
    final t = ((_zoom(progress) - 1.0) / (widget.style.maxZoom - 1.0))
        .clamp(0.0, 1.0);
    return widget.style.dimOpacity * t;
  }

  /// 「K.O.」ラベルの表示強度 (0 = 非表示)。
  double _labelOpacity(double progress) {
    final p = _phases();
    if (progress < p.zoomIn || progress >= 1.0) return 0.0;
    if (progress < p.label) {
      // 出現は素早く (区間の頭 20% で全開)、以降は保持
      final t = ((progress - p.zoomIn) / (p.label - p.zoomIn)).clamp(0.0, 1.0);
      return (t / 0.2).clamp(0.0, 1.0);
    }
    // ズームアウトと一緒に消える
    final t = ((progress - p.label) / (1.0 - p.label)).clamp(0.0, 1.0);
    return 1.0 - t;
  }

  /// 「K.O.」ラベルのスケール (ドンと出て少し落ち着く)。
  double _labelScale(double progress) {
    final p = _phases();
    if (progress < p.zoomIn) return 1.0;
    final t = ((progress - p.zoomIn) / (1.0 - p.zoomIn)).clamp(0.0, 1.0);
    return 1.35 - 0.35 * Curves.easeOutBack.transform(t);
  }

  /// 画面シェイク offset (短時間・1 回、減衰)。
  Offset _shakeOffset(double progress) {
    // 🔴 分母は **controller と同じ** `koScaledTotal` でなければならない。
    // `koScaled(koTotalDuration)` を使うと ⏭ Skip (50x) で
    // shakeFraction = 40/40 = 1.0 になり、**演出全体が揺れ続ける**。
    final totalMs = BattleConstants.koScaledTotal(_speed).inMilliseconds;
    if (totalMs <= 0) return Offset.zero;
    final shakeFraction =
        BattleConstants.koScaled(BattleConstants.koShakeDuration, _speed)
                .inMilliseconds /
            totalMs;
    if (progress <= 0 || progress >= shakeFraction) return Offset.zero;
    final t = progress / shakeFraction;
    final amplitude = widget.style.shakeAmplitude * (1.0 - t);
    final dx = math.sin(t * 28 + _shakeSeed) * amplitude;
    final dy = math.cos(t * 23 + _shakeSeed) * (amplitude * 0.4);
    return Offset(dx, dy);
  }

  /// インパクトリング (`UltimateHitEffectOverlay` の爆発リングを流用)。
  ({double scale, double opacity}) _impact(double progress) {
    final span = BattleConstants.koImpactFraction;
    if (progress >= span) return (scale: 0, opacity: 0);
    final t = progress / span;
    return (scale: 0.4 + t * 1.1, opacity: (1.0 - t).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      child: widget.child,
      builder: (context, child) {
        final progress = _ctrl.value;

        // 非発火時は children を素通しする。**Transform も Stack も挟まない**ので
        // 通常時のレイアウトは本 widget を入れる前とまったく同じになる
        // (Pre-mortem #4: 演出後に UI が戻らない、の構造的な予防)。
        if (!_isPlaying || progress <= 0.0 || progress >= 1.0) {
          return child!;
        }

        final dim = _dim(progress);
        final label = _labelOpacity(progress);
        final impact = _impact(progress);

        return Stack(
          fit: StackFit.expand,
          children: [
            // L1: シェイク + ズームされる戦闘エリア
            Transform.translate(
              offset: _shakeOffset(progress),
              child: Transform.scale(
                scale: _zoom(progress),
                child: child,
              ),
            ),
            // L2: 暗転 (ズームした戦闘エリアの上、ラベルの下)
            if (dim > 0)
              IgnorePointer(
                child: Container(color: Colors.black.withValues(alpha: dim)),
              ),
            // L3: インパクトエフェクト (爆発リング)
            if (impact.opacity > 0)
              IgnorePointer(
                child: Center(
                  child: Transform.scale(
                    scale: impact.scale,
                    child: Opacity(
                      opacity: impact.opacity,
                      child: CustomPaint(
                        size: Size(
                          widget.style.impactSize,
                          widget.style.impactSize,
                        ),
                        painter: ExplosionRingPainter(),
                      ),
                    ),
                  ),
                ),
              ),
            // L4: 「K.O.」
            if (label > 0)
              IgnorePointer(
                child: Align(
                  alignment: const Alignment(
                    BattleConstants.koLabelAlignmentX,
                    BattleConstants.koLabelAlignmentY,
                  ),
                  child: Opacity(
                    opacity: label,
                    child: Transform.scale(
                      scale: _labelScale(progress),
                      child: KoLabel(fontSize: widget.style.labelFontSize),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 「K.O.」の文字。
///
/// **l10n しない** ——「K.O.」は日本語圏でもそのまま通る記号的な表現で、
/// ロケールごとに訳語を用意する意味がない (ダメージ数字の表示と同じ扱い)。
/// テストから探せるよう public にしてある。
class KoLabel extends StatelessWidget {
  const KoLabel({super.key, this.fontSize = BattleConstants.koLabelFontSize});

  /// 文字サイズ。額縁では [BattleConstants.koAmbientLabelFontSize] が渡る。
  final double fontSize;

  /// 表示文字列 (テストが参照する真実値)。
  static const String text = 'K.O.';

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w900,
        letterSpacing: fontSize / 16,
        color: Colors.white,
        height: 1.0,
        shadows: [
          const Shadow(color: Color(0xFFFF6600), blurRadius: 24),
          Shadow(color: Colors.black.withValues(alpha: 0.8), blurRadius: 6),
        ],
      ),
    );
  }
}
