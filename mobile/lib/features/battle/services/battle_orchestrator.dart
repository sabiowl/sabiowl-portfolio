// 【FEAT-295】Timer 自体は `AtbController` 側で管理するため、ここでは
// `dart:async` を直接 import せず、`ValueNotifier` のみ `flutter/foundation` から使う。
// 【FEAT-385 (2026-05-29)】攻撃エフェクト遅延発火用に `dart:async` Timer を追加 import。
import 'dart:async';
import 'dart:math' show Random;  // 【FEAT-333】創造力連動クリティカル判定で使用
import 'package:flutter/foundation.dart';

import '../engine/atb_controller.dart';
import '../engine/tactic_resolver.dart';
import '../models/ability.dart';
import '../models/battle_state.dart';
import '../models/combatant.dart';
import '../models/recovery_potion.dart';  // RecoveryPotion + RecoveryPotionPlus + AttackPotion (FEAT-376) + DefensePotion (FEAT-432)
import '../../../core/l10n/service_l10n.dart';  // 【FEAT-489 Phase 2E】battle log の l10n
import '../models/tactic.dart';
import '../widgets/combatant_sprite.dart' show SpriteAction;  // 【FEAT-385】攻撃エフェクト

/// 【FEAT-301】手動必殺ボタン押下の結果。UI 側はこの値に応じて
/// サビ口調 SnackBar / haptic feedback / Tooltip 状態を切り替える。
enum UltimateQueueResult {
  /// 押下成功 → `queueUltimate = true` 立った（次の ATB 満タンで ultimate 発動）。
  queued,

  /// 既に queue 済（連打、Pre-mortem #4 冪等化）。state 不変、副作用なし。
  alreadyQueued,

  /// UltGauge 未満タン（`chargedSpecialCount < ultCost`）。
  /// SnackBar: 「あと N 回通常攻撃を重ねれば必殺技が放てますよ 🪶」。
  notEnoughCharge,

  /// 戦闘進行中ではない（status != running or disposed）。
  /// 通常 UI 側で button 自体が無効化されているため、SnackBar 不要。
  notRunning,
}

/// 【FEAT-295 Phase 1c】戦闘進行管理（ローカル）。
///
/// 役割:
///   - `AtbController` を所有して tick を駆動
///   - `onTurnReady` で `TacticResolver` を呼んで次アビリティ決定
///   - ダメージ計算 + HP 更新 + ログ追記
///   - `BattleState` を `ValueNotifier` で公開（Riverpod 側で listen）
///
/// **Pre-mortem #1** 対応: `dispose()` で `AtbController` を破棄し、Timer race を防止。
///
/// 使用パターン:
/// ```dart
/// final orchestrator = BattleOrchestrator(
///   player: playerCombatant,
///   enemy: enemyCombatant,
///   tactic: Tactic.offense,
/// );
/// orchestrator.start();
/// // BattleState は orchestrator.stateNotifier から listen
/// ```
/// 【FEAT-333】創造力連動クリティカル判定用 Random インスタンス。
/// テスト時は決定論的シード注入を将来検討 (現状は実機ベース確率検証で十分)。
final _random = Random();

class BattleOrchestrator {
  BattleOrchestrator({
    required Combatant player,
    required Combatant enemy,
    required Tactic tactic,
    TacticResolver? resolver,
    int potionsPlanned = 0,
    // 【FEAT-376】新規ポーション種別
    int potionsPlusPlanned = 0,
    int attackPotionsPlanned = 0,
    // 【FEAT-432】防御の薬、攻撃の薬と完全対称
    int defensePotionsPlanned = 0,
    // 【FEAT-381 (2026-05-29)】戦闘画面背景画像 asset path (default '' = 単色フォールバック)。
    String enemyBackgroundImagePath = '',
    // 【FEAT-416 (2026-06-01)】SharedPreferences から復元した倍速設定 (default 1.0)。
    double initialSpeedMultiplier = 1.0,
  })  : _resolver = resolver ?? TacticResolver(),
        _potionsPlanned      = potionsPlanned.clamp(0, RecoveryPotion.maxPerBattle),
        _potionsPlusPlanned  = potionsPlusPlanned.clamp(0, RecoveryPotionPlus.maxPerBattle),
        _attackPotionsPlanned= attackPotionsPlanned.clamp(0, AttackPotion.maxPerBattle),
        _defensePotionsPlanned= defensePotionsPlanned.clamp(0, DefensePotion.maxPerBattle),
        _state = ValueNotifier<BattleState>(
          BattleState(
            player:   player,
            enemy:    enemy,
            tactic:   tactic,
            status:   BattleStatus.waiting,
            logLines: const [],
            startedAt: DateTime.now(),
            // 【FEAT-381】初期 state に背景画像パスを設定、Orchestrator 内 s.copyWith()
            // で毎 tick `this` から自動引き継ぎ (default '' は引き継ぎなし)。
            enemyBackgroundImagePath: enemyBackgroundImagePath,
            // 【BUG-79 (FEAT-416 hotfix、2026-06-10)】BattleState にも
            // initialSpeedMultiplier を伝搬。これを忘れると AtbController は
            // 復元値 (例: 3.0) で動くが BattleState.speedMultiplier は default
            // 1.0 のまま → _SpeedChip は 1x をハイライトしつつ実速度は 3x という
            // 同期ズレが発生する (= ユーザー報告「次のバトルで ×1 が選択されて
            // いても 3 倍速で動く」の真因)。FEAT-416 Pre-mortem S2 では
            // 「default 1.0 起点」前提を立てたが、AtbController と BattleState
            // 両方を復元値起点にすべきだった見落としに該当する。
            speedMultiplier: initialSpeedMultiplier,
          ),
        ) {
    _atb = AtbController(
      player: player,
      enemy:  enemy,
      onTurnReady: _onTurnReady,
      speedMultiplier: initialSpeedMultiplier,  // 【FEAT-416】SharedPreferences 復元値
    );
    // 【FEAT-404 (2026-06-01)】ATB tick の進捗を listen して state 強制更新。
    // 旧実装は離散的イベント (ターン発火) でしか state.value を更新せず、
    // tick ごとの ATB 充填が UI に反映されなかった (battle_provider は
    // orchestrator.state のみ listen するため)。本 listener で 10fps で
    // state.value を copy 通知 → widget rebuild → atbGauge を描画する。
    _atb.addListener(_onAtbProgress);
  }

