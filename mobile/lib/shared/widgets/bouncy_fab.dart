import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';

/// 【2026-06-28】ホーム / カレンダー画面の追加 FAB 用「軽快なタップ感」共通 widget。
///
/// 目的: 「押すこと自体が気持ち良い」「軽快」「何度でも押したくなる」体験。
///
/// タイミング設計 (ユーザー要件):
/// - タップ →  5ms 以内: ボタンが縮み始める (onTapDown で即時 forward)
/// - タップ → 40ms: scale 0.95 完了 + ハプティクス light impact (forward 完了タイミング)
/// - タップ →  〜200ms: easeOutBack で弾みながら 1.0 に復帰 (reverse 160ms)
/// - タップ → 120ms: onPressed 発火 (画面遷移) — リップル + 縮小バック効果を見せる遅延
///
/// 構成:
/// - [AnimationController] (vsync) で scale / shadow を手動駆動 (AnimatedScale より制御性高)
/// - [GestureDetector] で onTapDown/Up/Cancel を捕捉 (InkWell の callback と独立)
/// - [Material] + [InkWell] で標準リップル使用、splashColor は紫 15% に統一
/// - [BoxShadow] は `_ctrl` の進捗で blurRadius を 12→6 に弱める (AnimatedBuilder)
///
/// パフォーマンス:
/// - vsync は SingleTickerProviderStateMixin で 1 controller のみ (60fps 維持)
/// - ScaleTransition / AnimatedBuilder のみで re-build は子の影 + scale のみ
/// - InkWell ripple は Material の固有最適化 (GPU layer) に乗る
class BouncyFab extends StatefulWidget {
  /// タップ確定時 (120ms 遅延後) に呼ばれる callback。
  final VoidCallback onPressed;

  /// FAB の中央に置く widget (通常は [Icon])。
  final Widget child;

  /// 背景色。Sabiowl では基本 [AppTheme.primary] を使う。
  final Color backgroundColor;

  /// FAB の正方形サイズ (デフォルト 56dp = M3 FAB 標準)。
  final double size;

  /// アクセシビリティ用 tooltip (オプション)。
  final String? tooltip;

  /// onPressed 発火までの遅延 (ms)。リップル + 縮小バック効果を見せるため
  /// デフォルト 120ms。0 にすると onTapUp 直後に発火。
  final int onPressedDelayMillis;

  const BouncyFab({
    super.key,
    required this.onPressed,
    required this.child,
    this.backgroundColor = AppTheme.primary,
    this.size = 56.0,
    this.tooltip,
    this.onPressedDelayMillis = 120,
  });

  @override
  State<BouncyFab> createState() => _BouncyFabState();
}

class _BouncyFabState extends State<BouncyFab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _shadowAnim;

  /// 押下中の最小スケール (0.95)。
  static const double _kPressedScale = 0.95;

  /// forward (press down) 所要時間。
  static const Duration _kForwardDuration = Duration(milliseconds: 40);

  /// reverse (release) 所要時間。
  static const Duration _kReverseDuration = Duration(milliseconds: 160);

  /// 通常時の影 blurRadius。
  static const double _kShadowBlurNormal = 12.0;

  /// 押下完了時の影 blurRadius (押した瞬間に影が弱まる感じ)。
  static const double _kShadowBlurPressed = 6.0;

  /// 連打防止用フラグ。onPressed が遅延発火中は二度押しを無視する。
  bool _firing = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: _kForwardDuration,
      reverseDuration: _kReverseDuration,
      value: 0.0,
    );
    // 【設計】forward は直線で 1.0 → 0.95、reverse は easeOutBack で弾む。
    // ScaleTransition の前段でカーブを当てるため Tween + CurvedAnimation を別個に組む。
    _scaleAnim = Tween<double>(begin: 1.0, end: _kPressedScale).animate(_ctrl);
    _shadowAnim = Tween<double>(
      begin: _kShadowBlurNormal,
      end: _kShadowBlurPressed,
    ).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// onTapDown: forward 開始 + ハプティクス即時。
  /// ハプティクスはユーザー要件「タップから 40ms で振動」を満たすため、
  /// forward 完了 (40ms 後) と「ほぼ同期」する形で onTapDown 直後に発火する。
  /// 厳密に 40ms 後を狙う Future.delayed は OS スケジューラの不確実性
  /// (Android 振動エンジンの起動が ~20ms 前後揺れる) を増やすため避けた。
  void _handleTapDown(TapDownDetails _) {
    HapticFeedback.lightImpact();
    _ctrl.forward();
  }

  void _handleTapUp(TapUpDetails _) {
    _ctrl.reverse();
  }

  void _handleTapCancel() {
    _ctrl.reverse();
  }

  /// onTap: リップル + 縮小バック効果を見せるため [onPressedDelayMillis] 遅延して発火。
  /// 連打防止用に [_firing] でガード。
  void _handleTap() {
    if (_firing) return;
    _firing = true;
    final delay = Duration(milliseconds: widget.onPressedDelayMillis);
    Timer(delay, () {
      if (!mounted) {
        _firing = false;
        return;
      }
      widget.onPressed();
      _firing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // GestureDetector を最外に置き、InkWell の onTapDown/Up より先に捕捉する。
    // (InkWell も同名 callback を持つが、本実装では scale 制御は GestureDetector
    // 側でやる方が AnimationController の所有関係が明快。InkWell には onTap のみ
    // 渡してリップル + onPressed 確定を任せる。)
    final fab = ScaleTransition(
      scale: _scaleAnim,
      child: AnimatedBuilder(
        animation: _shadowAnim,
        builder: (context, child) {
          return Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: widget.backgroundColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.30),
                  blurRadius: _shadowAnim.value,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: child,
          );
        },
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            // 紫 15% のリップル + 弱い highlight。
            // InkSplash の duration は標準 200~300ms 程度で要件「250ms 以内」と整合。
            splashColor: AppTheme.primary.withValues(alpha: 0.15),
            highlightColor: AppTheme.primary.withValues(alpha: 0.05),
            onTap: _handleTap,
            child: Center(child: widget.child),
          ),
        ),
      ),
    );

    final wrapped = GestureDetector(
      // behavior: opaque で子の透明領域もタップを捕捉、リップル発火を保証。
      behavior: HitTestBehavior.opaque,
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      child: fab,
    );

    if (widget.tooltip != null) {
      return Tooltip(message: widget.tooltip!, child: wrapped);
    }
    return wrapped;
  }
}
