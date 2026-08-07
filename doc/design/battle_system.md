# Sabiowl バトルシステム設計ノート (MVP)

> 作成日: 2026-05-23
> **ステータス**: 🟡 設計レビュー中
> 元要件書: `doc/instructions_from_gemini/battle_system.md`
> セッション種別: PM (長期設計)
> 想定 FEAT 起票: **FEAT-295**（本ノート承認後）

---

## 1. 経緯と確定事項

### 1.1 背景

Gemini が起こした要件書（`doc/instructions_from_gemini/battle_system.md`）に基づき、習慣化のご褒美演出として「初期 FF 風の簡易 ATB バトル」を実装する。`refined_spec.md` L113「ステータスの冒険活用 → 冒険モードの戦闘設計が固まり次第」の保留事項に決着をつける本ノート。

`STATUS.md` 2026-05-21 メモ「**段階 0 検証バックログ完全消化 ✅ → 段階 1（バトルシステム設計議論）へ移行可能な状態**」を受けて、2026-05-23 の PM (長期設計) セッションで設計議論を開始。

### 1.2 設計議論で確定した 6 項目（2026-05-23）

| # | 項目 | 確定値 |
|---|---|---|
| 1 | MVP スコープ | ~3 週間 (Phase 1a-1f + 3 作戦 + 武器 +10) |
| 2 | バトルトリガー | ホーム画面常駐 ATB ウィジェット（Gemini 案踏襲） |
| 3 | アビリティ MVP | 固定 4 種（通常/強/回復/大技）ハードコード、SP/JP/ジョブ解禁なし |
| 4 | 作戦 MVP | 3 作戦（攻撃重視/回復重視/大技温存）ハードコード |
| 5 | 責務分担 | Sabiowl 流中間案（Flutter ローカル戦闘 + Backend 結果保存/報酬） |
| 6 | ビジュアル | 既存キャラ 9 体をドットアレンジ |

### 1.3 リリース戦略

**MVP リリースに含める**（β リリース前に Phase 1 完了が必須）。これにより Sabiowl の差別化軸が「習慣化アプリ + 静的 RPG（ガチャ・キャラ）」から「習慣化アプリ + アクティブ RPG（ATB バトル）」に拡張される。

---

## 2. MVP スコープ

### 2.1 含めるもの

- ✅ ATB ゲージ + ターン制（味方 1 vs 敵 1）
- ✅ ドット絵 + 5 種演出（待機ユラユラ / 突撃 / 斬撃 / のけぞり / ダメージポップ / フェードアウト消滅）
- ✅ プレイヤーレベル ↔ 味方キャラレベル自動連動（既存 `PlayerProfile.level` 流用）
- ✅ 4 アビリティ（通常攻撃/強攻撃/回復/大技）ハードコード
- ✅ 3 作戦切替（攻撃重視/回復重視/大技温存）ハードコード
- ✅ 武器装備（+10 固定値、初期 1 種）
- ✅ ホーム画面常駐 ATB ウィジェット
- ✅ 雑魚 1 種（ゴブリン）vs 1 戦完結
- ✅ 敗北ペナルティ（街に戻すだけ、素材保持）
- ✅ 既存 `Player.coins` / `Player.current_exp` への報酬加算
- ✅ Backend `BattleLog` 履歴保存 + 最新 1 戦のテキストログ表示

### 2.2 含めないもの（Phase 2 以降）

- ❌ ジョブ・アビリティ習得・着脱（SP/JP 育成）
- ❌ アビリティ追加（4 種以上）
- ❌ 武器種類拡張・調達経路（ガチャ/Shop 統合）
- ❌ 雑魚複数種類・ボス戦・進行型ステージ
- ❌ リプレイ動画（テキストログのみ MVP）
- ❌ 味方複数（パーティ編成）
- ❌ ボス降臨イベント（`refined_spec.md` Phase 3）
- ❌ 共鳴リング連携（`refined_spec.md` Phase 4）

### 2.3 想定リリース日

設計ノート承認後 + 13 営業日 ≈ **3 週間** で β 版に統合可能。FEAT-280 オフラインキャッシュ + FEAT-284 通知 Phase 1 と並行で進行可能（触るファイルが全く異なるため）。

---

## 3. アーキテクチャ

### 3.1 Backend / Flutter 責務分担（Sabiowl 流中間案）

| 層 | 責務 |
|---|---|
| **Backend** | ① 敵マスタ + 武器マスタ提供 ② 戦闘開始時に `battle_token` 発行（敵 ID + 期限） ③ 戦闘終了時に結果受信 → 報酬計算 → `Player.coins/exp` 加算 → `BattleLog` 保存 ④ 不正の最低限チェック（戦闘秒数下限 + ダメージ合計上限） |
| **Flutter** | ① ATB タイマー（10fps tick）② ダメージ計算（ATK + 武器 +10 - DEF）③ 4 アビリティ実行ロジック ④ 3 作戦の優先順位判定 ⑤ ドット絵 5 種演出 ⑥ 戦闘ログのテキスト生成 |

**設計哲学**: 「ソロアプリのため厳密なチート対策は優先度低」（Gemini 要件 5 章）を踏まえ、Backend は「物理的にあり得ない結果」だけを弾く。戦闘シミュレーション再現はしない（Phase 3 のボス降臨イベント等で必要になったら導入）。

### 3.2 Flame 採用判定: **自作 AnimationController を採用**

| 比較項目 | Flame 1.x | 自作 AnimationController |
|---|---|---|
| 学習コスト | 1 週間 | 0 日（既存資産） |
| バンドルサイズ | +1.5MB | +0KB |
| MVP の 5 種演出 | 過剰 | `Tween` + `AnimatedAlign` / `AnimatedScale` で十分 |
| 既存 Sabiowl 整合性 | Lottie 削除した方針と矛盾 | 既存 `WorldFrameSection` 等と整合 |
| Phase 2 で複雑化したら | 移行検討余地あり | 引き続き使うか Flame 移行判断 |

**結論**: MVP は自作 AnimationController + Stack ベース。Phase 2 でパーティ複数・複雑エフェクトが必要になったら Flame 移行を再検討（その時点で MVP の戦闘ロジック資産は移植可能な設計にしておく）。

### 3.3 ホーム画面常駐ウィジェットのレイアウト

**配置**: `WorldFrameSection` の直下（既存 ListView に Item として挿入）

