/// 【FEAT-298】回復薬の定数定義（設計値クラス）。
///
/// Backend `SHOP_CATALOG['recovery_potion']` と Backend
/// `BattleStartView._MAX_POTIONS_PER_BATTLE` と整合。
///
/// 本クラスは状態を持たない（テスト依存性を避けるため）。
///
/// 【FEAT-489 Phase 2E】`displayName` のみ locale 依存になったため
/// `static const` → `static get` 化し、[ServiceL10n] 経由で解決する。
/// 消費側は `battle_orchestrator` (BuildContext なしの service 層) のみ。
/// **`itemId` は Backend `PlayerItem.item_id` と一致させる key なので不変**。
library;

import '../../../core/l10n/service_l10n.dart';  // 【FEAT-489 Phase 2E】

class RecoveryPotion {
  RecoveryPotion._();

  /// Backend PlayerItem.item_id と一致させる識別子。
  static const String itemId = 'recovery_potion';

  /// 表示名。
  static String get displayName =>
      ServiceL10n.current.battlePotionRecoveryName;

  /// アイコン絵文字（戦闘 UI で 💊 として一貫使用）。
  static const String emoji = '💊';

  /// 戦闘開始前に設定できる使用数の最大値（Backend 側と整合）。
  /// 0〜maxPerBattle の範囲外は Backend で 400 reject される。
  static const int maxPerBattle = 3;

  /// 1 個あたりの回復量比率（maxHp に対する割合）。
  /// 設計ノート §10 + 指示書 §2.3「+HP 50%」を踏襲。
  static const double healRatio = 0.50;

  /// 自動使用発火 HP 閾値（currentHp / maxHp <= 本値で発火）。
  /// 指示書 §2.3「HP 30% 以下で自動的に 1 個ずつ消費」を踏襲。
  static const double autoUseHpThreshold = 0.30;

  /// PlayerItem の最大所持数（Backend 99 と整合）。
  static const int maxStock = 99;

  /// ダイヤ単価（Backend SHOP_CATALOG と整合、UI 表示用）。
  static const int diamondPrice = 30;

  /// `maxHp` を渡すと 1 個使用時の回復量（整数）を返す。
  static int healAmount(int maxHp) => (maxHp * healRatio).toInt();
}


/// 【FEAT-376 (2026-05-29)】上位回復薬の定数定義。
///
/// - HP 全回復（回復量 = maxHp × 1.0）
/// - HP 30% 以下で自動消費、通常回復薬より優先
/// - max_stock=10、💎 60
class RecoveryPotionPlus {
  RecoveryPotionPlus._();

  /// Backend PlayerItem.item_id と一致させる識別子。
  static const String itemId = 'recovery_potion_plus';

  /// 表示名。
  static String get displayName =>
      ServiceL10n.current.battlePotionRecoveryPlusName;

  /// アイコン絵文字。
  static const String emoji = '💊';

  /// 戦闘開始前に設定できる使用数の最大値。
  static const int maxPerBattle = 3;

  /// 1 個あたりの回復量比率（maxHp 全回復）。
  static const double healRatio = 1.0;

  /// 自動使用発火 HP 閾値（通常回復薬と同じ）。
  static const double autoUseHpThreshold = 0.30;

  /// PlayerItem の最大所持数（Backend SHOP_CATALOG と整合）。
  static const int maxStock = 10;

  /// ダイヤ単価。
  static const int diamondPrice = 60;

  /// `maxHp` を渡すと 1 個使用時の回復量（整数）を返す。
  static int healAmount(int maxHp) => (maxHp * healRatio).toInt();
}


/// 【FEAT-376 (2026-05-29)】攻撃の薬の定数定義。
///
/// - 使用ターンの攻撃力 +50%（1 ターン限り）
/// - 各攻撃ターンの先頭で在庫があれば自動消費（HP に関係なく）
/// - max_stock=10、💎 80
class AttackPotion {
  AttackPotion._();

  /// Backend PlayerItem.item_id と一致させる識別子。
  static const String itemId = 'attack_potion';

  /// 表示名。
  static String get displayName => ServiceL10n.current.battlePotionAttackName;

  /// アイコン絵文字。
  static const String emoji = '⚔️';

  /// 戦闘開始前に設定できる使用数の最大値。
  static const int maxPerBattle = 3;

  /// 攻撃力倍率（使用ターンのみ適用）。
  static const double atkMultiplier = 1.5;

  /// PlayerItem の最大所持数。
  static const int maxStock = 10;

  /// ダイヤ単価。
  static const int diamondPrice = 80;
}


/// 【FEAT-432 (2026-06-13)】防御の薬の定数定義。
///
/// - 使用ターンの被ダメージ ÷1.5（1 ターン限り）
/// - 各被ダメージターンの先頭で在庫があれば自動消費（HP に関係なく）
/// - max_stock=10、💎 80 (AttackPotion と完全対称)
class DefensePotion {
  DefensePotion._();

  /// Backend PlayerItem.item_id と一致させる識別子。
  static const String itemId = 'defense_potion';

  /// 表示名。
  static String get displayName => ServiceL10n.current.battlePotionDefenseName;

  /// アイコン絵文字。
  static const String emoji = '🛡️';

  /// 戦闘開始前に設定できる使用数の最大値。
  static const int maxPerBattle = 3;

  /// 被ダメージ軽減用の除数（使用ターンのみ適用、ダメージ ÷ 本値）。
  static const double damageReductionFactor = 1.5;

  /// PlayerItem の最大所持数。
  static const int maxStock = 10;

  /// ダイヤ単価。
  static const int diamondPrice = 80;
}