  /// 【FEAT-404】AtbController の tick 進捗を battle_provider 経由で UI に反映。
  /// mutable Combatant の atbGauge は state.player/enemy 経由で読み取られるため、
  /// 強制 notify (copyWith 空) だけで build が走り 最新値が描画される。
  void _onAtbProgress() {
    if (_disposed) return;
    if (_state.value.status != BattleStatus.running) return;
    _state.value = _state.value.copyWith();
  }

  late final AtbController _atb;
  final TacticResolver _resolver;
  final ValueNotifier<BattleState> _state;

  /// 【FEAT-298】戦闘開始前に申告された回復薬使用上限。
  final int _potionsPlanned;
  /// 【FEAT-376】上位回復薬の使用上限。
  final int _potionsPlusPlanned;
  /// 【FEAT-376】攻撃の薬の使用上限。
  final int _attackPotionsPlanned;
  /// 【FEAT-432】防御の薬の使用上限。
  final int _defensePotionsPlanned;

  /// 【FEAT-298】戦闘中に実際に消費した回復薬数。
  int _potionsUsed = 0;
  /// 【FEAT-376】上位回復薬の実消費数。
  int _potionsPlusUsed = 0;
  /// 【FEAT-376】攻撃の薬の実消費数。
  int _attackPotionsUsed = 0;
  /// 【FEAT-432】防御の薬の実消費数。
  int _defensePotionsUsed = 0;

  /// 【FEAT-376】攻撃の薬が今ターン有効かどうか (使用したターン中のみ true)。
  bool _attackPotionActiveThisTurn = false;
  /// 【FEAT-432】防御の薬が今ターン有効かどうか (使用したターン中のみ true)。
  bool _defensePotionActiveThisTurn = false;

  /// 【FEAT-298 Pre-mortem #1】同一ターン内で複数発火しないためのガード。
  bool _potionUsedThisTurn = false;

  /// 戦闘中の回復薬残数。UI 残数表示用。
  int get potionsRemaining => _potionsPlanned - _potionsUsed;
  /// 【FEAT-376】上位回復薬の残数。
  int get potionsPlusRemaining => _potionsPlusPlanned - _potionsPlusUsed;
  /// 【FEAT-376】攻撃の薬の残数。
  int get attackPotionsRemaining => _attackPotionsPlanned - _attackPotionsUsed;
  /// 【FEAT-432】防御の薬の残数。
  int get defensePotionsRemaining => _defensePotionsPlanned - _defensePotionsUsed;

  /// 戦闘中に実際に消費した数（Backend 送信用）。
  int get potionsUsed => _potionsUsed;
  /// 【FEAT-376】Backend 送信用。
  int get potionsPlusUsed => _potionsPlusUsed;
  int get attackPotionsUsed => _attackPotionsUsed;
  /// 【FEAT-432】Backend 送信用。
  int get defensePotionsUsed => _defensePotionsUsed;

  /// 戦闘開始時の使用計画数（UI 進捗表示用）。
  int get potionsPlanned => _potionsPlanned;
  int get potionsPlusPlanned => _potionsPlusPlanned;
  int get attackPotionsPlanned => _attackPotionsPlanned;
  /// 【FEAT-432】防御の薬の使用計画数。
  int get defensePotionsPlanned => _defensePotionsPlanned;

  /// 公開 ValueNotifier。Riverpod / Widget 側で `valueListenable` として listen 可。
  ValueListenable<BattleState> get state => _state;

  /// 戦闘開始: ステータスを running に切替 + ATB tick 開始。
  void start() {
    if (_disposed) return;
    if (_state.value.status != BattleStatus.waiting) return;
    _state.value = _state.value.copyWith(status: BattleStatus.running);
    _atb.start();
  }

  /// 【FEAT-301】手動必殺ボタン押下処理。3 条件を順にチェックし、すべて満たせば
  /// `BattleState.queueUltimate = true` を立てる。立てたあとは `_handlePlayerTurn`
  /// が次の ATB 満タン到達時に Resolver を上書きして ultimate を発動する。
  ///
  /// チェック順（早期 return）:
  ///   1. 戦闘進行中でなければ `notRunning` (status != running / disposed)
  ///   2. 既に queue 済なら `alreadyQueued`（連打冪等化、Pre-mortem #4）
  ///   3. UltGauge 未満タンなら `notEnoughCharge`（最頻ケース）
  ///   4. ATB 未満タンでも queue 自体は許可 → 「次のターンで発動」する設計
  ///      （Tactic 切替との race も queue 優先で吸収、Pre-mortem #3）
  ///
  /// 戻り値はサビ口調 SnackBar の出し分けに使う（呼び出し側 = UI）。
  UltimateQueueResult tryQueueUltimate() {
    if (_disposed) return UltimateQueueResult.notRunning;
    final s = _state.value;
    if (s.status != BattleStatus.running) return UltimateQueueResult.notRunning;
    if (s.queueUltimate) return UltimateQueueResult.alreadyQueued;
    if (s.chargedSpecialCount < s.player.ultCost) {
      return UltimateQueueResult.notEnoughCharge;
    }
    _state.value = s.copyWith(queueUltimate: true);
    return UltimateQueueResult.queued;
  }

