import 'dart:math';

import 'package:flutter/material.dart';

import '../constants/battle_constants.dart';
import '../constants/battle_sprite_motion.dart';

/// 【FEAT-295 Phase 1b】戦闘ユニットのドット絵 + 5 種演出を統合した widget。
///
/// 設計ノート §7.2 に従い、すべて `RepaintBoundary` でホーム他レイヤーから
/// 隔離する（Pre-mortem #4: バッテリードレイン対策）。
///
/// 5 演出:
///   1. **待機ユラユラ** (`SpriteAction.idle`): 1500ms 周期 sin で y 方向 ±2px
///   2. **突撃** (`SpriteAction.charge`): 200ms で x 方向 ±8 → 0 (direction 依存)
///   3. **斬撃エフェクト** (`SpriteAction.slash`): 150ms 白い斜線 fade
///   4. **のけぞり** (`SpriteAction.recoil`): 300ms で x 方向 shake ±4
///   5. **フェードアウト消滅** (`SpriteAction.fadeOut`): 500ms で opacity 1 → 0
///
/// 使用パターン: `BattleOrchestrator` が `setState` で `action` を変更する設計。
enum SpriteAction {
  idle,
  charge,
  slash,
  recoil,
  fadeOut,
}

/// 【FEAT-387 (2026-05-30)】charge アニメーションの x 方向を制御する enum。
///
/// 横並び対峙構図で、それぞれが「相手の方向」に突撃するよう x 符号を反転する。
/// - [right]: 右方向に動く (画面左の敵が画面右の味方に向かう)。default = MiniArena 互換。
/// - [left]: 左方向に動く (画面右の味方が画面左の敵に向かう)。
enum AttackDirection {
  right,
  left,
}

class CombatantSprite extends StatefulWidget {
  const CombatantSprite({
    super.key,
    required this.spriteKey,
    this.action = SpriteAction.idle,
    this.size = 96.0,
    this.flipHorizontal = false,
    this.attackDirection = AttackDirection.right,
    this.onActionDone,
    this.enableMotion = false,
  });

  /// `assets/images/battle/<key>.webp` の key 部分。
  /// 例: 'sabi' / 'goblin' / 'character_zenon' 等。
  final String spriteKey;

  final SpriteAction action;
  final double size;
  final bool flipHorizontal;
  /// 【FEAT-387】charge アニメーションの突撃方向。
  /// - `right`: 右に動く (画面左配置の敵が味方に向かう)。MiniArena 互換 default。
  /// - `left`: 左に動く (画面右配置の味方が敵に向かう)。
  final AttackDirection attackDirection;
  final VoidCallback? onActionDone;

  /// 【FEAT-527】攻撃フレームの再生を許可する。
  ///
  /// **default は false**。有効にした画面でだけフレームが動き、
  /// 他は 1 行も挙動が変わらない。素材が 1 体ずつ増える段階導入なので、
  /// 「どこで有効か」を呼び出し側が明示する形にしている。
  ///
  /// true でも [BattleSpriteMotion.has] が false のキャラは
  /// **従来どおりの Transform 演出**で動く (フォールバック)。
  final bool enableMotion;

  @override
  State<CombatantSprite> createState() => _CombatantSpriteState();
}