**高さ**: 折りたたみ時 56px / 展開時 200px（`AnimatedSize` で遷移）

**状態 3 種**:

| 状態 | 表示内容 |
|---|---|
| 待機中 | 「次の出陣まで N 分」or 「出陣準備完了」+ 出陣ボタン |
| 戦闘中 | ATB ゲージ × 2 + キャラ/敵スプライト + 簡易テキストログ |
| 戦闘終了直後 | 「勝利！ +10 coins +20 EXP 🪶」（3 秒後に折りたたみ） |

**ユーザー操作**: タップで全画面戦闘ページ（`/battle`）に遷移可能。ながら見と能動見の両対応。

**バッテリー対策**（FEAT-224〜227 への退行回避）:
- ATB ゲージは **10fps 描画**（gauge は離散的に見える方が FF 風で味）
- `RepaintBoundary` でホーム他レイヤー隔離
- 戦闘待機中（敵未出現）は完全 idle（Timer 停止）

### 3.4 ファイル構造案

```
mobile/lib/features/battle/
├── constants/
│   ├── battle_constants.dart         # ATB tick / damage 基礎値 / 報酬倍率
│   └── abilities.dart                # 4 アビリティ定義 (HP%/ATK 倍率/cost)
├── models/
│   ├── combatant.dart                # キャラ + 敵共通の戦闘単位
│   ├── battle_state.dart             # 戦闘全体の状態
│   ├── ability.dart                  # アビリティ定義
│   └── tactic.dart                   # 3 作戦 enum + 優先順位ロジック
├── engine/
│   ├── atb_controller.dart           # ChangeNotifier ベース ATB タイマー
│   └── tactic_resolver.dart          # 作戦 → 次アクション決定
├── services/
│   ├── battle_orchestrator.dart      # 戦闘進行管理（ローカル）
│   └── battle_service.dart           # Backend API ラッパー
├── providers/
│   └── battle_provider.dart          # Riverpod state
├── widgets/
│   ├── battle_widget.dart            # ホーム画面常駐ウィジェット
│   ├── combatant_sprite.dart         # ドット絵 + 5 演出
│   ├── atb_gauge.dart                # 個別 ATB ゲージ
│   ├── damage_popup.dart             # ダメージ数値表示
│   └── battle_log_text.dart          # テキストログ表示
└── pages/
    ├── battle_page.dart              # 戦闘フル画面（出陣ボタンから遷移）
    └── battle_log_page.dart          # 履歴ログ表示

backend/api/
├── models/
│   └── battle.py                     # Enemy / Battle / BattleLog / WeaponMaster
├── views/
│   └── battle.py                     # POST /battle/start/, /battle/finish/
├── serializers.py (追記)
├── urls.py (追記)
└── migrations/
    └── 0081_battle_system.py
```

---

## 4. データモデル

### 4.1 Backend モデル

```python
# backend/api/models/battle.py

class Enemy(models.Model):
    """敵マスタ（MVP は 'goblin' 1 種のみ）"""
    key       = models.CharField(max_length=32, unique=True)        # 'goblin'
    name      = models.CharField(max_length=64)                      # 'ゴブリン'
    sprite_key= models.CharField(max_length=64)                      # asset key
    base_hp   = models.IntegerField(default=100)
    base_atk  = models.IntegerField(default=10)
    base_spd  = models.IntegerField(default=10)                      # ATB 充填速度
    level_scaling = models.FloatField(default=1.0)                   # Player.level に比例
    reward_coins  = models.IntegerField(default=10)
    reward_exp    = models.IntegerField(default=20)
    tier      = models.CharField(max_length=16, choices=[
        ('zako','雑魚'), ('boss','ボス')
    ], default='zako')

class WeaponMaster(models.Model):
    """武器マスタ（MVP: +10 固定値の初期武器 1 種のみ）"""
    key       = models.CharField(max_length=32, unique=True)         # 'starter_sword'
    name      = models.CharField(max_length=64)                      # '見習いの剣'
    atk_bonus = models.IntegerField(default=10)
    description = models.CharField(max_length=128, blank=True)

class Battle(models.Model):
    """戦闘セッション（token 発行 + 開始 → /finish/ で検証）"""
    player    = models.ForeignKey(PlayerProfile, on_delete=CASCADE, related_name='battles')
    enemy     = models.ForeignKey(Enemy, on_delete=PROTECT)
    enemy_hp_init  = models.IntegerField()                           # 計算済み
    enemy_atk_init = models.IntegerField()
    started_at  = models.DateTimeField(auto_now_add=True)
    finished_at = models.DateTimeField(null=True, blank=True)
    result    = models.CharField(max_length=16, null=True, blank=True, choices=[
        ('win','勝利'), ('lose','敗北'), ('abandon','中断')
    ])
    token     = models.CharField(max_length=64, unique=True)         # /finish/ で検証

class BattleLog(models.Model):
    """戦闘履歴（リプレイ表示用、最新 N 件保持、N は MVP では無制限）"""
    battle    = models.OneToOneField(Battle, on_delete=CASCADE, related_name='log')
    summary_text = models.TextField()                                # 'サビ → ゴブリン -15HP\n...'
    total_damage_dealt = models.IntegerField(default=0)
    total_damage_taken = models.IntegerField(default=0)
    rounds       = models.IntegerField(default=0)
    rewards_coins= models.IntegerField(default=0)
    rewards_exp  = models.IntegerField(default=0)
    created_at   = models.DateTimeField(auto_now_add=True)
```

**migration**: `0081_battle_system.py`（CreateModel × 4、auto-generated）

### 4.2 Flutter モデル

```dart
// mobile/lib/features/battle/models/

class Combatant {
  final String id;             // 'player' or 'enemy_goblin_1'
  final String name;
  final String spriteKey;
  final int maxHp;
  int currentHp;
  final int atk;
  final int spd;               // ATB 充填速度
  double atbGauge = 0.0;       // 0.0 〜 1.0
  bool isAlive => currentHp > 0;
}

@freezed
class BattleState with _$BattleState {
  const factory BattleState({
    required Combatant player,
    required Combatant enemy,
    required Tactic tactic,
    required BattleStatus status,    // waiting / running / won / lost
    required List<String> logLines,
    int chargedSpecialCount = 0,     // 大技温存カウンタ
  }) = _BattleState;
}

enum BattleStatus { waiting, running, won, lost }
enum Tactic { offense, recovery, conserveUltimate }
```

### 4.3 既存資産との接続

