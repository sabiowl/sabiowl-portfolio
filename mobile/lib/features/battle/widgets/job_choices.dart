import '../../../l10n/app_localizations.dart';

/// 13 ジョブ定義 (PartyEditDialog / JobSelectionOverlay 閲覧表示用、Backend Job 仕様と整合)。
/// PM 確定値 (migration 0112 + 0128 / 指示書 §2.1)。
///
/// 【FEAT-430 (2026-06-12)】「キャラ = ジョブ」固定化により v1.0 では閲覧専用。
/// 【FEAT-431 (2026-06-13)】`party_edit_dialog.dart` の private `_JobChoice` /
/// `_kJobs` を public 化し本 file へ切り出し (Pre-mortem S2、
/// `JobSelectionOverlay` からも参照するため)。
/// 【FEAT-428 hotfix (2026-06-13)】8 → 13 ジョブに拡張 (5 ジョブ追加:
/// magic_swordsman / bard / necromancer / gunner / alchemist)。
/// FEAT-428 指示書では Backend migration 0128 + Mobile character_asset.dart の
/// 修正のみ明示されており、本 file の kJobs 更新がスコープから漏れていた。
/// 結果、ジョブ一覧モーダルで新 5 ジョブが表示されない + ルナ (gunner) を
/// 設定しても warrior にフォールバックされる挙動になっていた。
/// `atbSpeedModifier` 等の modifier 値は表示ヒントとして保持。
/// Backend 側で Job パラメータを変更した場合は本 `kJobs` も同期更新すること
/// （単一真実値: migration 0112 + 0128 が真実値）。
class JobChoice {
  const JobChoice({
    required this.id,
    required this.name,
    required this.description,
    // 【FEAT-390】楽観 UI / localJob 生成用 modifier 値 (Backend seed 0086 と整合)
    required this.atbSpeedModifier,
    required this.attackPowerModifier,
    required this.onHitEffect,
    required this.ultCost,
  });

  final String id;
  final String name;
  final String description;
  final double atbSpeedModifier;    // 【FEAT-390】Backend seed 0086 と整合 (表示用ヒント)
  final double attackPowerModifier; // 【FEAT-390】
  final String onHitEffect;         // 【FEAT-390】
  final int ultCost;                // 【FEAT-390】

  String localizedName(AppLocalizations l10n) => switch (id) {
    'warrior'         => l10n.battleJobNameWarrior,
    'assassin'        => l10n.battleJobNameAssassin,
    'blue_mage'       => l10n.battleJobNameBlueMage,
    'healer'          => l10n.battleJobNameHealer,
    'knight'          => l10n.battleJobNameKnight,
    'archer'          => l10n.battleJobNameArcher,
    'monk'            => l10n.battleJobNameMonk,
    'dark_mage'       => l10n.battleJobNameDarkMage,
    'magic_swordsman' => l10n.battleJobNameMagicSwordsman,
    'bard'            => l10n.battleJobNameBard,
    'necromancer'     => l10n.battleJobNameNecromancer,
    'gunner'          => l10n.battleJobNameGunner,
    'alchemist'       => l10n.battleJobNameAlchemist,
    'black_mage'      => l10n.battleJobNameBlackMage,
    _                 => name,
  };

  String localizedDescription(AppLocalizations l10n) => switch (id) {
    'warrior'         => l10n.battleJobDescWarrior,
    'assassin'        => l10n.battleJobDescAssassin,
    'blue_mage'       => l10n.battleJobDescBlueMage,
    'healer'          => l10n.battleJobDescHealer,
    'knight'          => l10n.battleJobDescKnight,
    'archer'          => l10n.battleJobDescArcher,
    'monk'            => l10n.battleJobDescMonk,
    'dark_mage'       => l10n.battleJobDescDarkMage,
    'magic_swordsman' => l10n.battleJobDescMagicSwordsman,
    'bard'            => l10n.battleJobDescBard,
    'necromancer'     => l10n.battleJobDescNecromancer,
    'gunner'          => l10n.battleJobDescGunner,
    'alchemist'       => l10n.battleJobDescAlchemist,
    'black_mage'      => l10n.battleJobDescBlackMage,
    _                 => description,
  };
}