  /// 中断: ステータス abandoned + Timer 停止。
  void abandon() {
    if (_disposed) return;
    _atb.pause();
    _state.value = _state.value.copyWith(
      status:  BattleStatus.abandoned,
      endedAt: DateTime.now(),
    );
  }

  void _onTurnReady(Combatant actor) {
    if (_disposed) return;
    final s = _state.value;
    if (s.status != BattleStatus.running) return;

    final isPlayer = actor.id == s.player.id;

    // 【FEAT-298 Pre-mortem #1】各 turn 開始時にフラグリセット。
    _potionUsedThisTurn        = false;
    // 【FEAT-376】攻撃の薬の効果は1ターンのみ → turn開始時にリセット。
    _attackPotionActiveThisTurn = false;
    // 【FEAT-432】防御の薬の効果は1ターンのみ → turn開始時にリセット。
    _defensePotionActiveThisTurn = false;

    if (isPlayer) {
      // 【FEAT-376】攻撃の薬: プレイヤーのターンで在庫があれば自動使用 (HP 関係なし)
      _tryUseAttackPotion();
      _handlePlayerTurn();
    } else {
      // 【FEAT-432】防御の薬: 敵のターン（プレイヤーが被ダメージするターン）で
      // 在庫があれば自動使用 (HP 関係なし)。攻撃の薬と完全対称。
      _tryUseDefensePotion();
      _handleEnemyTurn();
    }

    // ゲージリセット
    _atb.resetGauge(actor);

    // 【FEAT-298】行動解決後に自動回復薬チェック。
    // 敵攻撃の直後（HP が削られた直後）に発火するのが本命のタイミング。
    // 戦闘終了（won/lost）後は発火しない（_state.value.status を再評価）。
    _checkAutoPotion();
  }

  /// 【FEAT-298 + FEAT-376】HP <= 30% で回復薬を自動使用する。
  ///
  /// 優先順位: 上位回復薬 (HP 全回復) → 通常回復薬 (HP 50% 回復)
  /// 各 turn 1 個まで (_potionUsedThisTurn ガード)。
  void _checkAutoPotion() {
    if (_disposed) return;
    final s = _state.value;
    if (s.status != BattleStatus.running) return;
    if (_potionUsedThisTurn) return;
    if (s.player.maxHp <= 0) return;

    final hpPct = s.player.currentHp / s.player.maxHp;
    if (hpPct > RecoveryPotion.autoUseHpThreshold) return;

    // 【FEAT-376】上位回復薬を優先消費 (HP 全回復)
    if (potionsPlusRemaining > 0) {
      final healAmount = RecoveryPotionPlus.healAmount(s.player.maxHp);
      final newHp = (s.player.currentHp + healAmount).clamp(0, s.player.maxHp);
      final actualHeal = newHp - s.player.currentHp;
      s.player.currentHp = newHp;
      _potionsPlusUsed++;
      _potionUsedThisTurn = true;

      final newLog = List<String>.from(s.logLines)
        ..add(ServiceL10n.current.battleLogPotionPlusUsedSabi_message(
          RecoveryPotionPlus.emoji,
          RecoveryPotionPlus.displayName,
          actualHeal,
          potionsPlusRemaining,
        ));
      _state.value = s.copyWith(logLines: newLog);
      return;
    }

    // 通常回復薬 (HP 50% 回復)
    if (potionsRemaining <= 0) return;

    final healAmount = RecoveryPotion.healAmount(s.player.maxHp);
    final newHp =
        (s.player.currentHp + healAmount).clamp(0, s.player.maxHp);
    final actualHeal = newHp - s.player.currentHp;
    s.player.currentHp = newHp;
    _potionsUsed++;
    _potionUsedThisTurn = true;

    final newLog = List<String>.from(s.logLines)
      ..add(ServiceL10n.current.battleLogPotionRecoveryUsedSabi_message(
        RecoveryPotion.emoji,
        RecoveryPotion.displayName,
        actualHeal,
        potionsRemaining,
      ));
    _state.value = s.copyWith(logLines: newLog);
  }

  /// 【FEAT-376】攻撃の薬: プレイヤーの攻撃ターン先頭で在庫があれば自動使用。
  /// 効果: そのターンの攻撃力 +50% (_attackPotionActiveThisTurn = true)。
  void _tryUseAttackPotion() {
    if (_disposed) return;
    if (attackPotionsRemaining <= 0) return;
    final s = _state.value;
    if (s.status != BattleStatus.running) return;

    _attackPotionsUsed++;
    _attackPotionActiveThisTurn = true;

    final newLog = List<String>.from(s.logLines)
      ..add(ServiceL10n.current.battleLogPotionAttackUsedSabi_message(
        AttackPotion.emoji,
        AttackPotion.displayName,
        attackPotionsRemaining,
      ));
    _state.value = s.copyWith(logLines: newLog);
  }

  /// 【FEAT-432】防御の薬: 敵の攻撃ターン先頭で在庫があれば自動使用。
  /// 効果: そのターンの被ダメージ ÷1.5 (_defensePotionActiveThisTurn = true)。
  /// 攻撃の薬 (_tryUseAttackPotion) と完全対称。
  void _tryUseDefensePotion() {
    if (_disposed) return;
    if (defensePotionsRemaining <= 0) return;
    final s = _state.value;
    if (s.status != BattleStatus.running) return;

    _defensePotionsUsed++;
    _defensePotionActiveThisTurn = true;

    final newLog = List<String>.from(s.logLines)
      ..add(ServiceL10n.current.battleLogPotionDefenseUsedSabi_message(
        DefensePotion.emoji,
        DefensePotion.displayName,
        defensePotionsRemaining,
      ));
    _state.value = s.copyWith(logLines: newLog);
  }

