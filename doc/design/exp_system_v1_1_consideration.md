# EXP システム再設計 検討メモ (Gemini 案 exp_system.md)

> 作成日: 2026-06-14
> **ステータス**: ✅ FEAT-434 として v1.0 実装 (2026-06-14、`doc/instructions/FEAT-434_exp_system_v1_0.md`)
> **対象**: doc/instructions_from_gemini/exp_system.md の要件整理 + 既存衝突調査
> **依頼者**: ユーザー (本セッション PM 2026-06-14)
> **次のアクション**: 「PM 詳細調査後に再検討」セッションで本ノートを起点に判断

---

## 1. Gemini 案サマリー (exp_system.md)

### タスク種別ごとの仕様

| 種別 | 現状 (Sabiowl) | Gemini 案 |
|---|---|---|
| **Habit (習慣)** | 4 段階難易度 (easy/normal/hard/legendary)、`EXP_PER_COUNT * DIFFICULTY_MULTIPLIER` で計算 | **難易度廃止**、基本 10 XP + **継続ボーナス** |
| **ToDo** | Habit と共通の difficulty/EXP 経路 | **難易度 1-5 で 10/20/30/40/50 XP** |
| **Schedule (Timeline 予定)** | イベント完了で固定 +EXP | **ToDo と同テーブル (1-5 で 10-50)** |

### Habit 継続ボーナステーブル

```
獲得値 = 基本値 (10) + (streak // 30) * 3
上限 = 365 日で 46
```

| streak | 獲得値 |
|---:|---:|
| 0 日 | 10 |
| 30 日 | 13 |
| 60 日 | 16 |
| 90 日 | 19 |
| 180 日 | 28 |
| 365 日以上 | **46 (上限)** |

### 設計意図 (Gemini)
- 「難易度を盛る」行為を防ぐ
- 継続価値の強化
- 長期継続者と新規ユーザーの格差を抑制 (365 日上限)
- 経験値以外のモチベ = 実績・称号で補完

---

## 2. Sabiowl 現状実装との衝突マップ

### 衝突 A: Habit 難易度ベースの EXP 経路

| 既存 FEAT | 内容 | 衝突レベル |
|---|---|:---:|
| `EXP_PER_COUNT = 30` (FEAT-406) | Easy 基準値、Normal=45/Hard=60/Legendary=150 | 🔴 完全廃止 |
| `DIFFICULTY_MULTIPLIER` 定数 | easy=1.0/normal=1.5/hard=2.0/legendary=5.0 | 🔴 完全廃止 |
| FEAT-213 `CATEGORY_STAT_MAP` | 11 カテゴリ → 6 ステータス按分 | 🟡 互換可能 (新 EXP テーブルでも按分は適用可) |
| FEAT-375 (Legendary 枠拡張、💎 200) | ダイヤ購入で Legendary 枠 +1 | 🔴 Legendary 廃止で意味消失 |
| FEAT-380 (Legendary 枠厳格化) | 6 軸全 Lv 5 で 1 枠目解放 | 🔴 同上 |
| FEAT-429 (Legendary 枠累進価格) | 200/400/600/800/1000 💎 | 🔴 同上 |
| FEAT-334 (Lv 20 ゲート撤廃) | Legendary 解禁条件 | 🔴 同上 |
| FEAT-289 (habit_count_service 中央化) | difficulty 引数で EXP 計算 | 🟡 リファクタリング (新仕様で書き直し) |
| FEAT-398 (daily_exp_throttle) | 25 件超過で EXP 1pt 固定 | 🟢 維持可能 (スロットルは値の上限制御) |

### 衝突 B: ToDo / Schedule の難易度仕様

| 既存 FEAT | 内容 | Gemini 案との差 |
|---|---|---|
| FEAT-83 (ToDo) | ToDo は Habit と同じ難易度経路 | ToDo 難易度を 1-5 段階に変換 |
| TimelineEvent | 完了 +5 XP (FEAT-144 + FEAT-419) | 難易度フィールド追加 + UI 追加 |
| `TimelineCompleteView` (`timeline.py:280`) | charges 加算 = ToDo 経路同等 | 難易度別 EXP 計算追加 |

### 衝突 C: battle_charges 連携 (= クエストゲージ)

Gemini 案: 「習慣達成時に獲得した値をクエストゲージへ加算」

解釈 3 通り:
1. **解釈 X (文字通り)**: 獲得 XP = battle_charges 加算量
   - 継続 0 日 = +10 charges = 3 戦分以上
   - 既存 `chargesPerBattle=3` (FEAT-406) と衝突、レート完全崩壊
   - 365 日継続なら +46 charges = 15 戦分、爆発
