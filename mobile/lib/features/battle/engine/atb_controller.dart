import 'dart:async';

import 'package:flutter/foundation.dart';

import '../constants/battle_constants.dart';
import '../models/combatant.dart';

/// 【FEAT-295 Phase 1a】ATB タイマー（10fps tick、ゲージ充填式）。
///
/// 設計ノート §3.2 / §6.2 に基づく。`ChangeNotifier` を継承し、ゲージ更新時に
/// `notifyListeners()` を発火する（ただし fps を抑えるため毎 tick `notifyListeners`
/// は呼ばず、行動可能になったタイミングのみ通知する設計）。
///
/// **Pre-mortem #1 対応**:
///   - `dispose()` で必ず `_timer?.cancel(); _timer = null;`
///   - `pause()` でも `_timer = null` にして、resume 時に新規 Timer を立てる
///   - tick callback 内で `_disposed` を最初にチェック
///
/// **使用パターン**:
/// ```dart
/// final atb = AtbController(
///   player: playerCombatant,
///   enemy: enemyCombatant,
///   onTurnReady: (actor) => orchestrator.handleTurn(actor),
/// );
/// atb.start();
/// // 戦闘終了時:
/// atb.dispose();
/// ```
class AtbController extends ChangeNotifier {
  AtbController({
    required this.player,
    required this.enemy,
    required this.onTurnReady,
    this.speedMultiplier = 1.0,  // 【FEAT-416 (2026-06-01)】倍速モード乗数 default 1.0
  });

  final Combatant player;
  final Combatant enemy;

  /// ゲージ 1.0 到達時のコールバック。
  /// `actor == player` or `actor == enemy` で誰のターンかを伝える。
  final void Function(Combatant actor)? onTurnReady;

  // 【FEAT-416 (2026-06-01)】倍速モード乗数 (1.0 / 1.5 / 2.0 / 3.0)。
  // _onTick で `spd * atbSpeedModifier * speedMultiplier / tickRate` で適用。
  // mutable: UI からの setSpeedMultiplier で runtime 変更可、次 tick から反映。
  double speedMultiplier;

  Timer? _timer;
  bool _disposed = false;

  /// pause/resume 状態。`pause()` で false、`resume()` で true。
  bool _running = false;
  bool get isRunning => _running;

  /// 戦闘開始: 100ms tick の Timer を起動する。
  void start() {
    if (_disposed) return;
    if (_running) return;
    _running = true;
    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(milliseconds: BattleConstants.tickMs),
      _onTick,
    );
  }

  /// 一時停止: Timer を破棄するが、ゲージ値は保持。
  /// resume 時は同じゲージ値から再開できる。
  void pause() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  /// 一時停止状態から再開する。
  void resume() {
    if (_disposed) return;
    if (_running) return;
    start();
  }

  /// 【FEAT-416】倍速変更 — dispose 後は no-op (Pre-mortem S1 対応)。
  /// 進行中の atbGauge は維持し、次 tick から新速度で充填する。
  void setSpeedMultiplier(double value) {
    if (_disposed) return;
    speedMultiplier = value;
  }

  /// ゲージリセット: actor.atbGauge = 0.0。
  /// `onTurnReady` から呼び出して「行動完了 → 次の充填開始」を表現する。
  void resetGauge(Combatant actor) {
    actor.atbGauge = 0.0;
  }

  /// tick callback: ゲージ充填 + 1.0 到達で `onTurnReady` 発火。
  ///
  /// 【FEAT-404 (2026-06-01)】毎 tick `notifyListeners()` で ATB 進捗を通知する。
  /// orchestrator が `addListener` 経由で `state.value` を強制更新 →
  /// battle_provider が listener として反応 → widget rebuild で 10fps の
  /// ATB 充填アニメーションを実現。
  ///
  /// 旧実装は離散的イベント (ターン発火時) のみ state.value を更新していたため、
  /// 充填過程が UI に反映されず「ATB ゲージが最後まで進まない」現象が発生していた。
  /// HpAtbCombinedBar 側の AnimationController + tween と組み合わせで、
  /// 1.0 達成 → 即発火 → reset の高速遷移を「ほぼ満タン → 0.0」へ補間する。
  void _onTick(Timer _) {
    // 【Pre-mortem #1】dispose 後の tick で setState / notifyListeners を呼ばない
    if (_disposed) return;
    if (!_running) return;

    // 死亡している側はゲージ充填しない
    // 【FEAT-299】`atbSpeedModifier` をジョブ駆動で乗算する。
    // default 1.0 = 既存挙動互換（Pre-mortem #1 退行回避）。
    if (player.isAlive) {
      // 【FEAT-416】speedMultiplier を乗算。default 1.0 で既存挙動互換。
      player.atbGauge +=
          player.spd * player.atbSpeedModifier * speedMultiplier / BattleConstants.tickRate;
      if (player.atbGauge >= 1.0) {
        player.atbGauge = 1.0;
        _firePlayerTurn();
        return; // 1 tick で 1 ターンのみ発火（同時発火回避）
      }
    }

    if (enemy.isAlive) {
      // 【FEAT-416】speedMultiplier を乗算。
      enemy.atbGauge +=
          enemy.spd * enemy.atbSpeedModifier * speedMultiplier / BattleConstants.tickRate;
      if (enemy.atbGauge >= 1.0) {
        enemy.atbGauge = 1.0;
        _fireEnemyTurn();
        return;
      }
    }

    // 【FEAT-404】tick ごとに notifyListeners → orchestrator が state 更新 →
    // widget rebuild で ATB 充填過程を 10fps で描画。
    notifyListeners();
  }

  void _firePlayerTurn() {
    if (_disposed) return;
    onTurnReady?.call(player);
    notifyListeners();
  }

  void _fireEnemyTurn() {
    if (_disposed) return;
    onTurnReady?.call(enemy);
    notifyListeners();
  }

  @override
  void dispose() {
    // 【Pre-mortem #1】dispose 内で setState/notifyListeners を呼ばない
    // → Timer cancel + null clear のみ
    _disposed = true;
    _running = false;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