class _CombatantSpriteState extends State<CombatantSprite>
    with TickerProviderStateMixin {
  // 待機ユラユラ（常時 loop）
  late final AnimationController _idleCtrl;

  // 一時的なアクション用（charge/recoil 等）
  late final AnimationController _actionCtrl;

  // 斬撃エフェクトの opacity
  late final AnimationController _slashCtrl;

  // フェードアウト用
  late final AnimationController _fadeCtrl;

  // 【FEAT-527】攻撃フレーム送り。value 0.0〜1.0 を frameIndexFor で番号に変換。
  late final AnimationController _frameCtrl;

  /// このキャラで攻撃フレームを再生するか。
  bool get _motionActive =>
      widget.enableMotion && BattleSpriteMotion.has(widget.spriteKey);

  /// いま攻撃フレームを描くべきか。
  ///
  /// `charge` (踏み込み) と `slash` (斬撃) の間だけフレームを出し、それ以外は
  /// 立ち絵に戻す。`recoil` (被弾) は攻撃フレームではないので含めない。
  ///
  /// 🔴 KO のとき `BattleOrchestrator` は idle への復帰 Timer を畳むので
  /// action は `slash` のまま残る (FEAT-526 §4.5)。その結果ここも true のままで、
  /// **振り抜いた最終フレームで静止する** —— KO 演出の意図どおりの絵になる。
  bool get _showingAttackFrame =>
      _motionActive &&
      (widget.action == SpriteAction.charge ||
          widget.action == SpriteAction.slash);

  @override
  void initState() {
    super.initState();
    _idleCtrl = AnimationController(
      vsync: this,
      duration: BattleConstants.idleSwayDuration,
    )..repeat();
    _actionCtrl = AnimationController(
      vsync: this,
      duration: BattleConstants.chargeStepDuration,
    );
    _slashCtrl = AnimationController(
      vsync: this,
      duration: BattleConstants.slashEffectDuration,
    );
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: BattleConstants.fadeOutDuration,
      value: 1.0,
    );
    _frameCtrl = AnimationController(
      vsync: this,
      duration: BattleSpriteMotion.totalDuration,
    );
    _maybeRunAction();
  }

  @override
  void didUpdateWidget(covariant CombatantSprite oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 【FEAT-455 (2026-06-21)】fadeOut からの遷移時に opacity を 1.0 に明示リセット。
    //
    // 【真因】前バトル勝利時に敵 (or 敗北時に味方) が SpriteAction.fadeOut で
    // _fadeCtrl.reverse(1.0 → 0.0) され、_fadeCtrl.value = 0.0 になる。
    // 次バトル開始時に CombatantSprite は同位置・同型のため Flutter が
    // _CombatantSpriteState を再利用 (key 指定なし)。新しい spriteKey で
    // widget は更新されるが、_fadeCtrl.value = 0.0 が残存し、新敵スプライトが
    // Opacity 0 で invisible になる ("敵が消える" バグ)。
    //
    // 【修正】fadeOut → 他 action への遷移で fade controller を明示リセット。
    // spriteKey 変化検出 (= 別キャラ) も併用して防御的に二重ガード:
    //   - fadeOut → idle (典型的な次バトル開始経路)
    //   - fadeOut → charge (即時再エンゲージ、稀)
    //   - 新 spriteKey (caller が action 同じでキャラだけ変えた稀ケース)
    final cameOutOfFade = oldWidget.action == SpriteAction.fadeOut &&
        widget.action != SpriteAction.fadeOut;
    final newSprite = widget.spriteKey != oldWidget.spriteKey;
    if (cameOutOfFade || newSprite) {
      _fadeCtrl.value = 1.0;
    }
    if (widget.action != oldWidget.action) {
      _maybeRunAction();
    }
  }

  void _maybeRunAction() {
    switch (widget.action) {
      case SpriteAction.idle:
        _actionCtrl.reset();
        _slashCtrl.reset();
        // 【FEAT-527】立ち絵に戻すのでフレーム送りも巻き戻す。
        _frameCtrl.reset();
        // 待機ループは継続中、何もしない
        break;
      case SpriteAction.charge:
        // 【FEAT-527】攻撃フレームの再生開始。`slash` へ遷移しても止めない
        // (400ms かけて 4 枚を送り、3 枚目が t=200ms の斬撃と重なる)。
        if (_motionActive) _frameCtrl.forward(from: 0);
        _actionCtrl.duration = BattleConstants.chargeStepDuration;
        _actionCtrl.forward(from: 0).whenComplete(() {
          if (!mounted) return;
          widget.onActionDone?.call();
        });
        break;
      case SpriteAction.slash:
        _slashCtrl.forward(from: 0).whenComplete(() {
          if (!mounted) return;
          widget.onActionDone?.call();
        });
        break;
      case SpriteAction.recoil:
        _actionCtrl.duration = BattleConstants.recoilDuration;
        _actionCtrl.forward(from: 0).whenComplete(() {
          if (!mounted) return;
          widget.onActionDone?.call();
        });
        break;
      case SpriteAction.fadeOut:
        _fadeCtrl.duration = BattleConstants.fadeOutDuration;
        _fadeCtrl.reverse(from: 1.0).whenComplete(() {
          if (!mounted) return;
          widget.onActionDone?.call();
        });
        break;
    }
  }

  @override
  void dispose() {
    // 【Pre-mortem #1】dispose 内で setState 呼ばず、Controller dispose のみ
    _idleCtrl.dispose();
    _actionCtrl.dispose();
    _slashCtrl.dispose();
    _fadeCtrl.dispose();
    _frameCtrl.dispose();
    super.dispose();
  }

  /// 描画するアセットのパス。
  ///
  /// フレームを持たないキャラ / [CombatantSprite.enableMotion] が false のときは
  /// **従来と同じ `<key>.webp`** を返す (フォールバック)。
  String _assetPath() {
    if (!_motionActive) {
      return 'assets/images/battle/${widget.spriteKey}.webp';
    }
    if (_showingAttackFrame) {
      return BattleSpriteMotion.framePath(
        widget.spriteKey,
        BattleSpriteMotion.frameIndexFor(_frameCtrl.value),
      );
    }
    return BattleSpriteMotion.idlePath(widget.spriteKey);
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width:  widget.size,
        height: widget.size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // ── 1. 待機ユラユラ + 2. 突撃 + 4. のけぞり + 5. フェード ──
            AnimatedBuilder(
              animation:
                  Listenable.merge([_idleCtrl, _actionCtrl, _fadeCtrl, _frameCtrl]),
              builder: (_, __) {
                // 待機 y 方向 ±2px
                final swayY = sin(_idleCtrl.value * 2 * pi) * 2;
                // アクション x 方向 offset
                double actionX = 0;
                double actionY = swayY;
                switch (widget.action) {
                  case SpriteAction.idle:
                  case SpriteAction.fadeOut:
                  case SpriteAction.slash:
                    break;
                  case SpriteAction.charge:
                    // 0 → ±8 → 0 の山形 (attackDirection で符号反転)
                    // 【FEAT-387 Pre-mortem #1】direction が right なら +8 (右)、
                    // left なら -8 (左) — それぞれ相手の方向に向かう突撃を表現。
                    final t = _actionCtrl.value;
                    final chargeSign = widget.attackDirection == AttackDirection.right
                        ? 1.0
                        : -1.0;
                    // 【FEAT-527】フレームを持つキャラは **踏み込みを絵の中で
                    // 描いている**ので、ここで widget ごと動かすと二重になる。
                    actionX = _motionActive ? 0 : sin(t * pi) * 8 * chargeSign;
                    break;
                  case SpriteAction.recoil:
                    // ±4px shake、sign 反転
                    final t = _actionCtrl.value;
                    actionX = sin(t * 6 * pi) * 4 * (1 - t);
                    break;
                }
                return Transform.translate(
                  offset: Offset(actionX, actionY),
                  child: Opacity(
                    opacity: _fadeCtrl.value,
                    child: Transform(
                      alignment: Alignment.center,
                      transform: widget.flipHorizontal
                          ? Matrix4.rotationY(pi)
                          : Matrix4.identity(),
                      child: Image.asset(
                        _assetPath(),
                        width:  widget.size,
                        height: widget.size,
                        // 【FEAT-405 hotfix (2026-06-01)】fit: BoxFit.contain 明示。
                        // 旧 default BoxFit.scaleDown は「画像が widget より小さければ
                        // 拡大しない」ため、92x92 の PNG (ogre / bat / skeleton / wolf 等
                        // 新規 12 体) が 128x128 widget 内で **そのままの小サイズ**で描画
                        // され、背景 (bg_mid_boss 等の暗色洞窟) に紛れて視認困難だった。
                        // contain で aspect ratio 維持しつつ widget サイズに拡大表示。
                        // 既存大キャンバス PNG (subaru = 1254x1254 等) は引き続き縮小表示。
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.none, // ドット絵 nearest-neighbor
                        // 【2026-08-08】MiniBattleArena 側は `_kMiniSpriteSize` で
                        // 拡大表示する (48 → 60)。元アセットは 92x92 〜 1254x1254 と
                        // ばらついており、そもそも整数倍に揃っていないため、
                        // サイズ変更で nearest-neighbor の見え方が悪化することはない。
                        errorBuilder: (_, __, ___) => Container(
                          width:  widget.size,
                          height: widget.size,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.image_not_supported_outlined,
                            color: Colors.white38,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            // ── 3. 斬撃エフェクト（白い斜線 fade） ──
            AnimatedBuilder(
              animation: _slashCtrl,
              builder: (_, __) {
                final t = _slashCtrl.value;
                // 0 → 1 → 0 の山形 opacity（中央で最大）
                final opacity = sin(t * pi);
                if (opacity <= 0.01) return const SizedBox.shrink();
                return IgnorePointer(
                  child: Opacity(
                    opacity: opacity,
                    child: Transform.rotate(
                      angle: pi / 6, // 30° 傾斜（斬撃感）
                      child: Container(
                        width: widget.size * 1.2,
                        height: 3,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.white.withValues(alpha: 0.7),
                              blurRadius: 6,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