  void _handlePlayerTurn() {
    final s = _state.value;

    // 【FEAT-301】手動キュー最優先: queueUltimate && UltGauge 満タン なら
    // Tactic 判定をスキップして ultimate 発動する（Tactic 非依存 = 切替された
    // 状態でも「押した = 出る」のユーザー直感を保つ、Pre-mortem #3 緩和）。
    // 旧 FEAT-300 hotfix の chargedSpecialCount ability 駆動更新は維持。
    final Ability ability;
    if (s.queueUltimate && s.chargedSpecialCount >= s.player.ultCost) {
      ability = Ability.ultimate;
    } else {
      ability = _resolver.resolveNextAbility(s);
    }

    // 【FEAT-300 hotfix】chargedSpecialCount を **Tactic 非依存** + ability 駆動 +
    // ultCost 動的 clamp に切替（Gemini battle_system_2.md §1.2「通常攻撃ごとに
    // 下のマスから点灯」準拠）。
    //
    // 【BUG-75 修正 (2026-05-29)】Ability.strong (強攻撃) でも +1 蓄積するよう拡張。
    // - normal:   +1（ultCost で clamp、Tactic に関係なく蓄積）
    // - strong:   +1（攻撃系 ability として扱う、Tactic.offense / recovery の 50% 経路で
    //             ゲージが貯まらない UX 破綻を解消）
    // - ultimate: 0 にリセット（発動消費）
    // - heal:     既存値維持（回復行動なので攻撃カウントには含めない）
    //
    // 旧 FEAT-300 hotfix は「Tactic 非依存化」(旧バグ修正) を実施したが、Ability.strong
    // も攻撃系として扱うべき観点を見落とし、Ability.normal のみ +1 とした不完全な hotfix
    // だった。Tactic.offense (50% strong) や Tactic.recovery (HP<50% で strong) を選んだ
    // ユーザーが「攻撃しても必殺ゲージが貯まらない」UX 破綻を体験する設計不整合だった。
    //
    // 旧 clamp は `BattleConstants.ultimateChargeRequired = 3` 固定で、ジョブ別
    // ultCost（berserker=1 / thief=4 等）を反映できていなかった FEAT-299 スコープ
    // 漏れも併せて解消。`s.player.ultCost` で正しく動的 clamp する。
    final int newCharged;
    if (ability == Ability.normal || ability == Ability.strong) {
      newCharged =
          (s.chargedSpecialCount + 1).clamp(0, s.player.ultCost);
    } else if (ability == Ability.ultimate) {
      newCharged = 0;
    } else {
      // Ability.heal: 回復行動なので攻撃カウントには含めない、既存値維持
      newCharged = s.chargedSpecialCount;
    }

    // 【FEAT-301】ultimate 発動時に queueUltimate もリセット（1 回発動 = 1 回消費）。
    // それ以外（手動キュー無し or 通常攻撃連打）は既存値維持。
    final bool clearQueue = ability == Ability.ultimate;

    _applyAbility(
      attacker: s.player,
      target:   s.enemy,
      ability:  ability,
      isPlayerAction: true,
      newChargedSpecialCount: newCharged,
      clearQueueUltimate: clearQueue,
    );
  }

  void _handleEnemyTurn() {
    final s = _state.value;
    _applyAbility(
      attacker: s.enemy,
      target:   s.player,
      ability:  Ability.normal, // MVP では敵は通常攻撃のみ
      isPlayerAction: false,
      newChargedSpecialCount: s.chargedSpecialCount,
    );
  }