| 既存資産 | バトル接続 |
|---|---|
| `PlayerProfile.level` | プレイヤー味方ユニットの `Combatant.atk` / `maxHp` 計算式に使う |
| `OwnedCharacter` | 出陣時に「いま装着している」キャラを取得（MVP は最初の所持キャラ固定） |
| `CharacterStat` 6 値 | MVP では未使用（Phase 2 でジョブ解禁条件に活用） |
| `Player.coins` | 戦闘勝利報酬の加算先 |
| `Player.current_exp` | 戦闘勝利報酬の加算先（既存レベルアップ経路を流用） |
| `WorldFrameSection` | ATB ウィジェットの配置 anchor |

---

## 5. アビリティ + 作戦の固定セット

### 5.1 4 アビリティの数式（MVP ハードコード）

| アビリティ | コスト | ダメージ/効果 | 待機時間 | アニメ |
|---|---|---|---|---|
| 通常攻撃 | なし | ATK × 1.0 | 1.0s | step_forward → slash |
| 強攻撃 | なし | ATK × 1.8 | 2.0s | step_forward × 2 → slash big |
| 回復 | なし | HP +25%（上限 maxHp） | 1.5s | green_glow |
| 大技 | ゲージ満タン保留 3 回 | ATK × 3.0 | 2.5s | step_forward → flash → slash huge |

**注**: コスト「ゲージ満タン保留 3 回」= ATB ゲージが 100% に達した状態で「行動しない」を 3 回繰り返したら次のターンで大技選択可能。これは「大技温存」作戦でのみ意味を持つ。

### 5.2 3 作戦の優先順位ロジック（擬似コード）

```dart
// mobile/lib/features/battle/engine/tactic_resolver.dart

Ability resolveNextAbility(BattleState state, Tactic tactic) {
  final hpPct = state.player.currentHp / state.player.maxHp;
  final canUltimate = state.chargedSpecialCount >= 3;

  switch (tactic) {
    case Tactic.offense:
      // 50%通常 / 50%強攻撃、HP 関係なし
      return Random().nextBool() ? Ability.normal : Ability.strong;

    case Tactic.recovery:
      if (hpPct < 0.30) return Ability.heal;
      if (hpPct < 0.50) return Ability.strong;
      return Ability.normal;

    case Tactic.conserveUltimate:
      if (canUltimate) return Ability.ultimate;
      return Ability.normal;  // ゲージ満タンでも保留（chargedSpecialCount++）
  }
}
```

---

## 6. 戦闘フロー

### 6.1 戦闘開始トリガー条件

**MVP の自動トリガー**: 「習慣達成数が前回戦闘から **3 回**」蓄積したら、ホーム画面の ATB ウィジェットに「出陣準備完了」と表示。ユーザーが「出陣」ボタンタップで戦闘開始。

**理由**: 「即時バトル」は連続達成者の体験を損なう / 「ウィジェット常駐 + 出陣ボタン」は能動見の動線を残しつつ、習慣達成というコアループへの動機を加える。

**チケット蓄積カウンタ**: Backend `PlayerProfile.battle_charges`（IntegerField, default=0）を追加。`HabitCountView` の plus 経路で `+1`、戦闘開始時に `-3` でリセット（max 9 でクランプ、3 戦分まで温存可能）。

### 6.2 ATB ループ詳細

```
Tick = 100ms (10fps)
ゲージ充填速度: spd / 100 per tick = spd% per second
  例: spd=10 → 10% per sec → 10 秒で 100%

ループ擬似コード:
  while (battle.status == BattleStatus.running):
    tick(100ms):
      player.atbGauge += player.spd / 100
      enemy.atbGauge  += enemy.spd  / 100
      
      if player.atbGauge >= 1.0:
        ability = resolveNextAbility(state, tactic)
        applyAbility(player, enemy, ability)  // ダメージ反映 + アニメ
        player.atbGauge = 0.0
        if !enemy.isAlive: battle.status = won; break
      
      if enemy.atbGauge >= 1.0:
        applyEnemyAttack(enemy, player)  // 敵は通常攻撃のみ
        enemy.atbGauge = 0.0
        if !player.isAlive: battle.status = lost; break
```

### 6.3 勝利/敗北判定 + 報酬計算

**勝利時**:
- `Player.coins  += enemy.reward_coins`（既存 +10）
- `Player.current_exp += enemy.reward_exp`（既存 +20、既存レベルアップ経路を流用）
- `BattleLog` 保存
- `Player.battle_charges -= 3`（クランプ 0）
- UI: 勝利モーダル「勝利しました 🪶 +10 coins +20 EXP」（サビ口調）

**敗北時**:
- 報酬なし
- `BattleLog` 保存（敗北記録）
- `Player.battle_charges -= 3`（クランプ 0）
- UI: 敗北モーダル「今回は退きましょう。羽を休めて、また挑みましょうね 🪶」

**バランス論**: 雑魚 1 戦の coins/exp ≈ 習慣達成 1 回と同等の重み。バトルを「ご褒美」に保ち、メインの稼ぎ口にしない（既存の習慣化コアループを侵食しない設計）。

---

## 7. ビジュアル戦略

### 7.1 既存キャラ 9 体のドットアレンジ手法

**手法 A（推奨）**: AI 画像生成サービスで既存 PNG を「8bit 風 / ドット絵風」に変換
- ツール候補: PixelLab / Pixelfy.me / Photoshop Pixel Filter
- 工数: 1 キャラあたり 30 分 × 9 キャラ + 敵 1 種（ゴブリン） + Sabi = ~6 時間
- コスト: $20-30（サブスク 1 ヶ月）

**手法 B（フォールバック）**: 元 PNG をそのまま 96×96 にリサイズし `FilterQuality.none` で nearest-neighbor 描画
- 工数: 0 時間
- 品質: ピクセル粗が「ドット絵風」に近い見え方になる
- リスク: FF 風の温度が出にくく、雰囲気が弱い

**MVP の判断**: PM 側で **手法 A** を並行進行（Phase 1b 着手前までに完了）。間に合わなければ Phase 1b 開始時に手法 B で代替し、Phase 2 で AI 加工版に差し替え。

### 7.2 演出 5 種の実装方針

