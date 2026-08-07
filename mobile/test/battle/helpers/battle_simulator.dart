// 【FEAT-371】FEAT-333 stat 連動 × FEAT-332 Enemy balance の境界バランステスト用
// バトルシミュレーター。
//
// 既存 `BattleOrchestrator` は `Timer.periodic` 駆動で実時間進行するため、
// `await Future.delayed(2400ms)` で限られた turn しか観測できない (`stat_battle_link_test.dart`
// が 2-3 turn 程度の窓で「効果が動作するか」を縛る設計)。
// 一方 FEAT-371 は「Lv5 で 3-4 turn / Lv10 で 5-7 turn 勝利」のように
// **戦闘完了まで** の turn 数を縛る必要がある = 20-40 秒の wallclock を 3 シナリオ走らせると
// 60-120 秒の test latency になり flutter test の 30 秒既定タイムアウトを超過する。
//
// 解決: tick を数学的に進める純粋シミュレーター (Random seed 固定で完全 deterministic)。
//
// 設計方針:
//   1. 既存 `Combatant` / `Ability` / `BattleConstants` の値定義を 1:1 で参照
//      (重複定義を避け、本体側で coefficient を変えたら自動追従)
//   2. ATB ゲージ充填は `(1.0 - gauge) / fillPerTick` で次行動までの tick 数を算出
//      → 早く 1.0 到達する側が action → 相手のゲージは比例進行
//   3. ダメージ式は `BattleOrchestrator._applyAbility` + `_applyResistance` と同形:
//      `atk × ability.multiplier × (1 - target.damageReduction)` + crit ×1.5
//      物理/魔法 resistance は default 1.0 で省略 (FEAT-371 は player vs zako のみ、
//      jobName 駆動の弱点判定不要)
//   4. Tactic は `Tactic.offense` 固定 (50% normal / 50% strong)
//      → heal / ultimate 分散を排除して境界 turn 数を安定化
//   5. FEAT-333 stat 連動 6 軸を `_buildPlayer` で `battle_provider.dart:533-577` と同式適用
//
// 制約 (intentional):
//   - 大技 (Ability.ultimate) は除外: Tactic.offense では発火しないため境界テスト無関係
//   - heal (Ability.heal) も除外: Tactic.offense では発火しない
//   - on_hit_effect (burn / heal) は除外: v1.0 player は warrior 経路で発火しない (job=None
//     扱いで default 'none')
//   - weak_ult_cost crit は除外: enemy 側 default null、player 攻撃時の判定なし
//
// 想定する追加敵: `_kEnemyCatalog` に現行 DB と同期した値を保持。
// migration を変更したら本表も更新する (Pre-mortem: 二重管理リスク、Phase 4 で確認)。
//
// 【FEAT-522 (2026-08-07) 修正】本ファイルは **旧 HP 式のまま放置されていた**。
//   - HP を `baseHp * levelScaling * level` で計算していた
//     (FEAT-400 v3、2026-05-31 で `scaled_hp = base_hp` の固定式に変わっている)
//   - 参照先コメントの `views/battle.py:177-178` は存在しないパス
//   - カタログ値が migration 0099 時点 (goblin hp=60 / young_orc hp=40) のまま
//
// それでも誤判定が起きていなかったのは **偶然**である。
// `goblin 60 × 0.5 × 5 = 150` が production の固定値 150 と一致し、
// young_orc も `40 × 0.5 × 10 = 200` = production 200 だった。
// FEAT-400 v3 が「unlock 時の難度を据え置いて固定化した」結果の一致にすぎず、
// テスト Lv を変えるか ATK 式を変えた瞬間に崩れる。本 FEAT の ATK 式変更で
// 実際に崩れるため、ここで現行式とカタログ値に揃える。

import 'dart:math';

import 'package:sabiowl/features/battle/constants/battle_constants.dart';