  void _applyAbility({
    required Combatant attacker,
    required Combatant target,
    required Ability ability,
    required bool isPlayerAction,
    required int newChargedSpecialCount,
    bool clearQueueUltimate = false,
  }) {
    final s = _state.value;
    final def = kAbilityDefs[ability]!;
    int dealtDamage = 0;
    // 【2026-07-05】overkill 分を除外した実効ダメージ。totalDamageDealt (Backend 送信)
    // には本値のみカウントし、raw dealtDamage は logLine / エフェクトで表示用に維持。
    // heal 経路では 0 のまま (集計に影響なし)。
    int effectiveDamage = 0;
    int healAmount  = 0;
    String logLine;
    // 【FEAT-299】on_hit_effect 適用後の追加ログ行（複数になる可能性、空なら追記なし）。
    final extraLogs = <String>[];
    // 【FEAT-385】attack 時のクリティカル判定フラグ。else ブロック内 (攻撃経路) で
    // `dmgResult.criticalLogs.isNotEmpty` を代入、メソッド末尾の攻撃エフェクト
    // 発火で参照する (dmgResult は else ブロックのローカル変数のためスコープ外
    // 参照不可、本フラグで橋渡し)。
    bool isCriticalAttack = false;

    if (ability == Ability.heal) {
      // 自分回復（HP%）
      final heal = (attacker.maxHp * def.healPercent).round();
      final newHp = (attacker.currentHp + heal).clamp(0, attacker.maxHp);
      healAmount = newHp - attacker.currentHp;
      attacker.currentHp = newHp;
      logLine = ServiceL10n.current
          .battleLogHeal(attacker.name, healAmount);
    } else {
      // 攻撃: ATK × multiplier × ジョブ攻撃力倍率
      // 【FEAT-299】`attackPowerModifier` をジョブ駆動で乗算する。
      // 【FEAT-376】isPlayerAction かつ _attackPotionActiveThisTurn=true なら
      //            さらに AttackPotion.atkMultiplier (×1.5) を乗算。
      // 【FEAT-432】!isPlayerAction かつ _defensePotionActiveThisTurn=true なら
      //            さらに DefensePotion.damageReductionFactor (÷1.5) で軽減。
      //            攻撃の薬と完全対称（preResist への乗除で統一）。
      final base = attacker.atk * def.atkMultiplier;
      final attackPotionBonus =
          (isPlayerAction && _attackPotionActiveThisTurn)
              ? AttackPotion.atkMultiplier
              : 1.0;
      final defensePotionFactor =
          (!isPlayerAction && _defensePotionActiveThisTurn)
              ? DefensePotion.damageReductionFactor
              : 1.0;
      final preResist = base * attacker.attackPowerModifier * attackPotionBonus
          / defensePotionFactor;

      // 【FEAT-302】弱点 / 耐性: target.physical/magical_resistance + weak_ult_cost。
      // - jobName で attack_type 判定（warrior/berserker/thief = physical / mage/cleric = magical）
      // - default は physical（敵側 attacker 等で jobName='' のときも physical 扱い、既存挙動互換）
      // - weak_ult_cost 一致時は Critical ログ + 1.3x
      final dmgResult =
          _applyResistance(preResist, attacker, target);
      dealtDamage = dmgResult.damage;
      // 【2026-07-05】overkill 分は `totalDamageDealt` にカウントしない。
      // dragon_slayer(+50) + FEAT-333 crit + 攻撃の薬 + 弱点等が乗算されると
      // 単発 damage が敵残 HP を大きく超え、raw の合計を Backend に送ると
      // `damage_dealt > enemy_hp_init * 5` 検証 (battle.py:_MAX_DAMAGE_MULTIPLIER)
      // で 400 (damage_unreasonable) が返り、報酬 0 表示 + ギルド画面クエスト数
      // 停滞バグ (2026-07-05 報告) の根本原因となる。ログ / エフェクトは
      // 従来通り raw の dealtDamage で表示 (プレイヤー体験の派手さ維持)。
      effectiveDamage =
          dealtDamage < target.currentHp ? dealtDamage : target.currentHp;
      target.currentHp = (target.currentHp - dealtDamage).clamp(0, target.maxHp);
      logLine = ServiceL10n.current.battleLogAttackLine(
          attacker.name, def.label, target.name, dealtDamage);
      // 【FEAT-333】weak_ult_cost crit + 創造力 critRate の両方の crit ログを追加。
      extraLogs.addAll(dmgResult.criticalLogs);
      // 【FEAT-385】Critical 判定を外側スコープ (メソッド末尾の攻撃エフェクト
      // 発火) で参照可能にするため、ローカル dmgResult の判定結果をフラグに保存。
      isCriticalAttack = dmgResult.criticalLogs.isNotEmpty;

      // 【FEAT-299】on_hit_effect: 攻撃時の追加効果（burn / heal）。
      // Pre-mortem #3 で「DoT は内部で即時加算に簡略化、tick 管理不要」採用。
      if (attacker.onHitEffect == 'burn' && target.isAlive) {
        // burn: 敵 max_hp × 0.02 × 3 を即時加算ダメージとして与える。
        // 【FEAT-302】magic 系の追加ダメージなので target.magicalResistance を適用。
        final baseBurn = target.maxHp * 0.02 * 3;
        final burnDmg = (baseBurn * target.magicalResistance)
            .round()
            .clamp(1, 9999);
        target.currentHp =
            (target.currentHp - burnDmg).clamp(0, target.maxHp);
        extraLogs.add(
          ServiceL10n.current.battleLogBurn(target.name, burnDmg),
        );
      } else if (attacker.onHitEffect == 'heal' && attacker.isAlive) {
        // heal: 与ダメージ × 0.10 を自分に吸収（attacker 自身への効果なので
        // target.resistance の影響は受けない、純粋な吸収率）
        final absorb = (dealtDamage * 0.10).round().clamp(1, 9999);
        final newHp = (attacker.currentHp + absorb)
            .clamp(0, attacker.maxHp);
        final actual = newHp - attacker.currentHp;
        if (actual > 0) {
          attacker.currentHp = newHp;
          extraLogs.add(
            ServiceL10n.current.battleLogDrain(attacker.name, actual),
          );
        }
      }
    }

    final newLog = List<String>.from(s.logLines)
      ..add(logLine)
      ..addAll(extraLogs);

    // 勝敗判定
    BattleStatus newStatus = s.status;
    DateTime? newEndedAt;
    // 【FEAT-526】とどめの一撃イベント (KO 演出の発火キー)。
    KoEvent? koEvent;
    if (!s.enemy.isAlive) {
      newStatus  = BattleStatus.won;
      newEndedAt = DateTime.now();
      _atb.pause();
      // 【FEAT-526 (2026-08-21)】この分岐は **「今回のダメージで敵の HP が 0 以下に
      // なった」瞬間にしか通らない** (status が一度 won になると running ガードで
      // 以降の tick が入らない)。したがって KoEvent は 1 バトルにつき 1 回しか
      // 立たず、重複ガードを別に足す必要がない。
      //
      // 🔴 `lost` 側では設定しない。「決めた」と「やられた」は演出の意味が逆で、
      // 敗北演出は別設計が要る (指示書 決定事項 3)。
      koEvent = KoEvent(damage: dealtDamage, isCritical: isCriticalAttack);
    } else if (!s.player.isAlive) {
      newStatus  = BattleStatus.lost;
      newEndedAt = DateTime.now();
      _atb.pause();
    }

    // 【2026-07-05】newDealt / newTaken は effectiveDamage (overkill 除外) を集計。
    // heal 経路では effectiveDamage が代入されず 0 のままなので影響なし。
    // 攻撃経路のみ overkill 除外の効果が働き、Backend 側 damage_unreasonable
    // 誤検知を防ぐ。詳細は上の Attack 分岐コメント参照。
    final newDealt = s.totalDamageDealt + (isPlayerAction ? effectiveDamage : 0);
    final newTaken = s.totalDamageTaken + (isPlayerAction ? 0 : effectiveDamage);

    // 【FEAT-333】健康力連動 hpRegenPerTurn: turn 終了時に attacker の HP を自然回復。
    // 戦闘継続中 (running) + 生存中 のときのみ発火。default 0 = 発火しない (既存挙動互換)。
    // ヒール action (Ability.heal) と二重発火しても問題なし (どちらも attacker.maxHp 上限で
    // clamp、log 行が両方出るだけで HP は maxHp を超えない)。
    if (attacker.hpRegenPerTurn > 0 &&
        newStatus == BattleStatus.running &&
        attacker.isAlive) {
      final regenHp =
          (attacker.currentHp + attacker.hpRegenPerTurn).clamp(0, attacker.maxHp);
      final actualRegen = regenHp - attacker.currentHp;
      if (actualRegen > 0) {
        attacker.currentHp = regenHp;
        newLog.add(
          ServiceL10n.current.battleLogRegen(attacker.name, actualRegen));
      }
    }

    _state.value = s.copyWith(
      logLines:            newLog,
      chargedSpecialCount: newChargedSpecialCount,
      // 【FEAT-301】ultimate 発動時は queue 消費 → false に戻す（明示 false 指定）。
      // それ以外は null を渡すことで copyWith 側の `?? this.queueUltimate` で既存値維持。
      queueUltimate:       clearQueueUltimate ? false : null,
      status:              newStatus,
      endedAt:             newEndedAt,
      totalDamageDealt:    newDealt,
      totalDamageTaken:    newTaken,
      rounds:              s.rounds + 1,
      // 【FEAT-526】status = won と **同じ copyWith** で設定する。
      // 非 KO 時は null を渡すが、copyWith 側が `?? this.koEvent` なので
      // 既存値を消す事故が起きない (センチネル不使用の理由)。
      koEvent:             koEvent,
    );

    // 【FEAT-385 (2026-05-29)】攻撃エフェクト発火 (ability != heal && damage 発生時のみ)。
    // - 攻撃者: charge → 200ms 後 slash → 500ms 後 idle 復帰
    // - 被攻撃者: recoil → 500ms 後 idle 復帰 + DamageEvent クリア
    // - クリティカル判定: isCriticalAttack (else ブロック内で代入済、FEAT-302
    //   弱点 + FEAT-333 創造力連動の両方を統合判定 = dmgResult.criticalLogs)
    // - 戦闘終了 (won/lost) でも一旦エフェクトは発火、CombatantSprite 側で
    //   fadeOut が action より優先されるため自然遷移
    if (ability != Ability.heal && dealtDamage > 0) {
      _triggerAttackEffect(
        attackerIsPlayer: isPlayerAction,
        dealtDamage:      dealtDamage,
        isCritical:       isCriticalAttack,
      );
    }

    // 【新規 (2026-06-26)】撃墜エフェクト発火 (プレイヤーの必殺技ヒット時のみ)。
    // UI 側 (battle_page) が ref.listen で transition を検知し、ハプティクス +
    // 画面シェイク + 白フラッシュ + 爆発リング を同フレーム同期発火する。
    // ~400ms 後に null に戻す (二度目の発火を別 timestamp で識別するための clear)。
    if (ability == Ability.ultimate && isPlayerAction && dealtDamage > 0) {
      _triggerUltimateHitEvent(
        dealtDamage: dealtDamage,
        isCritical:  isCriticalAttack,
      );
    }
  }