| 演出 | 実装 |
|---|---|
| 待機ユラユラ | `AnimationController(duration: 1500ms, repeat: true)` + `Transform.translate(y: sin(t) * 2)` |
| 突撃（一歩前） | `TweenAnimationBuilder<double>` で x 方向 +8px → 0px、200ms |
| 斬撃エフェクト | `AnimatedOpacity` で 0 → 1 → 0、150ms、白い斜線 SVG オーバーレイ |
| のけぞり | `AnimationController` で `Transform.translate(x: shake * 4)`、随時 sign 反転、300ms |
| ダメージポップ | `AnimatedDefaultTextStyle` + `AnimatedOpacity` + `Tween<Offset>` で y 方向 -20px、800ms フェード |
| フェードアウト消滅 | `AnimatedOpacity` で 1 → 0、500ms、終了後 widget 自体を remove |

**バッテリー配慮**: 待機ユラユラのみ常時動作（1500ms 周期 = 軽量）。他 5 種は「行動時のみ」発火、`RepaintBoundary` で外部レイヤー隔離。

---

## 8. Pre-mortem（失敗シナリオ + 緩和策、6 個）

### Pre-mortem #1: ATB タイマー dispose race（BUG-66 系）

**シナリオ**: 戦闘画面 dispose 中に `Timer.periodic` コールバックが `setState` を呼んで `defunct element assertion` でフリーズ。

**カテゴリ**: 競合・race

**予防策**:
- `BattleOrchestrator.dispose()` で必ず `_atbTimer?.cancel(); _atbTimer = null;`
- すべての setState 前に `if (!mounted) return;`
- CLAUDE.md「`dispose()` 内で `setState()` を呼ばない」を厳守
- 統合テスト: 戦闘中に強制 `unmount` → assertion なしを確認

### Pre-mortem #2: Backend 報酬整合性 vs ローカル戦闘の信頼境界

**シナリオ**: 改造アプリで「勝った」を Backend に送って coins を不当に取得。

**カテゴリ**: 権限・認証 / データ整合性

**予防策**（Sabiowl 流中間案、ソロアプリ哲学）:
- `Battle.token` を 32 文字ランダム + 30 分期限で発行
- `/finish/` で `token` 必須 + 「物理的にあり得ない結果」をチェック:
  - 戦闘秒数 < 3 秒 → reject（最速でも 1 ターンに 1 秒）
  - ダメージ合計 > `enemy.maxHp × 5` → reject（明らかに不自然）
  - `Player.battle_charges < 3` → reject（チケット不足での出陣不可）
- 厳密シミュレーション再現は **しない**（ソロアプリ + 実装コスト +2 週間）
- 観測: PostHog `battle_result` event に `duration_sec` / `damage_dealt` 送信、リリース後にチート率モニタリング

### Pre-mortem #3: 既存ホーム画面のレイアウト崩壊

**シナリオ**: ATB ウィジェット追加で `WorldFrameSection` + `SabiMessagePanel` と縦方向に競合 → スクロール過多 → ユーザーから「ホームが重い」苦情。

**カテゴリ**: 副作用の連鎖 / UX 摩擦

**予防策**:
- ウィジェットは **折りたたみ式**（デフォルト展開、ユーザーが閉じられる）
- 折りたたみ時 56px / 展開時 200px、`AnimatedSize` で柔らかい遷移
- `SharedPreferences` に `battle_widget_collapsed: bool` を保存し起動時復元
- 統合テスト: 既存ホーム画面のスクリーンショットと差分比較（widget 追加前後の縦長変化が +200px 以内）
- PostHog: `battle_widget_toggle` event で開閉率を計測

### Pre-mortem #4: バッテリードレイン（FEAT-224〜227 への退行）

**シナリオ**: ATB ゲージが 60fps で常時描画 = ホーム滞在中バッテリー消費激増、FEAT-224〜227 で得た +20〜40% 改善を全部食う。

**カテゴリ**: 運用 / UX 摩擦

**予防策**:
- ATB ゲージは **10fps 描画**（gauge は離散的に見える方が FF 風で味）
- `RepaintBoundary` でホーム他レイヤー隔離
- **戦闘待機中（敵未出現）は完全 idle**（Timer 完全停止）
- スプライト待機ユラユラは 1500ms 周期で十分（60fps 不要）
- 統合テスト: 戦闘待機中の `Timer.active` カウントが 0 であることを assert
- 実機検証: ホーム滞在 30 分のバッテリー消費が FEAT-227 前と同水準であることを確認

### Pre-mortem #5: ガチャキャラ未所持時の出陣エラー

**シナリオ**: 新規ユーザー or 異常状態で `OwnedCharacter` 0 件 → バトル開始時に null reference でクラッシュ。

**カテゴリ**: エッジケース

**予防策**:
- オンボーディング完了 = 必ず 1 キャラ取得済みの既存仕様を確認（FEAT-188 でゲスト経路含めて保証済）
- **フォールバック**: Sabi 自身をデフォルト戦闘ユニットとしてデータ化（`'sabi_default'` Combatant、`spriteKey: 'sabi_dot_6464'`、HP/ATK は最弱値）。OwnedCharacter 0 件時に自動採用
- 契約テスト: `OwnedCharacter` クエリ 0 件 → Sabi デフォルトが選択されることを assert
- ログ: `battle_start_with_sabi_default` イベントを WARNING で送信（このフォールバックが発火する = 別所のバグの兆候）

### Pre-mortem #6: リプレイ未実装で「見逃した」クレーム

**シナリオ**: ながらプレイ前提で、戦闘終了時に画面を見ていなかったユーザーから「何が起きたか分からない」苦情。

**カテゴリ**: UX 摩擦

**予防策**:
- MVP 内で **「最新 1 戦のテキストログ」だけは保存**:
  - `BattleLog.summary_text = "サビ 通常攻撃 → ゴブリン -15HP\nゴブリン 反撃 → サビ -8HP\n...\nサビ 大技 → ゴブリン -32HP（撃破）"`
  - ホーム画面 ATB ウィジェット下部に「直前の戦闘ログ」リンク
  - タップで `BattleLogPage` 開示
- リプレイ動画（倍速ダイジェスト）は Phase 2
- PostHog: `battle_log_open` event で利用率計測、低ければ Phase 2 のリプレイ実装優先度を下げる

---

## 9. Phase 1a〜1f 細分化

