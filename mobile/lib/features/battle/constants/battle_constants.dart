/// 【FEAT-295】バトルシステム MVP の定数（Phase 1a）。
///
/// 設計ノート (`doc/design/battle_system.md`) §3.3 / §6 を真実値とする。
class BattleConstants {
  BattleConstants._();

  // ── ATB tick ──────────────────────────────────────────────────────────
  /// Tick 周期（ms）。設計ノート §6.2 で 10fps 採用。
  /// ゲージ描画は離散的に見える方が FF 風で味、かつバッテリー消費を抑える
  /// （Pre-mortem #4: FEAT-224〜227 への退行回避）。
  static const int tickMs = 100;

  /// ゲージ充填速度: `combatant.spd / tickRate` per tick = `spd / 3` % per second
  /// 例: spd=10 → 30 秒で 100%。
  ///
  /// 【FEAT-296 hotfix 2026-05-24】100.0 → 200.0 に変更（2 倍遅く、戦闘 100-140 秒）。
  /// 【2026-06-13 hotfix #2】200.0 → 300.0 に変更（1.5 倍遅く、戦闘 150-210 秒）。
  /// ユーザー報告「戦闘がまだ短く感じる」を受けて。本日 HP 1.5 倍化を試みたが
  /// 戦闘時間延長の主因は本値 (tickRate)、HP 増加は撃数増のみで「テンポ」
  /// (1 ターン時間) を遅くする効果はなかった。HP 1.5 倍化は撤回し、本値で本質解。
  /// バトル時間を変えたい場合は本値のみ調整（高速化: 100 / 標準: 200 / 現行重め: 300）。
  static const double tickRate = 300.0;

  // ── 戦闘トリガー ──────────────────────────────────────────────────────
  /// 出陣可能チケット閾値。
  /// 【FEAT-406 (2026-06-01)】1 → 3: 3 達成で 1 戦参加可能 (旧 FEAT-295 思想復活)。
  /// 「三日坊主の壁」を毎日象徴化する設計。
  static const int chargesPerBattle = 3;

  /// チケット上限 (日次ストック最大)。
  /// 【FEAT-406 (2026-06-01)】10 → 3: 最大 3 戦ストック (= 9 達成で満タン)。
  /// 【FEAT-410 (2026-06-01)】3 → 30: 最大 10 戦ストック (daily 上限と整合)。
  ///
  /// 数値根拠: stockCount = charges // chargesPerBattle = charges // 3 のため、
  /// 「10 戦分ストック」を実現するには charges 上限 = 30 (= 30 達成で満タン)。
  /// 「ストック上限 = 1 日の参加可能回数」で認知ズレ解消、過剰防御 (二重制限) を撤回。
  /// 0:00 日次リセット (Backend battle_charges_date) が永続爆発リスクを構造的に断つ。
  /// 最大 10 戦ストック (= 30 達成で満タン、真の習慣家の充実感を ✓×10 で可視化)。
  static const int maxBattleCharges = 30;

  // ── 報酬 ──────────────────────────────────────────────────────────────
  // 【FEAT-358 (2026-05-27)】旧 `rewardCoinsPerWin` / `rewardExpPerWin` 削除。
  // FEAT-302 / FEAT-320 / FEAT-332 で Enemy 毎の `reward_coins` / `reward_exp`
  // が Backend で動的決定 → BattleStartView レスポンス → Flutter 反映 の経路に
  // 完全統一済。declaration 行以外で grep ヒットゼロの dead code を解消。

  // ── 大技 ──────────────────────────────────────────────────────────────
  /// 大技解放に必要な「ゲージ満タン保留」回数。設計ノート §5.1。
  static const int ultimateChargeRequired = 3;

  // ── 武器 ──────────────────────────────────────────────────────────────
  // 【FEAT-326】 旧 `starterWeaponAtkBonus = 10` 定数は削除。
  // 武器 ATK は `Player.equippedWeapon.atkBonus` を参照 (Backend `WeaponMaster`
  // が真実値、未装備時のフォールバックは inline `?? 10` で表現)。