  /// 【新規 (2026-06-26)】撃墜エフェクト用 UltimateHitEvent 発火 + 自動クリア。
  void _triggerUltimateHitEvent({
    required int dealtDamage,
    required bool isCritical,
  }) {
    if (_disposed) return;
    final event = UltimateHitEvent(
      damage:     dealtDamage,
      isCritical: isCritical,
    );
    _state.value = _state.value.copyWith(ultimateHitEvent: event);
    // 400ms 後にクリア (撃墜演出時間 ~350ms + バッファ 50ms)
    _scheduleEffectReset(const Duration(milliseconds: 400), () {
      // 自分以外の event で上書きされていなければ null に戻す
      if (_state.value.ultimateHitEvent == event) {
        _state.value = _state.value.copyWith(ultimateHitEvent: null);
      }
    });
  }

  // ────────────────────────────────────────────────────────────────────────
  // 【FEAT-385】攻撃エフェクト (SpriteAction + Floating Damage) 発火経路
  // ────────────────────────────────────────────────────────────────────────

  /// 攻撃エフェクト Timer 管理 (dispose で全 cancel、Pre-mortem race 回避)。
  final List<Timer> _effectTimers = [];

  /// 攻撃発生時の SpriteAction 切り替え + DamageEvent 設定。
  ///
  /// 演出フロー:
  ///   1. 即時: 攻撃者 charge + 被攻撃者 recoil + DamageEvent 設定
  ///   2. 200ms 後: 攻撃者 slash (斬撃エフェクト、被攻撃者は recoil 継続)
  ///   3. 500ms 後: 両者 idle 復帰 + DamageEvent クリア
  ///
  /// _disposed チェック + Timer 管理で Pre-mortem race を構造的に防止。
  void _triggerAttackEffect({
    required bool attackerIsPlayer,
    required int dealtDamage,
    required bool isCritical,
  }) {
    if (_disposed) return;

    // 【FEAT-526 §4.5 (2026-08-21)】🔴 KO のときは **前の攻撃が残した復帰 Timer**
    // をここで畳む。
    //
    // 自分の分を張らないだけでは足りない。ATB は 300ms 前後で 1 手進むのに対し
    // 復帰 Timer の遅延は 500ms なので、**とどめが入った時点で 1 つ前の攻撃の
    // 復帰 Timer がまだ飛んでいる**。放置すると KO 演出の途中でそれが発火し、
    // 両者が idle に戻って待機ユラユラが再開してしまう。
    //
    // ここで畳んでよいのは、`_effectTimers` に入っているのが「攻撃演出を元に
    // 戻す」用途の Timer だけだからである (`_scheduleEffectReset` の呼び出し元は
    // 本メソッドと `_triggerUltimateHitEvent` の event クリアのみ)。
    if (_state.value.status == BattleStatus.won) {
      for (final t in _effectTimers) {
        t.cancel();
      }
      _effectTimers.clear();
    }

    final damageEvent = DamageEvent(
      amount:     dealtDamage,
      isCritical: isCritical,
    );

    // フェーズ 1 (即時): 攻撃者 charge + 被攻撃者 recoil + DamageEvent 設定
    _state.value = _state.value.copyWith(
      playerAction: attackerIsPlayer ? SpriteAction.charge : SpriteAction.recoil,
      enemyAction:  attackerIsPlayer ? SpriteAction.recoil : SpriteAction.charge,
      enemyDamageEvent:  attackerIsPlayer ? damageEvent : null,
      playerDamageEvent: attackerIsPlayer ? null : damageEvent,
    );

    // フェーズ 2 (200ms 後): 攻撃者 slash (被攻撃者は recoil 継続)
    _scheduleEffectReset(const Duration(milliseconds: 200), () {
      final current = _state.value;
      _state.value = current.copyWith(
        playerAction: attackerIsPlayer ? SpriteAction.slash : current.playerAction,
        enemyAction:  attackerIsPlayer ? current.enemyAction : SpriteAction.slash,
      );
    });

    // フェーズ 3 (500ms 後): 両者 idle 復帰 + DamageEvent クリア
    //
    // 【FEAT-526 §4.5 A 案 (2026-08-21)】🔴 **KO のときはこの復帰 Timer を張らない。**
    //
    // ここは素の `Timer` なので `_atb.pause()` では止まらない。KO 演出 (650ms) の
    // 途中で発火すると **両者が idle に戻り、待機ユラユラが再開する** ——
    // 出典が求める「最後の攻撃が命中した姿勢を維持」が崩れ、間の抜けた絵になる。
    //
    // B 案 (復帰 Timer の遅延を演出時間だけ伸ばす) ではなく A 案を採ったのは、
    // **演出後は結局 fadeOut に入るので idle へ戻す意味が無い**から。
    // 遅延を伸ばす実装は「演出時間」を orchestrator にも知らせる必要があり、
    // 表示レイヤーの関心事をモデル側へ漏らすことになる (§4.1 と同じ理由)。
    //
    // 副作用として KO 時は `enemyDamageEvent` もクリアされないが、これは
    // **とどめのダメージ数字が演出中ずっと出ている**ということで、望ましい。
    // 次のバトルは新しい `BattleState` から始まるので持ち越しも起きない。
    //
    // フェーズ 2 (charge → slash) は KO でも張ったままにする。`slash` は 150ms の
    // 斬撃線がフェードして終わる一過性エフェクトで、その後は通常の立ち絵に戻る
    // ため「斬った姿勢のまま止まる」という意図どおりの絵になる。
    if (_state.value.status == BattleStatus.won) return;

    _scheduleEffectReset(const Duration(milliseconds: 500), () {
      _state.value = _state.value.copyWith(
        playerAction: SpriteAction.idle,
        enemyAction:  SpriteAction.idle,
        enemyDamageEvent:  null,  // 明示 null = 表示済みクリア (_Unset と区別)
        playerDamageEvent: null,
      );
    });
  }

