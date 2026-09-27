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

  // ── 【FEAT-526 (2026-08-21)】KO 演出 ─────────────────────────────────
  //
  // 出典 (`doc/instructions_from_gemini/KO.md`) が「調整できるように」と挙げた
  // 項目はすべてここに出す。**マジックナンバーを overlay 側に埋めないこと。**
  //
  // 内訳は合計がちょうど `koTotalDuration` (1830ms) になるよう分けてある:
  //     80 (ヒットストップ) + 120 (ズームイン) + 1500 (「K.O.」) + 130 (ズームアウト)
  // どれか 1 つを変えたら、他のどれかを同じ分だけ調整すること。

  /// 演出全体の長さ。
  /// **敵の fadeOut と報酬モーダルはこの時間だけ後ろにずれる。**
  ///
  /// 【2026-08-22 ユーザー判断 (2 回目)】650 → 1330 → **1830ms**。
  /// 1 秒でもまだ短いとの実機判断により、**「K.O.」の表示だけ**
  /// 1000 → 1500ms に伸ばした ([koLabelDuration])。出典 (`KO.md`) の
  /// 500〜800ms は**演出全体**の目安だったが、実機では**読ませる時間**が
  /// 足りなかった。
  ///
  /// 🔵 伸ばしたのは 1 区間だけで、**ヒットストップとズームは触っていない**。
  /// 「決めた」の手応えを作っているのは前半で、そこを伸ばすと間延びする。
  ///
  /// ⚠️ アンビエントのループは決着後の待ち時間を挟んでから次のバトルへ進む。
  /// 以前は 2 秒固定だったので「1.33 秒はぎりぎり収まる」と書いていたが、
  /// **1.83 秒では余裕が 170ms しか無く、次に伸ばした瞬間に破綻する。**
  /// そこで `ambient_auto_battle_orchestrator.dart` 側を
  /// `max(2 秒, koScaledTotal)` に変え、**この定数を伸ばしても壊れない**
  /// ようにした (2026-08-22)。
  static const Duration koTotalDuration = Duration(milliseconds: 1830);

  /// ヒットストップ (時間が止まって見える間)。ATB は `_atb.pause()` で
  /// すでに止まっているので、ここでは「まだ動かさない」時間として使う。
  static const Duration koHitStopDuration = Duration(milliseconds: 80);

  /// ズームイン (等倍 → [koMaxZoom])。
  static const Duration koZoomInDuration = Duration(milliseconds: 120);

  /// 「K.O.」表示時間。ズームイン完了時に出る。
  ///
  /// 【2026-08-22 ユーザー判断 (2 回目)】320 → 1000 → **1500ms**。
  /// 出典は 250〜400ms を挙げていたが、**実機では読み取る前に消えていた**。
  /// 等速で「K.O.」が見えているのは t=200ms 〜 1700ms の約 1.5 秒になる。
  ///
  /// 🔴 **この区間だけは倍速で割らない** ([koScaledLabel] 経由で使うこと)。
  /// ラベルは「感じる」ものではなく「**読む**」もので、読むのに要る時間は
  /// 倍速を上げても変わらない。詳細は [koScaledLabel]。
  static const Duration koLabelDuration = Duration(milliseconds: 1500);

  /// ズームアウト ([koMaxZoom] → 等倍)。
  static const Duration koZoomOutDuration = Duration(milliseconds: 130);

  /// 最大ズーム倍率 (出典 1.15〜1.30 の中央)。
  /// **カメラが存在しないので `Transform.scale` の拡大で代替する。**
  static const double koMaxZoom = 1.20;

  /// 背景を暗くする量 (戦闘エリアに重ねる黒 layer の alpha)。
  static const double koDimOpacity = 0.45;

  /// 画面シェイクの振れ幅 (px)。短時間・1 回。
  static const double koShakeAmplitude = 12.0;

  /// 画面シェイクの長さ。ヒットストップ + ズームインに収まる長さにする。
  static const Duration koShakeDuration = Duration(milliseconds: 180);

  /// インパクトエフェクト (爆発リング) の大きさ。
  static const double koImpactSize = 260.0;

  /// インパクトエフェクトが出ている割合 (演出全体に対する比)。
  ///
  /// 🔴 **比なので、演出全体を伸ばすとリングも一緒に伸びる。**
  /// 2026-08-22 に全体を 650 → 1330 → 1830ms と 2 度伸ばした。どちらのときも
  /// 比を据え置くとリングが一緒に伸びて**衝撃が余韻になってしまう**ため、
  /// 実時間 ~293ms が変わらないよう 0.45 → 0.22 → **0.16** と下げている
  /// (1830 × 0.16 ≒ 293ms)。**全体を触ったら必ずここも触ること。**
  static const double koImpactFraction = 0.16;

  /// 「K.O.」ラベルの表示位置 (戦闘エリア内の相対座標、`Alignment` と同じ意味)。
  /// y = -0.25 で中央よりやや上 (対峙している 2 体に被せすぎない)。
  ///
  /// `Alignment` 型ではなく double 2 本で持つのは、**本ファイルを Flutter 非依存に
  /// 保つため**。純粋ロジックのテスト (`test/battle/helpers/battle_simulator.dart`)
  /// が本ファイルを参照している。
  static const double koLabelAlignmentX = 0.0;
  static const double koLabelAlignmentY = -0.25;

  /// 「K.O.」ラベルの文字サイズ。
  static const double koLabelFontSize = 64.0;

  // ── 額縁 (アンビエント) 用の縮小値 (2026-08-22 ユーザー確定) ──────────
  //
  // 額縁は約 344 x 240px しかなく、しかも WorldFrameSection の暗幕 (55%) と
  // 敵背景オーバーレイ (25%) が既に乗っている。全画面用の値をそのまま持ち込むと
  // **「K.O.」が額縁からはみ出し、暗転の合計が ~75% でほぼ真っ黒**になる。
  //
  // 🔴 **時間は縮めない** (`koTotalDuration` は共通)。縮めるのは空間方向だけ。
  // ambient のループは勝敗確定後 2 秒待ってから次のバトルへ進むので、650ms の
  // 演出を挟んでも破綻しない。

  /// 額縁の最大ズーム (全画面 1.20 に対し控えめ)。
  static const double koAmbientMaxZoom = 1.10;

  /// 額縁の暗転量 (既存の暗幕に加算されるので全画面より小さく)。
  static const double koAmbientDimOpacity = 0.25;

  /// 額縁の「K.O.」文字サイズ (全画面 64pt では額縁幅の 3/4 を占めてしまう)。
  static const double koAmbientLabelFontSize = 28.0;

  /// 額縁の画面シェイク振れ幅 (全画面の約半分)。
  static const double koAmbientShakeAmplitude = 6.0;

  /// 額縁のインパクトエフェクト径。
  static const double koAmbientImpactSize = 130.0;

  /// 🔴 倍速時の下限。
  ///
  /// 3 倍速だとヒットストップが 80/3 = 27ms になり、描画 2 フレーム分で
  /// **「止まった」と認識できない**。逆に下限を大きく取りすぎると倍速の意味が
  /// 薄れるので、最小限の 40ms に留める (指示書 §4.6)。
  ///
  /// ⏭ Skip (50x) では実質すべての区間がこの下限に張り付く。
  /// **ただし「K.O.」ラベルだけは倍速の対象外** —— [koScaledLabel] 参照。
  static const Duration koMinDuration = Duration(milliseconds: 40);

  /// 倍速に合わせて演出時間を縮める。**下限 [koMinDuration] を下回らない。**
  ///
  /// `speedMultiplier` が 0 以下 (異常値) のときは等速として扱う
  /// —— 割り算で無限大にして固まるより、演出が長いほうがまだ安全。
  static Duration koScaled(Duration base, double speedMultiplier) {
    final speed = speedMultiplier > 0 ? speedMultiplier : 1.0;
    final scaled = (base.inMilliseconds / speed).round();
    final floor = koMinDuration.inMilliseconds;
    return Duration(milliseconds: scaled < floor ? floor : scaled);
  }

  /// 倍速時の**演出全体**の長さ。
  ///
  /// 🔴 **`koScaled(koTotalDuration, speed)` を使ってはいけない**
  /// (2026-08-22 実機報告)。下限 [koMinDuration] は**区間ごと**に掛かるので、
  /// 全体を単純に割ると **区間の合計より短くなり、下限が無効化される**。
  ///
  /// ```
  /// ⏭ Skip (50x)
  ///   区間の合計        : 40 + 40 + 40 + 40 = 160ms
  ///   koScaled(650, 50) : 650/50 = 13 → 下限 40ms
  ///   → 演出全体が 40ms = 60fps で 2.4 フレーム。実質見えない。
  /// ```
  ///
  /// 下限は「潰れすぎて認識できないのを防ぐ」ために入れたものなので、
  /// **合計側でそれを打ち消しては意味がない**。区間を積み上げた値を使う。
  ///
  /// 🔴 ラベルだけは [koScaledLabel] を使う (**倍速で割らない**)。
  ///
  /// 等速では `koTotalDuration` と一致する (80+120+1500+130 = 1830)。
  static Duration koScaledTotal(double speedMultiplier) =>
      koScaled(koHitStopDuration, speedMultiplier) +
      koScaled(koZoomInDuration, speedMultiplier) +
      koScaledLabel(speedMultiplier) +
      koScaled(koZoomOutDuration, speedMultiplier);

  /// 「K.O.」ラベルの表示時間。🔴 **どの倍速でも [koLabelDuration] を返す。**
  ///
  /// `speedMultiplier` を受け取るのに使わないのは意図的で、
  /// **「ここは倍速の対象外」を呼び出し側に意識させないため**。
  /// 他の区間と同じ形で呼べて、中で倍速を捨てる。
  ///
  /// ### なぜ割らないか (2026-08-22 ユーザー判断、3 段階の結論)
  ///
  /// 区間には性質が 2 種類ある:
  ///
  /// | 区間 | 用途 | 倍速で割ってよいか |
  /// |---|---|---|
  /// | ヒットストップ / ズーム / シェイク | **感じる** | 割ってよい (短くても「止まった」は伝わる) |
  /// | 「K.O.」ラベル | **読む** | 🔴 **割ってはいけない** |
  ///
  /// 倍速は「**戦闘の進行**を速く見たい」という要求であって、
  /// 「**結果を読む時間**を削りたい」ではない。ラベルを割ると、
  /// 3 倍速で 500ms、⏭ Skip では 30ms (下限 40ms = 60fps で 2.4 フレーム) になり、
  /// **速くするほど何が起きたか分からなくなる**。
  ///
  /// 経緯: 当初は全区間を割っていた → Skip で読めないので**ラベル専用の下限**
  /// (400ms) を入れた → 実機で「等速の 1.5 秒がちょうど良い」と判断され、
  /// **倍速でも 1.5 秒**に確定した。下限で近似するより素直。
  ///
  /// ⚠️ 代償: ⏭ Skip の演出全体が 40+40+1500+40 = **1620ms** になる。
  /// Skip は「バトルを 1-2 秒で終える」機能なので、**戦闘が一瞬で終わった後に
  /// 1.6 秒の演出が乗る**形になる。これは承知の上の trade-off で、
  /// 「読めないより待つほうがまし」という判断。
  static Duration koScaledLabel(double speedMultiplier) => koLabelDuration;

  // ── アンビエント（ホーム額縁）バトル ─────────────────────────────────
  /// 【FEAT-529 (2026-08-22)】アンビエント（ホーム額縁）バトルの速度上限。
  ///
  /// 🔴 額縁は「ながら見」の前景で、Skip (50x) を持ち込むと
  /// FEAT-527 の攻撃モーション（400ms 固定 = 倍速非追従）が
  /// **戦闘の終了に間に合わない**。6 キャラ分描いたモーションが
  /// ほぼ一度も見えないまま決着してしまう。
  ///
  /// 上限を 1x ではなく 3x にしているのは、**影響を Skip だけに閉じるため**。
  /// 1.5x / 2x / 3x を選んでいるユーザーの挙動は変わらない。
  ///
  /// ⚠️ これは「そのバトルでの実効値」であって、**ユーザーの設定そのものではない**。
  /// clamp 結果を SharedPreferences へ書き戻してはいけない（FEAT-529 Pre-mortem #1、
  /// 書き戻すと額縁バトルが 1 回走っただけでバトル画面の Skip 設定が消える）。
  static const double ambientMaxSpeedMultiplier = 3.0;

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