  // ── プレイヤー HP 計算式（FEAT-295 hotfix 2026-05-25）──────────────────
  /// プレイヤー HP のベース値（Lv.1 起点）。
  /// Lv.1 maxHp = base + 1 * perLevel = 110 で、ゴブリン (HP 60) 確実勝利の設計。
  /// 全体式: `maxHp = playerBaseHp + player.level * playerHpPerLevel`。
  /// 【2026-06-13】100 → 200 に 2 倍化（バトル許容度拡幅、初心者寄り設計）。
  /// 【2026-06-13 #2 撤回】#2 の「200→300 1.5 倍化」を撤回し 200 に戻す。
  /// ユーザー意図「バトル時間延長」が真因だったが、HP 増加では効果薄かった
  /// (撃数増えても 1 ターン時間 = tickRate が支配的)。本質解は tickRate
  /// 200→300 (= 1 ターン 30 秒、戦闘 150-210 秒) で別途実施 (battle_constants.dart
  /// 上部の tickRate 修正)。HP 2 倍化 (#1) は許容度拡幅目的で維持。
  ///   Lv.1  maxHp = 200 + 1*20  = 220
  ///   Lv.10 maxHp = 200 + 10*20 = 400
  ///   Lv.20 maxHp = 200 + 20*20 = 600
  static const int playerBaseHp = 200;

  /// レベルアップ 1 つあたりの HP 増加量。
  /// 【2026-06-13】10 → 20 に 2 倍化（playerBaseHp とセットで全体 2 倍、#1）。
  /// 【2026-06-13 #2 撤回】30→20 に戻す (#2 で 1.5 倍化したのを撤回)。
  ///
  /// 【FEAT-400 v3 / FEAT-522 訂正】旧コメント「敵 HP も level_scaling で比例するため、
  /// レベル差での詰みは構造的に防止」は誤り。敵 HP は FEAT-400 v3 (2026-05-31) で
  /// `scaled_hp = base_hp` の固定式になっており、Lv には比例しない。ATK も
  /// FEAT-522 (2026-08-07) で固定になった。詰みを防いでいるのは
  /// **Player 側が育つほど必要撃数が減る**構造と `unlock_level` による段階解放である。
  static const int playerHpPerLevel = 20;

  // ── Sabi フォールバック値 ─────────────────────────────────────────────
  /// OwnedCharacter 0 件時の最弱フォールバック（Pre-mortem #5）。
  /// PM 確定値（指示書「私が引き取り」セクション）。
  static const int sabiFallbackHp = 50;
  static const int sabiFallbackAtk = 5;
  static const int sabiFallbackSpd = 10;

  // ── 不正検出（Backend と整合）─────────────────────────────────────────
  /// ダメージ合計上限の倍率。enemy_hp_init × 20 を超えたら不正。
  /// 【2026-07-05】5 → 20 に緩和 (dragon_slayer+FEAT-333 crit+攻撃の薬+弱点 の
  /// 乗算で単発 damage が閾値超過するのを緩和、Backend `_MAX_DAMAGE_MULTIPLIER`
  /// と整合)。
  static const int maxDamageMultiplier = 20;

  /// 【2026-07-09 撤去済】旧 `minBattleDurationSec = 3` (v1 で 1 に緩和後、v2 で撤去)。
  /// 撤去理由: client trust の duration_sec 検証は偽装可 + legitimate 1 撃キル
  /// (SSR 武器 + ATB 高速化) を誤検知して報酬 0 表示する副作用大のため。
  /// damage cap (× 20) + daily_battle_count (10/日) の 2 層で bot 対策十分。

  /// Battle token 有効期限（30 分）。
  static const Duration battleTokenExpiry = Duration(minutes: 30);

  // ── UI / アニメーション ──────────────────────────────────────────────
  /// 待機ユラユラの周期（設計ノート §7.2）。
  static const Duration idleSwayDuration = Duration(milliseconds: 1500);

  /// 突撃（一歩前）の duration。
  static const Duration chargeStepDuration = Duration(milliseconds: 200);