2. **解釈 Y (別軸)**: 「クエストゲージ」は battle_charges とは別の新概念
   - 新 model field 追加 + 新 UI 必要
   - 大規模追加
3. **解釈 Z (現状維持)**: battle_charges は 1 達成 = +1 のまま、XP のみ新テーブル適用
   - 最も実装シンプル
   - Gemini の「クエストゲージ連携」記述と部分整合

→ **PM 推奨: 解釈 Z** (battle_charges は別軸維持、XP テーブルのみ再設計)。
解釈 X は明らかにバランス崩壊、解釈 Y は scope creep。

### 衝突 D: バトル経済 / レベルアップテンポ

新 EXP テーブルでの試算:
- Habit 1 達成: 旧 Normal 45 XP → 新 10 XP (継続 0 日) = **1/4.5 倍**
- 365 日継続でも: 旧 Normal 45 XP → 新 46 XP = ほぼ同等
- Easy だけだった旧 30 XP → 新 10 XP (継続 0 日) = **1/3 倍**

→ **新規ユーザーの Lv 上昇速度が 3-4 倍遅くなる**。
- 旧式: Lv 1→10 で約 150 日 (CLAUDE.md FEAT-319)
- 新式 (継続ボーナス考慮): 推定 **300-400 日**

これは「カジュアル化」「許容度拡幅」(本日の Player HP 2 倍化 + tickRate 300 と協調) と **逆方向**。

### 衝突 E: 6 軸ステータス (FEAT-213)

| 既存 | 影響 |
|---|---|
| `CATEGORY_STAT_MAP` (11 カテゴリ → 6 stat 按分) | 新 EXP テーブルでも按分は適用可、互換性 OK |
| 6 ステータスの Lv 計算 (`stat.max_exp = stat.max_exp * 1.2`) | EXP 量が変わるので Lv 上昇テンポ激変 |

---

## 3. 既存データへの影響 (移行コスト)

### Habit データ
- `Habit.difficulty` field: 既存全 Habit に値あり (easy/normal/hard/legendary)
- migration で全 `difficulty=None` に統一? or 維持して表示のみ削除?
- 既存 `Habit.total_exp` 値: 旧式で蓄積済、Lv 計算根拠が消失

### ToDo データ
- 現状 ToDo は Habit の `habit_type='todo'` で同じ難易度 field 共有
- ToDo 難易度を **1-5 段階** に変換するなら、easy/normal/hard/legendary → 1-5 のマッピング必要

### TimelineEvent データ
- 現状 difficulty field なし
- 新規追加が必要 (migration + model field)
- 既存 TimelineEvent 全件に default 値 (=3 等) を backfill

### Player Lv / CharacterStat
- 既存 player.total_exp / stat.exp は旧計算式の累積
- 新式に切替えると Lv 上昇速度が激変 (= 既存ユーザー困惑)
- 「リセット」or 「補正係数で滑らかに」or 「2 経路並走」等の判断必要

---

## 4. 8 つの設計判断ポイント (次回 PM セッションで決定)

| # | 判断項目 | 候補 |
|---|---|---|
| 1 | **v1.0 リリースに踏み込むか** | (a) v1.1 に回す / (b) Habit 難易度廃止だけ先行 / (c) 全部踏み込む |
| 2 | **`Habit.difficulty` field の扱い** | (a) 削除 / (b) 維持して非表示 / (c) easy/normal/hard/legendary を 1-5 に variant |
| 3 | **既存 Habit データの total_exp** | (a) リセット / (b) 旧式値維持 (Lv 計算は新式) / (c) 補正係数で平均化 |
| 4 | **ToDo 難易度 1-5 の意味** | (a) 既存 easy/normal/hard → 1/2/3 マッピング / (b) 全くの新規 5 段階 UI |
| 5 | **Schedule 難易度の UI** | (a) 既存 TimelineEvent に追加 / (b) v1.0 では実装せず後送り |
| 6 | **battle_charges 連携の解釈** | **(a) 解釈 Z (battle_charges 別軸維持)** ← PM 推奨 / (b) 解釈 X / (c) 解釈 Y |
| 7 | **継続ボーナスの streak 定義** | (a) 既存 `Habit.streak` (Habit 別) / (b) 全 Habit 横断の連続日数 |
| 8 | **6 軸ステータス (FEAT-213) との関係** | (a) 維持 + 新 EXP を按分 / (b) 廃止 |

---

## 5. 推定規模感 (判断項目別)