| Phase | 期間 | 成果物 | 検証 |
|---|---|---|---|
| **1a: ATB エンジン基礎** | 3 日 | `battle/engine/atb_controller.dart`（`ChangeNotifier` ベース、Tick=100ms、ゲージ充填式）+ `tactic_resolver.dart`（4 アビリティ + 3 作戦判定） | 単体テスト 8 件（ゲージ満タンで attack 発火 / リセット / 一時停止 / dispose race 防止 / 3 作戦 × 各 HP 帯） |
| **1b: ドット絵 + 5 種演出** | 3 日 | 既存キャラ 9 体 + ゴブリン + Sabi の AI ドット化（PM 別タスク並行）+ `battle/widgets/combatant_sprite.dart`（5 演出統合） | 実機で全 5 演出が滑らかに表示、60fps 常時描画ではないことを Performance overlay で確認 |
| **1c: 1 作戦固定で 1 戦完結 + 敗北/勝利演出** | 2 日 | `battle/services/battle_orchestrator.dart` + `battle/widgets/battle_widget.dart`（折りたたみ式 ATB ウィジェット）+ 勝利/敗北モーダル | 実機で 1 戦完結（攻撃重視 + ゴブリン）、勝利時 coins/exp 加算、敗北時メッセージ |
| **1d: 既存 EXP/coins 連動 + 戦闘トリガー** | 2 日 | `battle/providers/battle_provider.dart` + `home_page.dart` に `BattleWidget` 配置 + `HabitCountView` に `battle_charges += 1` + チケット蓄積 UI | 実機で 3 回習慣達成 → 「出陣準備完了」表示 → 戦闘終了で coins/EXP 加算反映 |
| **1e: Backend 戦闘ログ保存** | 1 日 | `backend/api/models/battle.py`（4 モデル）+ `views/battle.py`（`/battle/start/`, `/battle/finish/`）+ serializers + urls + migration 0081 + Enemy/WeaponMaster の seed（management command or migration data）| 契約テスト 5 件（token 発行 / 結果保存 / 不正検出 3 種 / 報酬付与 / `BattleLog` クエリ） |
| **1f: 統合テスト + サビ口調統一 + Pre-mortem 検証** | 2 日 | Flutter integration test 3 件（戦闘フル PASS / 敗北 / リプレイログ表示）+ サビ口調統一（勝利/敗北/出陣文）+ Pre-mortem #1〜#6 緩和策の動作確認 + Codemagic ビルド | `flutter analyze` 0 件 / `flutter test` PASS / `sabi_tone_test` PASS / TestFlight 実機検証 5 シナリオ |

**合計**: 3 + 3 + 2 + 2 + 1 + 2 = **13 営業日 ≈ 2.5 週間**（~3 週間想定の余裕含み）

---

## 10. リリース後ロードマップ