  /// 斬撃エフェクトの fade duration。
  static const Duration slashEffectDuration = Duration(milliseconds: 150);

  /// のけぞりの duration。
  static const Duration recoilDuration = Duration(milliseconds: 300);

  /// ダメージポップ（数値表示）の duration。
  static const Duration damagePopupDuration = Duration(milliseconds: 800);

  /// フェードアウト消滅の duration。
  static const Duration fadeOutDuration = Duration(milliseconds: 500);

  // ── BattleWidget レイアウト（Pre-mortem #3）──────────────────────────
  /// 折りたたみ時の高さ。
  static const double widgetCollapsedHeight = 56.0;

  /// 展開時の高さ。差分は +144px（設計ノート §3.3 / Pre-mortem #3 で +200px 以内）。
  static const double widgetExpandedHeight = 200.0;

  /// SharedPreferences キー: ウィジェットの折りたたみ状態を保存。
  static const String prefsKeyCollapsed = 'battle_widget_collapsed';
}

/// 【FEAT-390】バトル数値表示用の共通計算ヘルパー。
///
/// `battle_provider._buildPlayerCombatant` と `party_edit_dialog._StatusSection`
/// の両方が同一ヘルパーを呼び出すことで、「表示値とバトル内部値が必ず一致する」
/// 単一真実値設計を実現する（案 C: 共通ヘルパー化）。
///
/// Pre-mortem #1 対応: `computeAtk` が attackPowerModifier まで乗算するため、
/// Combatant 構築時は `attackPowerModifier = 1.0` に設定して二重適用を防ぐ。
class BattleDisplay {
  BattleDisplay._();

  /// 表示用 攻撃力計算。
  ///
  /// 式: (10 + level × 2 + weaponAtk + studyLv) × attackPowerModifier
  ///
  /// - `level`: プレイヤーレベル
  /// - `weaponAtk`: 装備中武器の atkBonus（未装備時は 0 or デフォルト 10）
  /// - `studyLv`: 学習力のレベル（FEAT-333 stat 連動）
  /// - `attackPowerModifier`: ジョブ修飾（戦士 1.3 / 魔導士 1.0 / etc）
  ///
  /// 戻り値: 整数化された攻撃力（round で丸め）
  static int computeAtk({
    required int level,
    required int weaponAtk,
    required int studyLv,
    required double attackPowerModifier,
  }) {
    final base = 10 + level * 2 + weaponAtk + studyLv;
    return (base * attackPowerModifier).round();
  }

  /// 表示用 ATB 速度修飾子計算。
  ///
  /// 式: atbSpeedModifier + mentalLv × 0.01
  ///
  /// - `atbSpeedModifier`: ジョブ修飾（戦士 0.9 / 青魔導士 1.0 / アサシン 1.4 等、FEAT-391 8 ジョブ）
  /// - `mentalLv`: 精神力のレベル（FEAT-333 stat 連動）
  ///
  /// 戻り値: ATB 速度倍率（1.0 = 100% 基準）
  ///
  /// 【codebase_review 20260530 P1-2】FEAT-391 で warrior ATB が 0.8 → 0.9 に変更されたため
  /// docstring を最新値に追従。8 ジョブの代表値で記載し、velocity 由来の stale を防止。
  static double computeAtb({
    required double atbSpeedModifier,
    required int mentalLv,
  }) {
    return atbSpeedModifier + mentalLv * 0.01;
  }

  /// ATB 倍率を文字列化。
  ///
  /// - `AtbDisplayFormat.percent` (default): "85%"
  /// - `AtbDisplayFormat.multiplier`: "0.85x"
  static String formatAtb(
    double atb, {
    AtbDisplayFormat format = AtbDisplayFormat.percent,
  }) {
    switch (format) {
      case AtbDisplayFormat.percent:
        return '${(atb * 100).round()}%';
      case AtbDisplayFormat.multiplier:
        return '${atb.toStringAsFixed(2)}x';
    }
  }
}

/// ATB 速度の表示形式。
enum AtbDisplayFormat { percent, multiplier }