| v1.0 採択範囲 | 推定工数 | 影響 FEAT |
|---|---|---|
| 全部踏み込む (Habit 難易度 + ToDo + Schedule + 6 stat 影響) | **🔴 12-18h** | FEAT-213/289/375/380/406/429 + 多数の旧テスト |
| Habit 難易度廃止のみ先行 | 🔴 6-9h | FEAT-375/380/429 廃止 + テスト |
| v1.1 に回して設計のみ確定 | 🟢 1-2h (設計ノート起票のみ) | 影響なし |

---

## 6. PM 推奨アプローチ

### 段階 1: 設計ノート確定 (v1.0 リリース前、本ノート)
- 本ノート (`exp_system_v1_1_consideration.md`) を起点に、ユーザーと 8 つの設計判断を議論
- 最終仕様確定 → `exp_system_v1_1.md` (= 正式 design ノート) に格上げ

### 段階 2: 既存 FEAT の整理 (v1.0 リリース前)
- 廃止候補 FEAT (375/380/429 等) の依存関係を grep で網羅
- 廃止 vs 維持の判断 (= 残しても害なし or 削除しないと矛盾)

### 段階 3: v1.1 で実装 (リリース後 1-2 週)
- migration 戦略確定 (既存データの取り扱い)
- 段階的ロールアウト (まず Habit のみ → ToDo / Schedule)
- Pre-mortem + 検証シナリオ

### 段階 4: リリースノート + ユーザー教育
- 「習慣に難易度がなくなりました」「継続日数で価値が変わります」
- 既存ユーザーへの説明 + 補償 (= 既存難易度 Legendary は無料解放??)

---

## 7. 重要な保留事項

### 7.1 Gemini 案の曖昧さ
- 「クエストゲージ連携」の解釈不明 (上記 衝突 C)
- 「実績・称号」(7/30/100/365/1000日継続) は **新規追加? or 既存称号と統合?**
- 「30 日継続ごとに +3」= streak 30 日 to 60 日でも +3? 連続でなくてもよい?

### 7.2 ストリーク保護機構との関係 (FEAT-377/420)
- `Habit.streak` は休息日 / 保護機構で「途切れない」設計
- 継続ボーナスが streak ベースなら、保護機構の価値が増す = 整合性高い

### 7.3 ガチャ XP ブースト (FEAT-318) との関係
- 15 分 × value で EXP 1.5 倍ブースト (実装中)
- 新 EXP テーブルでも適用可能、相乗効果あり

### 7.4 経済の再バランス (= 大量 hotfix が連鎖する可能性)
- 旧 EXP テーブルで設計された Enemy reward_exp、ダイヤ取得経路、ガチャ報酬値
- 新 EXP テーブルで Lv 上昇テンポが激変 → 全体バランス見直し必要

---

## 8. 次回セッションでの議題候補

1. 上記 §4 の 8 設計判断をユーザーに確認
2. v1.0 踏み込み判断 (= 段階 1-2 を v1.0、段階 3-4 を v1.1)
3. 既存 FEAT 廃止候補リストの確定 (= 機械的に削除可能なものだけ先に commit)
4. 「実績・称号」の Gemini 案実装 (継続日数ベース) を別 FEAT 化検討
5. リリースノート文言ドラフト

---

## 9. 関連ドキュメント

- 元仕様: [doc/instructions_from_gemini/exp_system.md](../instructions_from_gemini/exp_system.md)
- 影響対象:
  - [doc/instructions/FEAT-213](../instructions/) (= grep で複数ヒット)
  - [doc/instructions/FEAT-289_habit_count_service_extraction.md](../instructions/FEAT-289_habit_count_service_extraction.md)
  - [doc/instructions/FEAT-375_legendary_slot_expand.md](../instructions/FEAT-375_legendary_slot_expand.md)
  - [doc/instructions/FEAT-380_legendary_slot_strict_unlock.md](../instructions/FEAT-380_legendary_slot_strict_unlock.md)
  - [doc/instructions/FEAT-406_quest_charges_redesign.md](../instructions/FEAT-406_quest_charges_redesign.md)
  - [doc/instructions/FEAT-429_shop_progressive_pricing_expansion.md](../instructions/FEAT-429_shop_progressive_pricing_expansion.md)
  - [CLAUDE.md §ゲームバランス定数 / §EXP・レベル / §Habit モデル](../../CLAUDE.md)
- 真実値ファイル:
  - `backend/api/services/habit_count_service.py` (EXP 計算経路)
  - `backend/api/constants.py` (`EXP_PER_COUNT` / `DIFFICULTY_MULTIPLIER`)
  - `backend/api/models/habits.py` (`Habit.difficulty` / `Habit.streak`)