/// CharacterStat 6 軸の Lv (0-N)。`simulateBattle` に渡してプレイヤー Combatant を構築。
///
/// FEAT-333 連動式 (battle_provider.dart:552-557 と同じ順序):
///   - 運動力 → maxHp += lv × 5
///   - 学習力 → atk    += lv × 1
///   - 健康力 → hpRegenPerTurn = lv × 2
///   - 精神力 → atbSpeedModifier += lv × 0.01
///   - 創造力 → critRate = lv × 0.005
///   - 貢献力 → damageReduction = lv × 0.005
class StatLevels {
  const StatLevels({
    this.athleticLv = 0,
    this.studyLv = 0,
    this.healthLv = 0,
    this.mentalLv = 0,
    this.creativityLv = 0,
    this.contributionLv = 0,
  });

  /// 全 stat Lv 0 (FEAT-371 シナリオ 1: 新規ユーザー / 習慣未達想定)。
  const StatLevels.allZero()
      : athleticLv = 0,
        studyLv = 0,
        healthLv = 0,
        mentalLv = 0,
        creativityLv = 0,
        contributionLv = 0;

  /// 全 stat 同一 Lv (FEAT-371 シナリオ 2/3: 順調にステ上げたユーザー想定)。
  const StatLevels.allLevel(int lv)
      : athleticLv = lv,
        studyLv = lv,
        healthLv = lv,
        mentalLv = lv,
        creativityLv = lv,
        contributionLv = lv;

  final int athleticLv;
  final int studyLv;
  final int healthLv;
  final int mentalLv;
  final int creativityLv;
  final int contributionLv;
}

/// シミュレーション結果。
class BattleResult {
  const BattleResult({
    required this.winnerIsPlayer,
    required this.turns,
    required this.playerActions,
    required this.enemyActions,
    required this.playerFinalHp,
    required this.playerMaxHp,
    required this.enemyFinalHp,
  });

  /// 勝者が player なら true。`maxTurns` 到達による打ち切りや敵勝利は false。
  final bool winnerIsPlayer;

  /// 総 turn 数 = state.rounds 互換 (player + enemy 行動の合計)。
  /// FEAT-371 instruction の "5-7 turn" / "3-4 turn" 等の数値はこちらを採用。
  final int turns;

  /// player 行動回数 (内訳デバッグ用)。
  final int playerActions;

  /// enemy 行動回数 (内訳デバッグ用)。
  final int enemyActions;

  final int playerFinalHp;
  final int playerMaxHp;
  final int enemyFinalHp;

  /// 戦闘終了時の player HP 残率 (0.0-1.0)。「ギリギリ倒せる」目安 = 0.3-0.5 範囲。
  double get playerHpRatio =>
      playerMaxHp == 0 ? 0.0 : playerFinalHp / playerMaxHp;
}

/// 現行 DB と同期した敵パラメータ表。
/// 値変更時は backend 側の migration (最新は 0201_feat522_enemy_atk_flat_damage) も
/// 併せて更新する。
class _EnemySpec {
  const _EnemySpec({
    required this.key,
    required this.baseHp,
    required this.baseAtk,
    required this.baseSpd,
    required this.levelScaling,
    required this.unlockLevel,
  });

  final String key;
  final int baseHp;
  final int baseAtk;
  final int baseSpd;

  /// 【FEAT-522】0 = 固定。0 超なら unlock_level 以降だけ緩やかに追随する。
  final double levelScaling;

  /// 【FEAT-522】ATK 追随の基点。`levelScaling` が 0 なら結果に影響しない。
  final int unlockLevel;
}

/// FEAT-371 で参照する敵カタログ。境界テスト対象 (goblin / young_orc) のみ。
///
/// 【FEAT-522 (2026-08-07)】migration 0099 時点の値から **現行 DB に同期**した:
///   goblin    : hp 60 → 150 (FEAT-400 v3)、atk 8 → 5  (FEAT-522)
///   young_orc : hp 40 → 200 (FEAT-400 v3)、atk 8 → 20 (FEAT-522)
/// 旧値でも「× scaling × level」を掛けると偶然同じ HP になっていたが、
/// ATK 式の変更でその偶然は成立しなくなった。
const _kEnemyCatalog = <String, _EnemySpec>{
  'goblin': _EnemySpec(
    key: 'goblin',
    baseHp: 150,
    baseAtk: 5,
    baseSpd: 10,
    levelScaling: 0.0,
    unlockLevel: 5,
  ),
  'young_orc': _EnemySpec(
    key: 'young_orc',
    baseHp: 200,
    baseAtk: 20,
    baseSpd: 6,
    levelScaling: 0.0,
    unlockLevel: 10,
  ),
};