  /// 攻撃エフェクト Timer をリストで管理 + dispose で cancel。
  void _scheduleEffectReset(Duration delay, void Function() reset) {
    if (_disposed) return;
    late Timer timer;
    timer = Timer(delay, () {
      _effectTimers.remove(timer);
      if (!_disposed) reset();
    });
    _effectTimers.add(timer);
  }

  bool _disposed = false;

  /// 【FEAT-416 (2026-06-01)】UI からの倍速切替。AtbController に伝搬し、
  /// BattleState state にも反映することで _SpeedChip の rebuild を誘発する。
  /// dispose 後は no-op (Pre-mortem S1 対応)。
  void setSpeedMultiplier(double value) {
    if (_disposed) return;
    _atb.setSpeedMultiplier(value);
    _state.value = _state.value.copyWith(speedMultiplier: value);
  }

  /// 【BUG (2026-06-25)】戦闘中の作戦 (Tactic) 切替を orchestrator 内部 state
  /// に反映する。旧実装 (FEAT-295 Phase 1a) は battle_provider 側のみ
  /// state.copyWith していたため、FEAT-404 (2026-06-01) で ATB tick 通知が
  /// 10fps 化された結果、`_onAtbProgress` 経由の orchestrator state (古い
  /// tactic) で 100ms 以内に巻き戻る退行が発生していた。本メソッドで
  /// orchestrator 側を真実値として更新し、battle_provider は listener 経由で
  /// 自動同期に切り替える。
  ///
  /// Pre-mortem:
  ///   - S1 (dispose race): `_disposed` ガードで BUG-66 系の defunct 防止
  ///   - S2 (戦闘終了後タップ): UI 側で ChoiceChip が非表示になる前提のため
  ///     基本到達しないが、status 問わず state.copyWith 自体は無害
  ///   - S3 (TacticResolver 反映タイミング): TacticResolver は毎ターン
  ///     state.tactic を読むため、setTactic 後の次ターン解決から即反映
  void setTactic(Tactic tactic) {
    if (_disposed) return;
    _state.value = _state.value.copyWith(tactic: tactic);
  }