> **更新メモ 2026-05-25 (PM 長期設計セッション 議題 A-E)**: v1.0 リリースを 7/10-15 に延期決定 → Develop 18 日前倒し完了 → 6/30 リリース再計画 (Stop Loss 7/8) に再修正。以下 4 項目を v1.0 に降格 / 前倒し:
> - **必殺技手動ボタン → FEAT-301 で v1.0 採択** (Gemini §1.2 完全完結、3 営業日)
> - **敵 3 体追加 + 弱点 / 耐性 + 段階解放 (Lv.15/25/35) → FEAT-302 で v1.0 採択** (3 営業日、§10 Phase 2「雑魚 2-3 → ボス進行型」の一部前倒し、3 連戦進行 + ボス専用攻撃パターンは v1.1 残置)
> - **バトル定数最終調整 → FEAT-303 で v1.0 採択** (1 営業日、知人テスト後 6/16-19 で実施、データドリブン)
> - **PartyEditDialog v1.0 軽量版 → FEAT-304 で v1.0 採択** (2.5 営業日、Gemini `guild_equipment_display.md` の「ジョブ動的変更 + 装備閲覧 + アビリティ閲覧」のみ先行、フルスコープは FEAT-310 で v1.1 へ)
>
> v1.0 リリースチェックリスト: `doc/release_checklist/v1.0.md` 参照。**パーティ 3 人化 + 控え + 交代 + ATB 並列 4 人化 (Gemini §1.1/2.1/2.2) は v1.1+ 固定維持** (アーキテクチャ刷新 10 日、v1.0 リスク過大と判定)。
>
> **v1.1 起票予定メモ (リリース後 PM 長期設計セッションで FEAT-310 / FEAT-313 として起票)**:
>
> **🔗 集約済み**: v1.1 マスター TODO は **`doc/design/v1.1_roadmap.md` が真実値** (PM 長期設計セッション 2026-05-27 で集約完了)。本セクションの Phase 2 / Phase 3 大項目は v1.1_roadmap.md §2-A バトル / NPC / 装備系 + §3 v1.2+ 大規模項目に採番済み (FEAT-335 〜 FEAT-340 等)。本 §10 は引き続きバトル設計の詳細仕様ノートとして機能、ロードマップ判断は v1.1_roadmap.md を参照。
> - **FEAT-310: Gemini guild_equipment_display.md フルスコープ実装** (~25 営業日 / 5 週間)
>   - パーティ 3+1 人化 (Combatant 単数 → List<Combatant> party 化、BattleOrchestrator/AtbController/BattleState 全面改修)
>   - 控え枠 + 交代ロジック + クールタイム
>   - 各キャラ独立 UI ブロック × 3 + 控え 1 (Gemini §1.2)
>   - **🟢 MiniBattleArena 3+1 レイアウト = 案 Z 採択 (PM セッション 2026-05-29 確定、ユーザー判断)**:
>     - **設計議論**: ユーザー要望「ATB バー進捗速さをキャラごとに分けたい + 味方は縦 1 列で並べたい」→ PM 客観的意見 4 案 (X 情報量重視 / Y 横並び+短縦 ATB / Z 世界観重視 / W 一体型極限) 比較 → **案 Z 採択**
>     - **詳細モック**: `doc/design/mockups/feat_310_minibattle_arena_3_1_mock.html` (本モックを設計ベースとして実装、ブラウザで開けば即視覚確認可)
>     - **構造**: 額縁 aspectRatio 1.43:1 維持 (340 × 237 dp、FEAT-209/210 既定) + 敵 (左、sprite 36px、大型対峙感) + **味方縦 1 列 × 4 体** (右、行高 24dp、控えも統合)
>     - **🆕 HP|ATB 一体型バー**: 1 本のバーを左右半分に分割、左 50% = HP (緑/黄/赤で健康度色変化) + 右 50% = ATB (水色 → 紫グラデーション、充填度連動) = **個別 ATB を縦圧迫なしで実現**
>     - **背景余地 49%** (案 X 36% より +13%) で FEAT-381 戦闘背景画像 (bg_zako/mid_boss/boss/hidden_boss.png) を完全活用 + 将来 v1.2+「キャラ自由演出 (歩く/会話/環境変化)」の余地確保
>     - **控え 4 行目統合**: opacity 0.55 + 黄色 border 左端 + ATB 部分を斜線パターン (「待機中」表現)、上部から独立アイコン削除 = 4 体均等扱い
>     - **配置しないもの (BattlePage 集約)**: 必殺ボタン (FEAT-301 分業継承) / 数値詳細 (180/180 等) / 装備変更 (EquipmentSelectionOverlay) / Tactic 詳細切替 = ホーム MiniArena は「ながら見観戦モード」、操作は全画面 BattlePage に集約 (CLAUDE.md「習慣化 7 割 / ゲーム 3 割」整合)
>     - **凡例追加必須**: 1 体目下に「HP | ATB」テキストラベル (初心者向け、HP|ATB 一体型は革新的だが視認性低下リスクへの配慮)
>     - **実装留意点**: ① HP/ATB 一体型バー widget 新規 (`HpAtbCombinedBar`、Combatant 拡張) ② sprite 縮小 18-20px (案 X 28px より圧縮) ③ 各 Combatant.atbGauge を直接バインド (個別更新) ④ 背景画像 = FEAT-381 流用 + alpha 0.35 上乗せで視認性確保 ⑤ タップで `context.push(AppRoutes.battle)` で BattlePage 操作モード遷移
>     - **検討時の不採用案**: 案 X (情報量重視、行高 32dp、独立 HP/ATB 2 本、背景 36%) = MMORPG パーティフレーム王道だが Sabiowl 世界観喪失リスク / 案 Y (横並び + sprite 下短縦 ATB) = 戦闘感最強だが「縦 1 列」要望と不整合 / 案 W (HP/ATB 1 本 2 色グラデーション) = 情報密度極限だが初心者難解
>   - Ability モデル新規 (50 アビリティ seed = 5 ジョブ × 5 通常 × 5 必殺)
>   - PlayerJobProgress モデル新規 (ジョブレベル + EXP_in_job、戦闘勝利時加算)
>   - BattleOrchestrator のアビリティ動的化 (固定 4 種 → DB 駆動)
>   - TacticResolver のアビリティスロット参照化
>   - PartyEditDialog 拡張 (FEAT-304 が基盤、装備変更 + アビリティ選択 + ジョブレベル可視化)
>   - **🔴 装備選択カード階層 UI (Gemini `doc/instructions_from_gemini/guild_equipment_2.md` 統合、PM 長期設計セッション 2026-05-25 ユーザー判断 案 A 採択で v1.1 確定)**:
>     - **Layer 0**: ギルド画面 (黒マスク)、**Layer 1**: 編成・装備 dialog (FEAT-304 PartyEditDialog、はみ出して見える)、**Layer 2**: 装備選択カード (一回り小さい、ListView スクロール) の 3 層 Stack
>     - 装備選択カード内部構造: ヘッダー (左上「＜戻る」+ 中央「装備の変更」+ 右上「×」) / 現在装備中フィールド (固定枠) / 所持装備一覧 (ListTile に「装備する」ボタン、ListView スクロール) / 閉じる動線 (＜戻る・×・カード外背景タップ)
>     - 実装方針: Flutter `Stack` + `isSelectingEquipment` state flag、もしくは `Navigator.push(PageRouteBuilder(opaque: false))` で透明背景 (Gemini 仕様の第一候補は Stack)
>     - **新規 widget**: `mobile/lib/features/battle/widgets/equipment_selection_overlay.dart` (~200-300 行想定)
>     - **v1.0 で実装しない理由**: ① WeaponMaster/PlayerWeapon が v1.0 未使用 = **武器バリエーション 1 種 (starter_sword) のみ** = 「選択肢のない選択 UI」で UX 反価値 ② 武器ガチャ実装時に WeaponMaster は新スキーマで再設計 = 今 UI 作っても二度手間 ③ リリース 5 週前の PM 哲学「禁句リスト」整合性 (FEAT-307/308/309/311 はバグ修正カテゴリで対象外、本 UI は新機能追加)
>     - **v1.1 起票時の前提**: 武器バリエーション 3-5 種追加 (新スキーマ migration) + WeaponMaster API + PlayerWeapon 一覧 API + 装備変更 API + EquipmentSelectionOverlay widget + BattleConstants.starterWeaponAtkBonus ハードコード解除 + 装備変更時の damage 計算動的化 が **セットで完成** して初めて Gemini 仕様の UX 価値が実現
>   - **🔴 WeaponMaster / PlayerWeapon 削除統合 (機能レビュー 20260525 P0-3、v1.1 降ろし採択)**: 現行 2 モデル (`backend/api/models/battle.py:148-194`) は v1.0 で view/serializer 参照ゼロ + damage 計算未使用 = 完全な YAGNI。FEAT-310 武器ガチャ実装時に削除 + 新スキーマ (武器種別 / レアリティ / 強化値 / スキル / 属性 / ガチャ排出確率) で再設計。migration 1 本で `DeleteModel × 2` + 新規 `Weapon` / `PlayerWeapon` (新スキーマ) CreateModel + データ移行不要 (v1.0 でレコード 0 件想定、PlayerWeapon は onboarding 自動付与未実装)。**v1.0 で残す理由**: ① ユーザー影響ゼロ (現状未使用) ② リリース 5 週前の不可逆 Backend migration リスク回避 ③ 武器ガチャ実装時にどうせ新スキーマで再設計 → 今削除しても二度手間
>   - **✅ CharacterStat → バトル能力 1 対 1 連動 (FEAT-333 として v1.0 採択・実装済み、2026-05-27)**:
>     - **発見の経緯**: 当初は v1.1 持ち越し方針 (本 §10 FEAT-310 sub で計画化)。PM 長期設計セッション 2026-05-27 でユーザー「現状の各ステータスについて、どのステータスがバトルのどの能力を向上させるのか整理してください」の調査結果として、CharacterStat 6 軸 (運動力 / 学習力 / 健康力 / 精神力 / 創造力 / 貢献力) が **バトル能力に何も連動していない** 構造的盲点が判明 (battle.py / battle_provider.dart grep ヒットゼロ、過去 codebase_review 5/18/25/27 全件で未指摘)。FEAT-171 + FEAT-213 で「習慣達成 → ステ加算」までは完備、しかし「ステ成長 → バトル能力向上」連結が未実装 = Sabiowl コア哲学「習慣達成が世界を動かす」の最大の未完成箇所だったため、ユーザー pivot 「FEAT-310 は v1.0 に含めてください」を受けて **設計案 A (1 対 1 連動) のみ v1.0 採択** で 3h で実装完結
>     - **v1.0 採択範囲 (FEAT-333、設計案 A)**:
>       | ステータス | バトル能力 | 連動式 (実装値) | 効果例 (各ステ Lv 5 で) |
>       |---|---|---|---|
>       | 運動力 | 最大 HP 加算 | `maxHp += 運動力.level × 5` | +25 HP |
>       | 学習力 | 攻撃力加算 | `atk += 学習力.level × 1` | +5 ATK |
>       | 健康力 | turn 末 HP 自然回復 | 1 turn ごとに `+健康力.level × 2` HP | +10 HP/turn (maxHp clamp) |
>       | 精神力 | ATB 充填速度 | `atbSpeedModifier += 精神力.level × 0.01` | +5% 充填 |
>       | 創造力 | クリティカル率 | `critRate += 創造力.level × 0.005` | +2.5% クリ率 (×1.5 ダメージ) |
>       | 貢献力 | 被ダメージ軽減 | 受けるダメージ `× (1 - 貢献力.level × 0.005)` | -2.5% 被ダメ |
>     - **実装ファイル (3 ファイル + 新規 test 1)**: ① `models/combatant.dart` に `hpRegenPerTurn` / `critRate` / `damageReduction` を default 0/0.0 で追加 (退行ゼロ保証) ② `providers/battle_provider.dart:_buildPlayerCombatant` で CharacterStat 6 軸取得 + 1 対 1 連動式適用 (`statsNotifierProvider.valueOrNull` null fallback) ③ `services/battle_orchestrator.dart:_applyResistance` に critRate (random roll ×1.5) + damageReduction (×(1-red) 乗算) 統合、`_applyAbility` に turn 末 hpRegenPerTurn (running + 生存 + maxHp clamp で発火)、`_DamageResult.criticalLog: String?` → `criticalLogs: List<String>` 拡張で weak_ult_cost ⚡ + 創造 ✨ の同時発火対応 ④ `test/battle/stat_battle_link_test.dart` 新規 ~250 LOC、8 シナリオ全 PASS (退行ベース / 6 軸 stat 別 + 健康 maxHp clamp 補助)
>     - **v1.0 採択の判断根拠**: ① ユーザー明示の v1.0 採択指示 (PM 長期設計セッション 2026-05-27) ② FEAT-318 以降 3 条件 (条件 A 即時実装 / 条件 B Sabiowl コア哲学未完成解消 = 既存範囲拡張 / 条件 C バッファ 0.97 日 → 3h 消費で 0.57 日残) すべて満たす ③ default 0 fallback で既存 BattleOrchestrator/AtbController/TacticResolver の挙動完全互換、退行ゼロ (test 123 件全 PASS) ④ 「習慣達成が世界を動かす」コア哲学のメカニクス化完成
>     - **v1.1 持ち越し範囲 (FEAT-310 sub の残)**: バランス係数 (×5 / ×1 / ×0.01 等) の PostHog データドリブン最適化 / SP/JP 育成体系 / ジョブ別の stat 効果差別化 / アビリティ選択経路。本 FEAT-333 は「習慣達成 → stat → バトル」の最小連動線のみを v1.0 で完結
>   - **🔴 lastLevelUpAt / previousPlayerLevel Backend 本実装** (FEAT-308 v1.0 暫定 SharedPreferences 実装を Backend 駆動に置換、移行時に SharedPreferences cleanup migration 必要)
>   - PlayerWeapon 個別管理化 + 武器 3-5 種追加 + 装備 backfill migration
>   - 統合テスト 20 件 + バランス調整 4 日 (125 ビルド × 8 体 = 1,000 シナリオ、PostHog データドリブン)
>   - 設計判断根拠: 5/25 PM 長期設計セッションで「ライトユーザー (5-7 割) には複雑すぎ、Sabiowl ミッション「習慣化アプリ + ご褒美 RPG」と乖離リスク」のため v1.0 では先送り、PostHog データ取得後に **本当に需要があるか** を検証してから着手
>
> - **FEAT-313: ギルド受付ロザ追加 + 日替わり / シフト制 NPC** (~3 営業日)
>   - リリア (茶髪、業務熱心、20 代前半) の後輩 NPC として **ロザ (ピンク髪、明朗カジュアル、10 代後半)** を新規追加
>   - 提供 Gemini 参考画像 2 枚目 (ピンク髪 + 笑顔 + 茶サーコート) を sprite 調達ベースに使用
>   - **シフトロジック**: 日替わり or 偶数日/奇数日 or 平日/週末 (どれを採用するかは v1.1 起票時に PostHog データで判断: ユーザーが「同じキャラの方が安心」傾向なら平日/週末固定、「日替わり楽しい」傾向なら日替わり)
>   - **キャラ設定 (案、確定は v1.1 起票時)**: 名前=ロザ / 年齢=10 代後半 / 性格=元気 + 親しみ + ちょっと天然 / 一人称=「私」「ロザは」 / 二人称=「あなた様」「あなた」(リリアより砕けた) / 語尾=「〜ですよっ!」「〜だと思います!」「〜ですね〜」 / 絵文字=🌸 🎀 ⭐ 等 (リリアの実用系 🗡️ ⚔️ 🛡️ と対比、カジュアル系)
>   - **CLAUDE.md 更新**: 「リリアの口調ルール」セクション直下に「ロザの口調ルール」セクション追加、3 キャラ (サビ / リリア / ロザ) の役割分担と出現範囲を表で整理
>   - **設計判断根拠**: 5/25 PM 長期設計セッションでユーザーから「1 日ごとに受付キャラが変わる」案が出たが、v1.0 でいきなり 2 キャラ並走は「リリアの個性確立前 = 学習コスト増 + キャラ個性が薄くなる」リスクで案 A 採択 (リリア固定)。v1.1 で「リリアという既知キャラ + ロザという新顔」のサプライズ体験として段階的拡張

