import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../models/battle_state.dart';
import '../providers/battle_provider.dart';
import '../services/battle_haptics_service.dart';  // 【新規 2026-06-26】
import '../services/battle_orchestrator.dart' show UltimateQueueResult;

/// 【FEAT-301】手動必殺ボタン（全画面 `BattlePage` のみ配置、ミニビューには表示しない）。
///
/// 4 状態を持ち、見た目 + 押下挙動を切り替える:
///   - `disabled` (UltGauge 未満タン): 半透明、押下するとサビ口調 SnackBar
///     「あと N 回通常攻撃を重ねれば必殺技が放てますよ 🪶」
///   - `ready` (UltGauge 満タン + 未キュー): パルス + 周辺グロー、押下で queue
///   - `queued` (キュー済): わずかに沈み込み + Tooltip「次の一手で必殺技が放たれます 🪶」、
///     連打しても冪等（Pre-mortem #4）
///   - `finished` (戦闘終了): 完全に無効化、Tooltip も出さない
///
/// **Pre-mortem #1 対応**: `dispose()` は `_pulseCtrl.dispose()` のみ。
/// `setState` 一切呼ばない（CLAUDE.md「dispose 内で setState を呼ばない」遵守、
/// BUG-66 v3 系の defunct race を予防）。
///
/// **Pre-mortem #4 対応**: 押下時 haptic feedback `mediumImpact` で「押した感」を
/// 即フィードバック → 連打抑制。`tryQueueUltimate` 自体が冪等なので、複数回押下
/// しても state 変化は 1 回のみ。
class UltimateButton extends ConsumerStatefulWidget {
  const UltimateButton({
    super.key,
    required this.chargedCount,
    required this.ultCost,
    required this.queueUltimate,
    required this.status,
  });

  /// 現在の蓄積数（`BattleState.chargedSpecialCount`）。
  final int chargedCount;

  /// 満タン到達に必要な数（`combatant.ultCost`、ジョブ駆動 1〜4）。
  final int ultCost;

  /// キュー済か（`BattleState.queueUltimate`）。
  final bool queueUltimate;

  /// 戦闘ステータス。`running` 以外は完全無効化。
  final BattleStatus status;

  /// ボタンサイズ（直径）。仕様書 §2.3 で 48×48 推奨。
  static const double size = 48.0;

  @override
  ConsumerState<UltimateButton> createState() => _UltimateButtonState();
}

/// ボタンの 4 状態。
enum _ButtonVisualState {
  disabled,  // UltGauge 未満タン
  ready,     // 押下可能（UltGauge 満タン + 未キュー）
  queued,    // キュー済
  finished,  // 戦闘終了
}

