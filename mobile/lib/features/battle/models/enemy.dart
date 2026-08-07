/// 【FEAT-296 Phase 2-3】Enemy マスタ（Backend `Enemy` モデルの Flutter 表現）。
///
/// `GET /api/battle/enemies/` で取得した一覧を `EnemyListProvider` で保持し、
/// ギルド画面（`guild_page.dart`）の `_BossQuestList` で表示する。
///
/// 戦闘開始時は `EnemyMaster.key` を `BattleService.startBattle(enemyKey: ...)` に
/// 渡し、Backend がマスタから完全パラメータ（scaling × level 適用済 HP/ATK）を
/// 返却する設計。Flutter 側は `EnemyMaster` の表示用メタデータのみ保持。
class EnemyMaster {
  const EnemyMaster({
    required this.key,
    required this.name,
    required this.spriteKey,
    required this.baseHp,
    required this.baseAtk,
    required this.baseSpd,
    required this.levelScaling,
    required this.rewardCoins,
    required this.rewardExp,
    required this.tier,
    this.physicalResistance = 1.0,
    this.magicalResistance = 1.0,
    this.weakUltCost,
    this.unlockLevel = 0,
    this.backgroundImagePath = '',
    this.defeated = false,
  });

  /// 識別子: 'goblin' / 'giant_slime' / 'goblin_king' / 'dragon' / 'shadow_mage' /
  /// 【FEAT-302】'armored_knight' / 'ice_witch' / 'void_dragon'。
  final String key;

  /// 表示名: '巨大スライム' 等。
  final String name;

  /// スプライト asset key（`assets/images/battle/<spriteKey>.webp`）。
  final String spriteKey;

  /// 戦闘中 HP。**そのまま**使われ、player.level では増えない。
  ///
  /// 【FEAT-400 v3 (2026-05-31)】旧コメント「player.level × levelScaling で実 HP が
  /// 決まる」は同 FEAT で `scaled_hp = base_hp` の固定式に変わった時点で古くなっていた。
  final int baseHp;

  /// 1 発のダメージそのもの (設定値 = 実ダメージ)。
  ///
  /// 【FEAT-522 (2026-08-07)】旧式 `base_atk × level_scaling × player.level` を廃止。
  /// admin に入れた数字がそのまま実ダメージになる。
  final int baseAtk;

  /// ATB 充填速度。player.level では変わらない。
  final int baseSpd;

  /// 【FEAT-522】ATK の追随係数。**0 = 固定** (全 24 体の既定)。
  ///
  /// 0 より大きい値は `unlock_level` 以降だけ緩やかに追随する:
  ///   `scaled_atk = base_atk × (1 + levelScaling × max(0, level - unlockLevel))`
  /// 旧コメント「player.level に乗じるスケーリング倍率 (1.0 = 等倍、2.5 = ドラゴン級)」
  /// は FEAT-400 v3 の 0.5 統一時点で既に古く、本 FEAT で意味自体が変わった。
  final double levelScaling;

  /// 勝利報酬コイン。
  final int rewardCoins;

  /// 勝利報酬 EXP。
  final int rewardExp;

  /// 【FEAT-302】tier 拡張: 'zako' / 'mid_boss' / 'boss' / 'hidden_boss'。
  /// ギルド画面の表示分類 + 段階解放の見出しに使用。
  final String tier;

  /// 【FEAT-302】物理攻撃 (warrior/berserker/thief = jobName 駆動) のダメージ倍率。
  /// 1.0 = 等倍、0.7 = 30% 軽減、1.3 = 30% 増幅。default 1.0 = 既存挙動互換（Pre-mortem #5）。
  final double physicalResistance;

  /// 【FEAT-302】魔法攻撃 (mage burn / cleric heal) の効果倍率。default 1.0 互換。
  final double magicalResistance;

  /// 【FEAT-302】指定 ult_cost のジョブから受けるダメージが +30% (Critical)。
  /// null = 弱点なし。例: ice_witch.weakUltCost=4 → thief (ultCost=4) 限定。
  final int? weakUltCost;

  /// 【FEAT-302】解禁プレイヤーレベル (0=常時 / 15=mid_boss / 25=boss / 35=hidden_boss)。
  /// Flutter ギルド画面が player.level < unlockLevel なら 🔒 表示で disabled。
  final int unlockLevel;