### Phase 2（v1.1+, ~3 週間）

- パーティ 3 人化 + 控え + 交代 (**Gemini `battle_system_2.md` §1.1/2.1/2.2 完全実装**、アーキテクチャ刷新、`List<Combatant> party` 化 + `BattleOrchestrator` / `AtbController` / `BattleState` 全部修正)
- ジョブ + アビリティ + SP/JP 育成（`CharacterStat` 6 値 → ジョブ解禁条件）
- アビリティ追加（FF5 風着脱、最大 6 種）
- 武器装備拡張（ガチャ統合 or Shop 統合判断）
- **`PlayerWeapon` 個別管理化**（MVP は `BattleConstants.starterWeaponAtkBonus` 一律 +10 で代用、Phase 2 で全 player バックフィル migration + 装備 UI 実装）
- **`BattleOrchestrator.setTactic` 追加**（MVP は provider state のみ更新、orchestrator 内部の tactic は固定。Phase 2 で動的切替対応）
- 3 作戦のカスタマイズ（ユーザーがアビリティ組合せ）
- 雑魚 2-3 → ボス進行型ステージ（**FEAT-296 で「ボスリスト + 個別バトル」+ FEAT-302 で「弱点 / 耐性 + 段階解放 + 3 体追加 = 計 8 体」を MVP に前倒し済**、本項目は **「3 連戦進行」「ボス専用攻撃パターン (HP < 30% で発狂等)」「報酬差別化」** が残スコープ）
- on_hit_effect 状態異常拡張（paralysis / darkness / holy、真の DoT 実装、FEAT-299 burn/heal は MVP 簡略版）
- リプレイ機能（過去 3 回分のテキストログ + 倍速ダイジェスト、BattleLog 利用率 PostHog データで投資判断 = FEAT-236 と同パターン）
- 必殺演出強化（フラッシュ + カットイン、FEAT-301 ボタン採用で副次達成可だが、より派手にしたい場合）
- ATB 内部表現の 1000 max 正規化（Gemini §2.1 完全整合、現行 0.0-1.0 のテスト書き換えコストとのトレードオフ）
- **画像品質アップグレード（Phase 2.5）**: PixelLab Free 64×64 → 128-256px 高品質ドット絵に差し替え。`CombatantSprite` の論理サイズを 64×64 固定にしておけば、ファイル置換 + widget サイズ拡張だけで対応可能。調達経路（プロ依頼 / PixelLab Pro / 別 AI ツール）はリリース後の PostHog データで投資判断

