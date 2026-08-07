/// 【FEAT-295 Phase 1a / FEAT-299 Phase 2】キャラ + 敵共通の戦闘単位（mutable）。
///
/// 設計ノート §4.2。
///
/// freezed を使わない理由: ATB ゲージ・HP は tick 単位で頻繁に変動するため、
/// immutable + copyWith ではアロケーションが多すぎる。mutable + ChangeNotifier
/// の `AtbController` が変更通知を担う設計。
///
/// 【FEAT-299】ジョブ駆動設計の修飾子をフィールドとして抱える。default 値で
/// 既存挙動と完全同等（Pre-mortem #1 / #5 退行回避）。Backend `player_job` から
/// `_buildPlayerCombatant` が反映する。
class Combatant {
  Combatant({
    required this.id,
    required this.name,
    required this.spriteKey,
    required this.maxHp,
    required this.currentHp,
    required this.atk,
    required this.spd,
    this.atbGauge = 0.0,
    // 【FEAT-299】default 値は既存挙動互換（modifier 1.0 / on_hit none / ult_cost 3）。
    this.atbSpeedModifier = 1.0,
    this.attackPowerModifier = 1.0,
    this.onHitEffect = 'none',
    this.ultCost = 3,
    this.jobName = '',
    // 【FEAT-302】弱点 / 耐性。default 値 = 既存挙動互換（Pre-mortem #5 退行回避）。
    this.physicalResistance = 1.0,
    this.magicalResistance = 1.0,
    this.weakUltCost,
    // 【FEAT-333 (2026-05-27)】CharacterStat 6 軸 → バトル能力 1 対 1 連動。
    // default 値 0 で既存挙動互換 (Pre-mortem #1 退行回避)、PlayerProfile から
    // `_buildPlayerCombatant` で 6 ステ別連動式を適用して上書き。敵 / Sabi
    // フォールバックでは default 0 のまま、ステ効果なしで戦闘進行。
    this.hpRegenPerTurn = 0,
    this.critRate = 0.0,
    this.damageReduction = 0.0,
  });

  /// 識別子: 'player' or 'enemy_goblin' 等。
  final String id;

  /// 表示名: '勇者' or 'ゴブリン' 等。
  final String name;

  /// スプライト asset key（`assets/images/battle/<key>.webp`）。
  final String spriteKey;

  /// 最大 HP。バトル開始時に決定、以後不変。
  final int maxHp;

  /// 現在 HP。tick で減少 / heal で増加。
  int currentHp;

  /// 物理攻撃力（武器ボーナス込み）。
  final int atk;

  /// ATB 充填速度（1 tick あたり `spd / tickRate` ゲージ加算）。
  final int spd;

  /// 0.0 〜 1.0、1.0 で行動可能。
  double atbGauge;

  /// 【FEAT-299】ATB 充填速度倍率（ジョブ駆動）。AtbController._onTick で適用。
  /// default 1.0 = 既存挙動互換。
  final double atbSpeedModifier;

  /// 【FEAT-299】攻撃力倍率（ジョブ駆動）。BattleOrchestrator._applyAbility で適用。
  /// default 1.0 = 既存挙動互換。
  final double attackPowerModifier;

  /// 【FEAT-299】攻撃時の追加効果。`'none'` / `'burn'` / `'heal'`。
  /// - `burn`: 敵 HP に `max_hp × 0.02 × 3` を即時加算（DoT 風、Pre-mortem #3 で簡略化）
  /// - `heal`: 自分の HP を `damage_dealt × 0.10` 回復（吸収）
  /// default 'none' = 既存挙動互換。
  final String onHitEffect;

  /// 【FEAT-299】大技解放に必要なゲージ満タン保留回数。
  /// 既存 `BattleConstants.ultimateChargeRequired` 定数の動的化版。
  /// default 3 = 既存挙動互換（Pre-mortem #5）。
  final int ultCost;

  /// 【FEAT-299】ジョブ表示名（UI 用、例: '戦士', '魔導士'）。
  /// 空文字なら非表示（敵 / Sabi フォールバック時等）。
  final String jobName;

  /// 【FEAT-302】物理攻撃ダメージ倍率（被ダメ時に適用）。1.0=等倍 / 0.7=30%軽減。
  /// 攻撃側の `jobName` が warrior/berserker/thief のとき適用。
  final double physicalResistance;

  /// 【FEAT-302】魔法効果倍率（burn/heal の効果に適用）。default 1.0。
  /// 攻撃側の `jobName` が mage/cleric のとき適用。
  final double magicalResistance;

  /// 【FEAT-302】弱点 ult_cost。攻撃側 `ultCost` が一致すると Critical (+30%)。
  /// null = 弱点なし。例: ice_witch.weakUltCost=4 → thief (ultCost=4) で Critical。
  final int? weakUltCost;

  /// 【FEAT-333】健康力連動の毎 turn HP 自動回復量 (上限 maxHp)。
  /// 連動式: hpRegenPerTurn = 健康力.level × 2 (Lv 5 で +10 HP/turn)。
  /// default 0 = 既存挙動互換 (敵 / Sabi フォールバック時)。
  final int hpRegenPerTurn;

  /// 【FEAT-333】創造力連動のクリティカル率 (0.0-1.0)。
  /// 連動式: critRate = 創造力.level × 0.005 (Lv 5 で 2.5%)。
  /// 攻撃時に random < critRate で発動、damage × 1.5 (Pre-mortem 簡略化)。
  /// default 0.0 = 既存挙動互換。
  final double critRate;

  /// 【FEAT-333】貢献力連動の被ダメージ軽減率 (0.0-1.0)。
  /// 連動式: damageReduction = 貢献力.level × 0.005 (Lv 5 で 2.5% 軽減)。
  /// 受けるダメージ × (1 - damageReduction) を適用。
  /// default 0.0 = 既存挙動互換。
  final double damageReduction;

  bool get isAlive => currentHp > 0;
}