class _SimCombatant {
  _SimCombatant({
    required this.name,
    required this.maxHp,
    required this.atk,
    required this.spd,
    this.atbSpeedModifier = 1.0,
    this.hpRegenPerTurn = 0,
    this.critRate = 0.0,
    this.damageReduction = 0.0,
  })  : currentHp = maxHp,
        atbGauge = 0.0;

  final String name;
  final int maxHp;
  int currentHp;
  final int atk;
  final int spd;
  final double atbSpeedModifier;
  final int hpRegenPerTurn;
  final double critRate;
  final double damageReduction;
  double atbGauge;

  bool get isAlive => currentHp > 0;

  /// 1 tick あたりのゲージ充填量 (= `spd × atbSpeedModifier / tickRate`)。
  double get fillPerTick =>
      spd * atbSpeedModifier / BattleConstants.tickRate;
}

_SimCombatant _buildPlayer(int playerLevel, StatLevels stats) {
  // battle_provider.dart:528-531 と同式:
  //   weaponAtk = player.equippedWeapon?.atkBonus ?? 10  (FEAT-326)
  //   baseAtk   = 10 + player.level * 2 + weaponAtk
  //   baseMaxHp = playerBaseHp + player.level * playerHpPerLevel
  // FEAT-371 では starter_sword (+10) 装備想定で固定。
  final baseAtk = 10 + playerLevel * 2 + 10;
  final baseMaxHp = BattleConstants.playerBaseHp +
      playerLevel * BattleConstants.playerHpPerLevel;

  return _SimCombatant(
    name: 'プレイヤー',
    // FEAT-333: 6 軸 stat 連動を battle_provider.dart:563-576 と同係数で適用
    maxHp: baseMaxHp + (stats.athleticLv * 5),
    atk: baseAtk + (stats.studyLv * 1),
    spd: 10, // MVP 固定 (battle_provider.dart:566)
    atbSpeedModifier: 1.0 + (stats.mentalLv * 0.01),
    hpRegenPerTurn: stats.healthLv * 2,
    critRate: stats.creativityLv * 0.005,
    damageReduction: stats.contributionLv * 0.005,
  );
}

_SimCombatant _buildEnemy(String enemyKey, int playerLevel) {
  final spec = _kEnemyCatalog[enemyKey];
  if (spec == null) {
    throw ArgumentError(
      'Unknown enemy key: $enemyKey. '
      'Add to _kEnemyCatalog in battle_simulator.dart (sync with migration 0099).',
    );
  }
  // Backend `BattleStartView` (views/battle/start.py `scaled_hp` / `scaled_atk`) と同式:
  //   scaled_hp  = enemy.base_hp                                   (FEAT-400 v3、Lv 非連動)
  //   scaled_atk = int(base_atk * (1 + level_scaling
  //                                * max(0, level - unlock_level))) (FEAT-522)
  final scaledHp = spec.baseHp;
  final scaledAtk = (spec.baseAtk *
          (1 + spec.levelScaling * max(0, playerLevel - spec.unlockLevel)))
      .toInt();
  return _SimCombatant(
    name: spec.key,
    maxHp: scaledHp,
    atk: scaledAtk,
    spd: spec.baseSpd,
  );
}