### Phase 3（v1.2+, 大規模）

- ボス降臨イベント（`refined_spec.md` Phase 3、`BossAttackLog` モデル）
- 共鳴リング連携（`refined_spec.md` Phase 4）
- 味方複数 (5 体以上の本格パーティ編成、Phase 2 のパーティ 3 人化を超える拡張)
- Flame パッケージへの移行検討（アニメ複雑化の閾値超過時）

---

## 11. FEAT 起票プラン

### 11.1 番号採番

最新 FEAT は FEAT-294（習慣テンプレート、完了）。次番号は **FEAT-295**（要 Glob で再確認）。

### 11.2 起票単位

**1 つの大型 FEAT として起票**（推奨）:
- `doc/instructions/FEAT-295_battle_system_mvp.md`
- Phase 1a〜1f を 1 つの FEAT 内で Phase 構造化
- 工数 13 日、複数ファイル + migration + 新規 widget/page/route 多数 = CLAUDE.md 大規模基準合致 → **Develop 委譲**

**代替案**: Phase ごとに FEAT 分割（FEAT-295〜FEAT-300、6 FEAT）も可。**ただし PM 推奨は 1 FEAT 集約** で、理由は以下:
- Phase 間の依存が強い（1e がないと 1d の Backend 連動が完成しない）
- Develop セッションが Phase 連続で集中できる方がコンテキスト維持コスト低
- STATUS.md の管理対象が増えすぎない
- Phase 単位の進捗追跡は FEAT 本文内のチェックリストで吸収可能

### 11.3 Develop 委譲時の引き継ぎ事項

指示書ヘッダーに以下を含める:

```markdown
> 作成日: 2026-05-23
> **ステータス**: 🔴 未着手
> 元設計ノート: `doc/design/battle_system.md`（必ず先に読むこと）
> 想定工数: 13 営業日（3 週間）
> Phase 構造: 1a〜1f（本指示書内で章分け）
> Pre-mortem: 6 件、各章の冒頭に再掲
> 並行可能タスク: FEAT-280 / FEAT-284（触るファイル独立）
> 検証必須: TestFlight 実機 5 シナリオ
```

### 11.4 残論点（FEAT 着手前にユーザー判断が必要）

1. **武器 +10 の初期配布方法**: オンボーディング完了時の自動付与? 初回ホーム表示時? Shop の初期所持? → 推奨: オンボーディング完了時自動付与
2. **ゴブリンの sprite asset**: AI 生成画像 / フリー素材ライブラリ / プレースホルダ → 推奨: PM 側で並行調達
3. **Sabi がデフォルト戦闘ユニットになる場合のステータス**: HP 50 / ATK 5 でフォールバック専用とするか? → 設計ノート時点で確定（HP 50 / ATK 5）

---

## 12. 設計レビューチェックリスト

ユーザーレビュー時に確認していただきたい項目:

- [ ] MVP スコープ 11 項目（2.1）の過不足
- [ ] バトル開始トリガー条件「習慣達成 3 回 = 出陣準備完了」のバランス感
- [ ] 報酬バランス「雑魚 1 戦 ≈ 習慣達成 1 回」のコアループ侵食リスク
- [ ] Backend チート対策レベル（厳密シミュレーションなし）の許容
- [ ] Flame 不採用判断
- [ ] Pre-mortem #1〜#6 の網羅性
- [ ] Phase 1a〜1f の工数見積もり妥当性
- [ ] 1 FEAT 集約 vs 6 FEAT 分割の判断
- [ ] 残論点 3 件（武器配布 / ゴブリン sprite / Sabi フォールバック値）

---

## 改訂履歴

| 日付 | 改訂者 | 内容 |
|---|---|---|
| 2026-05-23 | PM (Claude) | 初版作成、設計議論で確定した 6 項目を反映 |
| 2026-05-23 | PM (Claude) | §12 残論点 3 件（A 出陣 3 回 / B 報酬 +10 coins/+20 EXP / C 3 週間延期許容）すべて承認確定、FEAT-295 起票完了 |