class _UltimateButtonState extends ConsumerState<UltimateButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  _ButtonVisualState get _visualState {
    if (widget.status != BattleStatus.running) {
      return _ButtonVisualState.finished;
    }
    if (widget.queueUltimate) return _ButtonVisualState.queued;
    if (widget.ultCost > 0 && widget.chargedCount >= widget.ultCost) {
      return _ButtonVisualState.ready;
    }
    return _ButtonVisualState.disabled;
  }

  bool get _isReady => _visualState == _ButtonVisualState.ready;

  @override
  void initState() {
    super.initState();
    if (_isReady) _pulseCtrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant UltimateButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 旧 ready → 新 ready ではない: アニメ停止 + リセット
    // 旧 ready ではない → 新 ready: アニメ開始
    final wasReady = oldWidget.status == BattleStatus.running
        && !oldWidget.queueUltimate
        && oldWidget.ultCost > 0
        && oldWidget.chargedCount >= oldWidget.ultCost;
    if (_isReady && !wasReady) {
      _pulseCtrl.repeat(reverse: true);
      // 【新規 (2026-06-26)】必殺ゲージ MAX 到達: 中程度 ~100ms「ヴォン」。
      // Android Waveform / iOS Core Haptics で「もうすぐ撃てる」合図を発火。
      BattleHapticsService.instance.playGaugeMax();
    } else if (!_isReady && wasReady) {
      _pulseCtrl.stop();
      _pulseCtrl.value = 0.0;
    }
  }

  @override
  void dispose() {
    // 【Pre-mortem #1 / CLAUDE.md】dispose 内で setState 呼ばない、Controller dispose のみ
    _pulseCtrl.dispose();
    super.dispose();
  }

  void _onTap() {
    // 【更新 (2026-06-26)】HapticFeedback.mediumImpact → BattleHapticsService。
    // ボタン押下時は「演出を邪魔しないほぼ感じない tap」、撃墜時の余韻演出と
    // 強度差を明確にする (ゲージ MAX / 撃墜 / ボタン の 3 段階強度設計)。
    BattleHapticsService.instance.playButtonPress();
    final result = ref.read(battleSessionProvider.notifier).tryQueueUltimate();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    switch (result) {
      case UltimateQueueResult.queued:
        // queue 成功は Tooltip 側で表現するため SnackBar 不要（過剰通知抑制）。
        break;
      case UltimateQueueResult.alreadyQueued:
        // 連打 = 黙って no-op（Pre-mortem #4 冪等化）。
        break;
      case UltimateQueueResult.notEnoughCharge:
        final remaining =
            (widget.ultCost - widget.chargedCount).clamp(1, widget.ultCost);
        final l10n = AppLocalizations.of(context)!;
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              l10n.battleUltimateNotReadySnackBarSabi_message(remaining),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
        break;
      case UltimateQueueResult.notRunning:
        // 戦闘終了済 → 通常は button 自体が finished で onTap が呼ばれない経路。
        break;
    }
  }

  String _tooltipMessage(_ButtonVisualState s, AppLocalizations l10n) {
    switch (s) {
      case _ButtonVisualState.disabled:
        final remaining =
            (widget.ultCost - widget.chargedCount).clamp(0, widget.ultCost);
        return remaining > 0
            ? l10n.battleUltimateChargingTooltipSabi_message(remaining)
            : l10n.battleUltimateChargingLabel;
      case _ButtonVisualState.ready:
        return l10n.battleUltimateReadyTooltipSabi_message;
      case _ButtonVisualState.queued:
        return l10n.battleUltimateQueuedTooltipSabi_message;
      case _ButtonVisualState.finished:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = _visualState;
    final isFinished = state == _ButtonVisualState.finished;

    // 状態別の見た目パラメータ。
    // - disabled: 半透明 (opacity 0.4)、押下可（SnackBar 用）
    // - ready: 通常 + パルス + グロー、押下可
    // - queued: わずかに沈み込み（scale 0.92）+ tint 強め、押下可（no-op）
    // - finished: 完全無効化（opacity 0.25）、押下不可
    final double opacity;
    final double scale;
    switch (state) {
      case _ButtonVisualState.disabled:
        opacity = 0.4;
        scale = 1.0;
        break;
      case _ButtonVisualState.ready:
        opacity = 1.0;
        scale = 1.0;
        break;
      case _ButtonVisualState.queued:
        opacity = 1.0;
        scale = 0.92;
        break;
      case _ButtonVisualState.finished:
        opacity = 0.25;
        scale = 1.0;
        break;
    }

    final tooltip = _tooltipMessage(state, l10n);

    final core = AnimatedBuilder(
      animation: _pulseCtrl,
      builder: (_, __) {
        // パルス: ready 中のみ動く（0.0 〜 1.0 を 900ms 周期）。
        final pulse = _isReady ? _pulseCtrl.value : 0.0;
        // ready 時のみグロー（影 0 → 12 を行き来）+ 軽い scale 1.0 → 1.06。
        final glowBlur = _isReady ? (4.0 + 8.0 * pulse) : 0.0;
        final readyScale = _isReady ? (1.0 + 0.06 * pulse) : 1.0;
        final effectiveScale = scale * readyScale;

        return Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: effectiveScale,
            child: Container(
              width:  UltimateButton.size,
              height: UltimateButton.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.gold,
                border: Border.all(
                  color: state == _ButtonVisualState.queued
                      ? Colors.white.withValues(alpha: 0.6)
                      : AppTheme.gold.withValues(alpha: 0.5),
                  width: state == _ButtonVisualState.queued ? 2.0 : 1.5,
                ),
                boxShadow: [
                  // 通常時の軽い影（Gemini §1.2「軽い影」準拠）
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.30),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                  // ready 中の周辺グロー（パルス連動）
                  if (_isReady)
                    BoxShadow(
                      color: AppTheme.gold.withValues(alpha: 0.55 * pulse),
                      blurRadius: glowBlur,
                      spreadRadius: 1.5 * pulse,
                    ),
                ],
              ),
              child: const Icon(
                Icons.bolt,
                size: 28,
                color: Colors.white,
              ),
            ),
          ),
        );
      },
    );

    final wrapped = RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: isFinished ? null : _onTap,
        child: core,
      ),
    );

    if (isFinished || tooltip.isEmpty) return wrapped;
    return Tooltip(message: tooltip, child: wrapped);
  }
}