/// FEAT-371 境界バランステスト用のバトルシミュレーター。
///
/// 既存 `BattleOrchestrator` の Timer.periodic 駆動を tick 単位の数学的進行に置き換えた
/// deterministic 版。同一 [seed] なら同一結果を返す。
///
/// アビリティ選択は `Tactic.offense` 固定 (50% normal / 50% strong)。
/// 大技 / heal は確率分散が大きく境界テスト不向きなので除外。
///
/// 計算手順 (1 round):
///   1. player / enemy 双方の「残ゲージ ÷ 1 tick あたり充填」で次行動までの tick 数を計算
///   2. 小さい方が先に行動 (= 早く 1.0 到達)
///   3. 行動した側のゲージを 0 に、相手のゲージを比例進行で増分
///   4. ダメージ計算 (atk × multiplier × crit × dmgRed)
///   5. player が攻撃終了したら hpRegenPerTurn 反映 (健康力連動)
///   6. rounds += 1、勝敗判定
///
/// [maxTurns] は無限ループ防止用 (default 200 = 通常戦闘の 10 倍程度)。
BattleResult simulateBattle({
  required int playerLevel,
  required StatLevels statLevels,
  required String enemyKey,
  int seed = 42,
  int maxTurns = 200,
}) {
  final random = Random(seed);
  final player = _buildPlayer(playerLevel, statLevels);
  final enemy = _buildEnemy(enemyKey, playerLevel);

  int rounds = 0;
  int playerActions = 0;
  int enemyActions = 0;

  while (player.isAlive && enemy.isAlive && rounds < maxTurns) {
    final ticksToPlayer = (1.0 - player.atbGauge) / player.fillPerTick;
    final ticksToEnemy = (1.0 - enemy.atbGauge) / enemy.fillPerTick;

    if (ticksToPlayer <= ticksToEnemy) {
      // Player acts
      enemy.atbGauge =
          (enemy.atbGauge + ticksToPlayer * enemy.fillPerTick).clamp(0.0, 1.0);
      player.atbGauge = 0.0;
      _resolvePlayerAttack(player, enemy, random);
      playerActions++;
    } else {
      // Enemy acts
      player.atbGauge =
          (player.atbGauge + ticksToEnemy * player.fillPerTick).clamp(0.0, 1.0);
      enemy.atbGauge = 0.0;
      _resolveEnemyAttack(enemy, player, random);
      enemyActions++;
    }
    rounds++;
  }

  return BattleResult(
    winnerIsPlayer: enemy.currentHp <= 0 && player.currentHp > 0,
    turns: rounds,
    playerActions: playerActions,
    enemyActions: enemyActions,
    playerFinalHp: player.currentHp,
    playerMaxHp: player.maxHp,
    enemyFinalHp: enemy.currentHp,
  );
}

/// Tactic.offense: 50% normal (×1.0) / 50% strong (×1.8) で攻撃。
/// 攻撃後に hpRegenPerTurn を attacker 自身に適用 (健康力連動)。
void _resolvePlayerAttack(
    _SimCombatant player, _SimCombatant enemy, Random random) {
  // tactic_resolver.dart:38-39 の `_random.nextBool() ? Ability.normal : Ability.strong`
  // と同条件分岐 (FEAT-371 では強攻撃倍率 1.8 を使用)。
  final isStrong = random.nextBool();
  final multiplier = isStrong ? 1.8 : 1.0;
  _applyDamage(player, enemy, multiplier, random);

  // FEAT-333 健康力連動: 攻撃 turn 終了時に attacker の HP を自然回復
  // (battle_orchestrator.dart:370-380 と同形)
  if (player.hpRegenPerTurn > 0 && player.isAlive) {
    player.currentHp =
        (player.currentHp + player.hpRegenPerTurn).clamp(0, player.maxHp);
  }
}

/// 敵は常に通常攻撃 (×1.0) のみ。FEAT-371 では敵 stat 連動なし。
void _resolveEnemyAttack(
    _SimCombatant enemy, _SimCombatant player, Random random) {
  _applyDamage(enemy, player, 1.0, random);
}

/// ダメージ計算 (battle_orchestrator.dart:_applyResistance と同形):
///   1. 基礎 dmg = atk × multiplier
///   2. FEAT-333 創造力連動: random < critRate なら ×1.5
///   3. FEAT-333 貢献力連動: target.damageReduction で ×(1 - dmgRed)
///   4. clamp(1, 9999) で最小ダメージ 1 保証
void _applyDamage(_SimCombatant attacker, _SimCombatant target,
    double multiplier, Random random) {
  double damage = attacker.atk * multiplier;
  if (attacker.critRate > 0.0 && random.nextDouble() < attacker.critRate) {
    damage *= 1.5;
  }
  if (target.damageReduction > 0.0) {
    damage *= (1.0 - target.damageReduction);
  }
  final dmg = damage.round().clamp(1, 9999);
  target.currentHp = (target.currentHp - dmg).clamp(0, target.maxHp);
}
