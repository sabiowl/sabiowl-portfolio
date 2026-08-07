/// 【FEAT-295 Phase 1a】4 アビリティ定義（MVP ハードコード、設計ノート §5.1）。
///
/// SP/JP/ジョブ解禁は Phase 2 で導入予定（MVP では全アビリティ常時使用可能）。
library;

import '../../../core/l10n/service_l10n.dart';  // 【FEAT-489 Phase 2E】

enum Ability {
  /// 通常攻撃: ATK × 1.0、待機 1.0s。コストなし。
  normal,

  /// 強攻撃: ATK × 1.8、待機 2.0s。コストなし。
  strong,

  /// 回復: HP +25%（上限 maxHp）、待機 1.5s。コストなし。
  heal,

  /// 大技: ATK × 3.0、待機 2.5s。コスト「ゲージ満タン保留 3 回」。
  ultimate;
}

/// アビリティの数式・効果定義（lookup table）。
class AbilityDef {
  const AbilityDef({
    required this.ability,
    required this.atkMultiplier,
    required this.healPercent,
    required this.castDurationMs,
  });

  final Ability ability;

  /// ATK 倍率（攻撃系のみ意味、heal では 0）。
  final double atkMultiplier;

  /// 回復割合（heal のみ意味、攻撃系では 0）。
  final double healPercent;

  /// 詠唱時間（演出 + tick 進行に使う）。
  final int castDurationMs;

  /// ログ表示用ラベル。
  ///
  /// 【FEAT-489 Phase 2E】locale 依存になったため const map の field から外し、
  /// 参照時に解決する getter に変更した。本 def を読む `battle_orchestrator` は
  /// BuildContext を持たない service 層なので、Phase 2D で新設した [ServiceL10n]
  /// を経由する (Phase 2D `notification_service` と同じ設計)。
  String get label => switch (ability) {
        Ability.normal => ServiceL10n.current.battleAbilityNormalLabel,
        Ability.strong => ServiceL10n.current.battleAbilityStrongLabel,
        Ability.heal => ServiceL10n.current.battleAbilityHealLabel,
        Ability.ultimate => ServiceL10n.current.battleAbilityUltimateLabel,
      };
}

const Map<Ability, AbilityDef> kAbilityDefs = {
  Ability.normal: AbilityDef(
    ability:        Ability.normal,
    atkMultiplier:  1.0,
    healPercent:    0.0,
    castDurationMs: 1000,
  ),
  Ability.strong: AbilityDef(
    ability:        Ability.strong,
    atkMultiplier:  1.8,
    healPercent:    0.0,
    castDurationMs: 2000,
  ),
  Ability.heal: AbilityDef(
    ability:        Ability.heal,
    atkMultiplier:  0.0,
    healPercent:    0.25,
    castDurationMs: 1500,
  ),
  Ability.ultimate: AbilityDef(
    ability:        Ability.ultimate,
    atkMultiplier:  3.0,
    healPercent:    0.0,
    castDurationMs: 2500,
  ),
};