  /// 【BUG (2026-06-25)】戦闘開始前 BottomSheet で 1 個以上の回復薬 (基本 +
  /// 上位) をセットしているか。`Tactic.recovery` (回復重視) の UI 表示判定に
  /// 使用し、両方 0 のときは選択肢自体を非表示にする。
  ///
  /// 攻撃 / 防御の薬は「回復薬」ではないため判定対象外。
  bool get hasRecoveryPotions =>
      _potionsPlanned > 0 || _potionsPlusPlanned > 0;

  /// 【FEAT-302 + FEAT-333】ダメージ計算ヘルパー: 弱点 / 耐性 + Stat 連動を適用する。
  ///
  /// 計算手順:
  ///   1. `_attackTypeOf(attacker.jobName)` で physical / magical を判定
  ///   2. 対応する `target.physicalResistance` or `target.magicalResistance` を乗算
  ///   3. `target.weakUltCost != null && == attacker.ultCost` なら ×1.3 + Critical ログ
  ///   4. 【FEAT-333】創造力連動 critRate: `random < critRate` で ×1.5 + Critical ログ
  ///      (weak_ult_cost crit と独立、両方発火する可能性あり)
  ///   5. 【FEAT-333】貢献力連動 damageReduction: 最終ダメージ × (1 - reduction)
  ///
  /// default 値 (resistance=1.0 / critRate=0.0 / damageReduction=0.0) で既存挙動完全互換
  /// (Pre-mortem #1 退行回避)。
  _DamageResult _applyResistance(
      double baseDamage, Combatant attacker, Combatant target) {
    final attackType = _attackTypeOf(attacker.jobName);
    final resistance = attackType == _AttackType.magical
        ? target.magicalResistance
        : target.physicalResistance;
    double adjusted = baseDamage * resistance;
    final critLogs = <String>[];
    if (target.weakUltCost != null && target.weakUltCost == attacker.ultCost) {
      adjusted *= 1.3;
      critLogs.add(
          ServiceL10n.current.battleLogWeaknessCritical(target.name));
    }
    // 【FEAT-333】創造力連動 critRate: random < critRate で damage × 1.5。
    // weak_ult_cost crit と独立、両方発火することもある (学習力 × 創造力ビルドの想定)。
    if (attacker.critRate > 0.0 && _random.nextDouble() < attacker.critRate) {
      adjusted *= 1.5;
      critLogs.add(ServiceL10n.current.battleLogCritical(attacker.name));
    }
    // 【FEAT-333】貢献力連動 damageReduction: 受けるダメージ × (1 - damageReduction)。
    // 最後に適用 (resistance + crit 含めた最終ダメージに乗算)。
    if (target.damageReduction > 0.0) {
      adjusted *= (1.0 - target.damageReduction);
    }
    return _DamageResult(
      damage: adjusted.round().clamp(1, 9999),
      criticalLogs: critLogs,
    );
  }

  /// 【FEAT-302】attack_type を jobName から判定。
  /// warrior / berserker / thief → physical
  /// mage / cleric → magical
  /// その他（空文字 / 敵 / 未知ジョブ）→ physical (default、既存挙動互換)
  _AttackType _attackTypeOf(String jobName) {
    // 【FEAT-489 Phase 2F-a — 既知の不具合、意図的に未修正】
    //
    // 本判定は **表示名** で分岐しているが、下の一覧に完全一致する job_name は
    // 現行 DB に 1 件も無い (migration 0112/0128/0138/0147 で 魔導士 → 青魔導士 /
    // 黒魔導士 / 闇魔導士、僧侶 → 白魔導士 に改名されたが本一覧が追従していない)。
    // つまり **常に physical が返る dead branch** で、これは Phase 2F-a より前から
    // 存在する。さらに Backend `Job.job_name_en` 追加 (migration 0198) で job_name は
    // locale 依存になったため、表示名で分岐する設計自体が誤りになった。
    //
    // 正しい修正は `jobId` (locale 非依存) での分岐だが、それは
    // 「今まで全 physical だった魔法職が magical になる」= **敵耐性計算が変わる
    // ゲームバランス変更**になるため、l10n の Phase では触らず PM 判断に回す。
    // したがって本リテラルは表示文字列ではなく判定データとして残置する。
    const magicalJobs = ['魔導士', '僧侶', 'mage', 'cleric'];
    if (magicalJobs.contains(jobName)) return _AttackType.magical;
    return _AttackType.physical;
  }

  /// dispose: AtbController + ValueNotifier を破棄。
  /// **Pre-mortem #1**: dispose 後の tick callback は AtbController 側で
  /// `_disposed` チェックで早期 return する設計。
  void dispose() {
    _disposed = true;
    // 【FEAT-385】攻撃エフェクト Timer を全 cancel (Pre-mortem race 回避)。
    for (final t in _effectTimers) {
      t.cancel();
    }
    _effectTimers.clear();
    // 【FEAT-404】addListener (_onAtbProgress) を解除してから atb 自体 dispose。
    _atb.removeListener(_onAtbProgress);
    _atb.dispose();
    _state.dispose();
  }
}

/// 【FEAT-302 + FEAT-333】damage 計算結果 + Critical 判定ログを返すための内部 record。
/// FEAT-333 で weak_ult_cost crit + 創造力 critRate の両方が同時発火する可能性が出たため、
/// `criticalLog: String?` → `criticalLogs: List<String>` に拡張 (空 list = crit なし)。
class _DamageResult {
  const _DamageResult({required this.damage, this.criticalLogs = const []});
  final int damage;
  final List<String> criticalLogs;
}

/// 【FEAT-302】攻撃タイプ enum。jobName から判定（_attackTypeOf）。
enum _AttackType { physical, magical }