/// 【FEAT-391 (2026-05-30)】8 ジョブ定義 (5 → 8 に拡張 + キャラ 1:1 マッピング)。
/// 【FEAT-428 hotfix (2026-06-13)】8 → 13 ジョブに拡張 (5 ジョブ追加)。
/// Backend migration 0112 + 0128 の seed 値と整合させている
/// (単一真実値: migration が真実値)。
const List<JobChoice> kJobs = [
  JobChoice(
    id: 'warrior', name: '戦士',
    description: 'ATB 0.9 倍 / 攻撃力 1.3 倍 / 必殺 2 ストック\nバランス型の王道戦士 (sol)',
    atbSpeedModifier: 0.9, attackPowerModifier: 1.3, onHitEffect: 'none', ultCost: 2,
  ),
  JobChoice(
    id: 'assassin', name: 'アサシン',
    description: 'ATB 1.4 倍 (高速) / 攻撃力 1.0 倍 / 必殺 3 ストック\n高速行動 + 必殺多用 (aria)',
    atbSpeedModifier: 1.4, attackPowerModifier: 1.0, onHitEffect: 'none', ultCost: 3,
  ),
  JobChoice(
    id: 'blue_mage', name: '青魔導士',
    description: 'ATB 1.0 倍 / 攻撃力 1.1 倍 + 炎 / 必殺 2 ストック\n安定魔法アタッカー (cyan)',
    atbSpeedModifier: 1.0, attackPowerModifier: 1.1, onHitEffect: 'burn', ultCost: 2,
  ),
  JobChoice(
    id: 'healer', name: '白魔導士',
    description: 'ATB 1.0 倍 / 攻撃力 0.6 倍 + HP 吸収 / 必殺 3 ストック\n回復特化 (lucia)',
    atbSpeedModifier: 1.0, attackPowerModifier: 0.6, onHitEffect: 'heal', ultCost: 3,
  ),
  JobChoice(
    id: 'knight', name: 'ナイト',
    description: 'ATB 0.7 倍 (重装) / 攻撃力 1.1 倍 / 必殺 2 ストック\n堅実な重装前衛 (beatrix)',
    atbSpeedModifier: 0.7, attackPowerModifier: 1.1, onHitEffect: 'none', ultCost: 2,
  ),
  JobChoice(
    id: 'archer', name: 'アーチャー',
    description: 'ATB 1.2 倍 / 攻撃力 1.0 倍 / 必殺 3 ストック\n中速 + 中火力の安定型 (faye)',
    atbSpeedModifier: 1.2, attackPowerModifier: 1.0, onHitEffect: 'none', ultCost: 3,
  ),
  JobChoice(
    id: 'monk', name: 'モンク',
    description: 'ATB 1.3 倍 (高速) / 攻撃力 0.9 倍 / 必殺 4 ストック\n高速連撃型 (zenon)',
    atbSpeedModifier: 1.3, attackPowerModifier: 0.9, onHitEffect: 'none', ultCost: 4,
  ),
  JobChoice(
    id: 'dark_mage', name: '闇魔導士',
    description: 'ATB 0.8 倍 / 攻撃力 1.5 倍 + 炎 / 必殺 1 ストック\n一撃高火力 + 即発動 (noir)',
    atbSpeedModifier: 0.8, attackPowerModifier: 1.5, onHitEffect: 'burn', ultCost: 1,
  ),
  // 【FEAT-428 hotfix (2026-06-13)】新 5 ジョブ (migration 0128 seed 値と整合)
  JobChoice(
    id: 'magic_swordsman', name: '魔法剣士',
    description: 'ATB 1.0 倍 / 攻撃力 1.25 倍 + 炎 / 必殺 3 ストック\n物理魔法ハイブリッド (kyle)',
    atbSpeedModifier: 1.0, attackPowerModifier: 1.25, onHitEffect: 'burn', ultCost: 3,
  ),
  JobChoice(
    id: 'bard', name: '吟遊詩人',
    description: 'ATB 1.2 倍 / 攻撃力 0.7 倍 + HP 吸収 / 必殺 3 ストック\n高速 + 回復支援 (fia)',
    atbSpeedModifier: 1.2, attackPowerModifier: 0.7, onHitEffect: 'heal', ultCost: 3,
  ),
  JobChoice(
    id: 'necromancer', name: 'ネクロマンサー',
    description: 'ATB 0.8 倍 / 攻撃力 1.4 倍 + 炎 / 必殺 4 ストック\n重撃 + 闇魔法 (irene)',
    atbSpeedModifier: 0.8, attackPowerModifier: 1.4, onHitEffect: 'burn', ultCost: 4,
  ),
  JobChoice(
    id: 'gunner', name: 'ガンナー',
    description: 'ATB 1.3 倍 (高速) / 攻撃力 1.1 倍 / 必殺 2 ストック\n高速射手 + 必殺多用 (luna)',
    atbSpeedModifier: 1.3, attackPowerModifier: 1.1, onHitEffect: 'none', ultCost: 2,
  ),
  JobChoice(
    id: 'alchemist', name: '錬金術師',
    description: 'ATB 0.9 倍 / 攻撃力 0.8 倍 + HP 吸収 / 必殺 4 ストック\n回復特化 + 重必殺 (aurum)',
    atbSpeedModifier: 0.9, attackPowerModifier: 0.8, onHitEffect: 'heal', ultCost: 4,
  ),
  // 【BUG-104 (2026-06-14)】新ジョブ「黒魔導士」追加 (migration 0138 seed 値と整合、rune 専用)
  JobChoice(
    id: 'black_mage', name: '黒魔導士',
    description: 'ATB 0.9 倍 / 攻撃力 1.4 倍 + 炎 / 必殺 2 ストック\n炎と雷を操る攻撃魔導士 (rune)',
    atbSpeedModifier: 0.9, attackPowerModifier: 1.4, onHitEffect: 'burn', ultCost: 2,
  ),
];