  /// 【FEAT-381 (2026-05-29)】戦闘画面の背景画像 asset path。
  /// tier 別汎用 (zako/mid_boss/boss/hidden_boss) or Enemy 個別 override。
  /// 空文字 '' = 背景画像なし (battle_page.dart で AppTheme.background 単色フォールバック)。
  /// 例: 'assets/images/backgrounds/battle/bg_zako.webp'
  /// 画像欠落時は Flutter `Image.asset.errorBuilder` で安全に単色フォールバック。
  final String backgroundImagePath;

  /// 【FEAT-439 (2026-06-17)】プレイヤーが一度でも勝利した敵か。
  /// ギルド画面で弱点/耐性 chip 表示の判定に使用 (未勝利時は隠す、勝利後に表示)。
  /// Backend `Battle.result='win'` 履歴の存在から計算 (EnemyListView)。
  /// HP ゲージは勝利後も非表示 (「強さ未知数」の体験維持、PM 判断 BUG-138 系)。
  /// 古い Backend と通信時は default false (= 全敵未勝利扱い、安全側)。
  final bool defeated;

  bool get isBoss => tier == 'boss';

  /// 【FEAT-302】中ボス（Lv.15 解禁）判定（UI 表示色分け用）。
  bool get isMidBoss => tier == 'mid_boss';

  /// 【FEAT-302】隠しボス（Lv.35 解禁）判定（UI 表示色分け用）。
  bool get isHiddenBoss => tier == 'hidden_boss';

  /// 【FEAT-302】「物理耐性あり」判定（< 1.0 で軽減 / > 1.0 で増幅）。
  /// 警告 UI（battle_pre_start_sheet）の表示判定に使う。
  bool get hasPhysicalResistance => physicalResistance < 1.0;
  bool get hasMagicalResistance => magicalResistance < 1.0;
  bool get hasWeakness => weakUltCost != null;

  factory EnemyMaster.fromJson(Map<String, dynamic> json) {
    return EnemyMaster(
      key:          json['key']        as String,
      name:         json['name']       as String,
      spriteKey:    json['sprite_key'] as String,
      baseHp:       json['base_hp']    as int? ?? 0,
      baseAtk:      json['base_atk']   as int? ?? 0,
      baseSpd:      json['base_spd']   as int? ?? 0,
      // 【FEAT-522】既定を 1.0 → 0.0 に。0 = 固定が全 24 体の既定なので、
      // 欠落時に 1.0 (= 解禁 +1 Lv ごとに 2 倍) へ倒すのは危険側のフォールバック。
      // なお本フィールドはアプリ内の計算には使われていない (表示・デバッグ用)。
      // 実 ATK は BattleStartResponse の `enemy.atk` を Backend がそのまま返す。
      levelScaling: (json['level_scaling'] as num?)?.toDouble() ?? 0.0,
      rewardCoins:  json['reward_coins'] as int? ?? 0,
      rewardExp:    json['reward_exp']   as int? ?? 0,
      tier:         json['tier']       as String? ?? 'zako',
      // 【FEAT-302】null 安全（古い Backend と通信した場合の Pre-mortem #5 退行回避）。
      physicalResistance:
          (json['physical_resistance'] as num?)?.toDouble() ?? 1.0,
      magicalResistance:
          (json['magical_resistance']  as num?)?.toDouble() ?? 1.0,
      weakUltCost:  json['weak_ult_cost'] as int?,
      unlockLevel:  json['unlock_level']  as int? ?? 0,
      // 【FEAT-381】未デプロイ環境では default '' (背景なし、安全 fallback)。
      // 【FEAT-513 v1.1 hotfix 4 (2026-07-31)】旧 shim `.replaceAll('.png', '.webp')`
      // は Backend migration 0197 (2026-07-31) で DB 値を '.webp' 化したため削除。
      backgroundImagePath: (json['background_image_path'] as String?) ?? '',
      // 【FEAT-439 (2026-06-17)】古い Backend (defeated 未配信) では false fallback。
      defeated: json['defeated'] as bool? ?? false,
    );
  }
}
