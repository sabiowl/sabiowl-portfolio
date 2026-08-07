import 'dart:math';

import '../models/ability.dart';
import '../models/battle_state.dart';
import '../models/tactic.dart';

/// 【FEAT-295 Phase 1a → 2026-07-02 拡張】3 作戦の優先順位ロジック（設計ノート §5.2）。
///
/// `BattleOrchestrator` が「プレイヤーの ATB ゲージが 1.0 に達した瞬間」に呼び出して、
/// 次に発火すべきアビリティを返す。
///
/// 【2026-07-02】必殺技の自動発動 tactic を反転:
///   - Tactic.offense (攻撃重視) → canUltimate なら ultimate 自動発動
///   - Tactic.conserveUltimate (大技温存) → 自動発動なし、手動 queueUltimate のみ
/// 「攻撃重視 = 攻撃全開 (必殺も撃つ)」「大技温存 = 手動で温存」という label 意味への
/// 忠実化。手動発動 (queueUltimate) は Tactic 非依存で動作するため、conserveUltimate
/// でも手動必殺ボタンを押せば発動する (BattleOrchestrator._handlePlayerTurn の queue 経路)。
class TacticResolver {
  TacticResolver({Random? random}) : _random = random ?? Random();

  final Random _random;

  /// 次に発火するアビリティを判定する。
  ///
  /// - `Tactic.offense`: canUltimate → ultimate、それ以外は 50% normal / 50% strong
  /// - `Tactic.recovery`: HP < 30% で heal、< 50% で strong、それ以外 normal
  /// - `Tactic.conserveUltimate`: 常に normal (自動発動なし、手動 queueUltimate のみ)
  ///
  /// 【FEAT-299】`combatant.ultCost` でジョブ駆動の必殺コストを採用。
  /// default 3 = 既存挙動互換（Pre-mortem #5）。
  Ability resolveNextAbility(BattleState state) {
    final tactic = state.tactic;
    final hpPct  = state.player.maxHp == 0
        ? 0.0
        : state.player.currentHp / state.player.maxHp;
    final canUltimate =
        state.chargedSpecialCount >= state.player.ultCost;

    switch (tactic) {
      case Tactic.offense:
        // 【2026-07-02】canUltimate なら ultimate 自動発動、それ以外 50/50 攻撃。
        // 「攻撃重視 = 攻撃全開 (必殺も撃つ)」の意味に忠実化。
        if (canUltimate) return Ability.ultimate;
        return _random.nextBool() ? Ability.normal : Ability.strong;

      case Tactic.recovery:
        if (hpPct < 0.30) return Ability.heal;
        if (hpPct < 0.50) return Ability.strong;
        return Ability.normal;

      case Tactic.conserveUltimate:
        // 【2026-07-02】自動発動なし。canUltimate でも常に normal を返す。
        // ultimate を撃ちたいユーザーは UltimateButton (queueUltimate 経路) を
        // 押す必要がある。手動発動経路は Tactic 非依存で常に有効。
        return Ability.normal;
    }
  }

  /// 「ultimate を解放するために保留すべきか」を返すヘルパー。
  ///
  /// 【2026-07-02】仕様変更に伴い意味を再定義: `Tactic.conserveUltimate` は
  /// **常に** 手動発動待ちで normal を打つ。canUltimate 到達後もユーザーが
  /// 手動ボタンを押すまで撃たないため、「ultimate 保留すべき状態か」を返すのは
  /// 単純に「tactic == conserveUltimate」で決まる。
  ///
  /// 【FEAT-299】`combatant.ultCost` 動的化。default 3 = 既存挙動互換。
  bool shouldReserveForUltimate(BattleState state) {
    return state.tactic == Tactic.conserveUltimate;
  }
}
