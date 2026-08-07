# Job Mastery System — v1.1+ 設計ノート

> 作成日: 2026-06-12
> **ステータス**: 🟡 設計中 (v1.1+ 着手時に詳細化、本ノートは方向性のみ)
> **規模**: 🔴 大規模 (推定 12-15h、v1.1 ロードマップ案件)
> **依頼者**: ユーザー (本セッション PM 2026-06-12)
> **関連**: [FEAT-430 (v1.0 ジョブ固定化)](../instructions/FEAT-430_job_fixation_v1_0.md) / [v1.1_roadmap.md](v1.1_roadmap.md) FEAT-310 (ジョブレベル + 5×5 アビリティ解禁、本ノートで詳細化対象) / [habit_weapon_system_v1_1.md](habit_weapon_system_v1_1.md) (v1.1 武器システム、本ノートと協調)

---

## 1. ビジョン

### ユーザー要望 (原文、本セッション 2026-06-12)

> ジョブの熟練度レベル機能を追加し、熟練度レベルが Max になったらそのジョブがどのキャラでも適用できるようにしようと思います。

### 1 行サマリー

「**装着して戦うほどジョブが育ち、Max まで育てたジョブは他キャラにも付け替え可能になる**」育成ループを追加し、Sabiowl の「積み重ねの可視化」哲学をジョブシステムにも適用する。

### Sabiowl 哲学との整合性

| 哲学 | 本システムでの体現 |
|---|---|
| 積み重ねの可視化 | 装着戦闘ごとに熟練度 EXP +X、Lv 上昇でユーザーに「育っている」感を提供 |
| 努力の選択肢解禁 | Max 到達ジョブのみ自由付与可、「育てた人だけが得られる柔軟性」を実現 |
| ペース尊重 | 強制ではない、好きなキャラ + ジョブで戦い続けても OK (Max 到達のメリットはあるが必須ではない) |

---

## 2. 現状 (v1.0、FEAT-430 適用後)

| 軸 | 現状 |
|---|---|
| Character ↔ Job マスタ | FEAT-391/428 で 24 キャラ × 13 ジョブ 1:1 紐付け済 |
| ジョブ解決経路 | `active_character.job` のみ (FEAT-430 で `player.active_job` 経路 deactivate) |
| `PlayerProfile.active_job` field | **維持** (v1.0 deactivate、v1.1+ で「Max 到達ジョブの上書き」用に再活用) |
| ジョブ熟練度 | **未実装** (本ノートで設計対象) |
| アビリティ | ジョブ固有の `on_hit_effect` (burn/heal/none) + `ult_cost` のみ実装、5×5 アビリティ展開は未実装 |

---

## 3. v1.1+ 設計案

### 3.1 データモデル

#### 新規 `PlayerJobMastery` モデル

```python
class PlayerJobMastery(models.Model):
    """【v1.1+】プレイヤーのジョブ別熟練度。

    PlayerProfile × Job のクロスでレコード管理。Lv が Max (= JOB_MASTERY_MAX_LEVEL) に
    到達すると、`player.active_job` 経路で **どのキャラに対しても** 当該ジョブを上書き可能。
    """
    player = models.ForeignKey(
        'api.PlayerProfile', on_delete=models.CASCADE,
        related_name='job_masteries',
    )
    job = models.ForeignKey(
        'api.Job', on_delete=models.CASCADE,
        related_name='masteries_by_player',
    )
    level = models.IntegerField(default=1, verbose_name='熟練度レベル (1-10)')
    exp   = models.IntegerField(default=0, verbose_name='熟練度 EXP (current level 内)')
    is_maxed = models.BooleanField(default=False, verbose_name='Max 到達済 (Lv=JOB_MASTERY_MAX_LEVEL)')
    first_maxed_at = models.DateTimeField(null=True, blank=True, verbose_name='Max 到達日時')

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=['player', 'job'], name='unique_player_job_mastery'),
        ]
        indexes = [
            models.Index(fields=['player', 'is_maxed']),  # 「Max 到達ジョブ一覧」高速検索用
        ]
```

#### 定数

```python
# backend/api/constants.py (v1.1+ 追加予定)
JOB_MASTERY_MAX_LEVEL = 10
JOB_MASTERY_EXP_PER_BATTLE_WIN = 5     # 装着戦闘勝利時の熟練度 EXP (Enemy 強さ独立)
JOB_MASTERY_EXP_PER_BATTLE_LOSS = 1    # 敗北時 (= 装着体験はあるため微 EXP)

def calc_job_mastery_exp_to_next(level: int) -> int:
    """Lv N → Lv N+1 に必要な EXP。指数曲線で Lv 後半に深み。

    Lv 1→2: 10 EXP (2 戦勝利)
    Lv 5→6: 50 EXP (10 戦勝利)
    Lv 9→10: 200 EXP (40 戦勝利、Max 直前で達成感重み)
    """
    return level * level * 2 + level * 4 + 4
```

### 3.2 解放経路

#### 装着時の熟練度 EXP 取得

`backend/api/views/battle.py:BattleFinishView` の reward 確定経路に追加:

```python
# 【v1.1+】装着ジョブの熟練度 EXP 加算
active_job = player.active_character.job  # FEAT-430 整合
mastery, _ = PlayerJobMastery.objects.select_for_update().get_or_create(
    player=player, job=active_job,
    defaults={'level': 1, 'exp': 0},
)
exp_gain = JOB_MASTERY_EXP_PER_BATTLE_WIN if won else JOB_MASTERY_EXP_PER_BATTLE_LOSS
mastery.exp += exp_gain

# Lv up 判定 (複数 Lv 同時 up 対応)
while (mastery.level < JOB_MASTERY_MAX_LEVEL and
       mastery.exp >= calc_job_mastery_exp_to_next(mastery.level)):
    mastery.exp -= calc_job_mastery_exp_to_next(mastery.level)
    mastery.level += 1

# Max 到達フラグ
if mastery.level >= JOB_MASTERY_MAX_LEVEL and not mastery.is_maxed:
    mastery.is_maxed = True
    mastery.first_maxed_at = timezone.now()
    # サビ口調イベント発火 (PostHog + Mobile SnackBar 用)

mastery.save()
```

#### Max 到達後の挙動

- `player.active_job` field の API (`PATCH /api/player/active_job/`) を **再活性化** (FEAT-430 で 410 Gone にしていた endpoint を復活)
- ただし指定可能なジョブは **`PlayerJobMastery.is_maxed=True` のジョブのみ** (validation)
- 戦闘解決経路 (battle.py) を 3 段階に戻す:
  1. `player.active_job` (Max 到達済の上書き、最優先)
  2. `active_character.job` (キャラ初期ジョブ、フォールバック)
  3. warrior (最終 fallback)

### 3.3 UI / UX

#### キャラ詳細シート (character_page.dart)

- 各キャラに「熟練度進捗バー」表示 (例: 「魔法剣士 Lv 3 / 10 (42 / 80 EXP)」)
- Max 到達ジョブには 👑 マーク + 「**他キャラにも装着可能**」hint

#### 新 PartyEditDialog (v1.1+ で増築)

- 「ジョブ選択」セクション再活性化
- 選択可能なジョブ: `active_character.job` (default) + Max 到達済 PlayerJobMastery のジョブ
- 未 Max ジョブは grayed out + 「あと N 戦で Max ですよ 🪶」hint

#### 新画面: ジョブ熟練度一覧 (v1.1+)

- 全 13 ジョブの熟練度進捗を表形式で一覧
- 完了率 + 残り戦闘数 + Max 到達ご褒美予告

---

## 4. 想定される失敗シナリオ (Pre-mortem、v1.1 着手時に詳細化)

### S1: 熟練度ファーミング (カテゴリ 8 回帰)
スライム連戦で全ジョブ Max まで上げる「作業ゲー」化

**緩和案**: `Enemy.tier` に応じた EXP 倍率 (zako x1.0 / mid_boss x1.5 / boss x2.5 / hidden_boss x4.0)

### S2: PlayerJobMastery レコード爆発 (カテゴリ 9 運用)
全プレイヤー × 13 ジョブ = N×13 レコード、index 設計を間違えると遅延

**緩和案**: `[player, is_maxed]` index で「Max 到達ジョブ一覧」高速化、UniqueConstraint で `[player, job]` 重複防止

### S3: v1.0 既存 `PlayerProfile.active_job` non-null ユーザーへの影響 (カテゴリ 1)
FEAT-430 で deactivate された field に値が残っているユーザー → v1.1+ で再活性化したら過去設定が突然復活

**緩和案**: v1.1+ migration で「未 Max ジョブが `active_job` に入っているユーザーは null にリセット」backfill

### S4: 熟練度 EXP 取得が race-prone (カテゴリ 2 競合)
複数バトル並行時の `PlayerJobMastery` レコード書き込み衝突

**緩和案**: `select_for_update()` で行ロック + atomic ブロック内で update (FEAT-377/427 と同パターン)

### S5: 「Max まで遠すぎ」UX 摩擦 (カテゴリ 6 UX)
Lv 1 → Max まで 40+ 戦 = 1 ジョブだけで 1 週間、13 ジョブで 3 ヶ月。「遠すぎてやる気出ない」

**緩和案**: 中間 Lv (Lv 5) で「アビリティ強化」等のサブ報酬を配置、Max 一点豪華主義を避ける (FEAT-310 5×5 アビリティ解禁案と統合)

### S6: ジョブ熟練度と Habit カテゴリの混乱 (カテゴリ 6 UX 認知負荷)
6 軸 CharacterStat (FEAT-213) + 13 ジョブ熟練度 = 認知負荷高い

**緩和案**: ジョブ熟練度は「戦闘ユーザーが知るべき情報」、Habit 経路ユーザーには優先表示しない (= キャラ詳細シート内に閉じる、ホーム画面には出さない)

---

## 5. リリース戦略

### Phase A (v1.1 起点): モデル + EXP 取得経路のみ (~3-4h)
- migration: PlayerJobMastery 追加
- battle.py に熟練度 EXP 加算ロジック追加
- API: `GET /api/player/job_masteries/` (一覧取得) 新規
- Mobile: キャラ詳細シートに熟練度バー表示 (read-only)

### Phase B (v1.1+ 数週後): Max 到達後の自由付与 (~3-4h)
- `PlayerActiveJobView` 再活性化 + validation
- PartyEditDialog ジョブ選択 UI 復活
- Max 到達時のサビ口調 SnackBar + 解禁演出

### Phase C (v1.1+ 半年後): ジョブ熟練度一覧画面 + アビリティ解禁 (~5-7h)
- 新画面「ジョブ熟練度一覧」(FEAT-310 5×5 アビリティと統合)
- 50 アビリティ seed + Lv 別解禁ロジック

---

## 6. 関連設計ノート

- [v1.1_roadmap.md](v1.1_roadmap.md) — FEAT-310 ジョブレベル + 5×5 アビリティ解禁 (本ノートで詳細化)
- [habit_weapon_system_v1_1.md](habit_weapon_system_v1_1.md) — v1.1 武器システム (本ノートと協調、ジョブ別装着武器テーブル統合の可能性)
- [battle_system.md](battle_system.md) — v1.0 バトルシステム真実値 (本ノート参照元)
- [../instructions/FEAT-430_job_fixation_v1_0.md](../instructions/FEAT-430_job_fixation_v1_0.md) — v1.0 ジョブ固定化 (本設計の前提)

---

## 7. v1.1 着手時の TODO

- [ ] 本ノートの「3 設計案」を実装計画として詳細化
- [ ] Pre-mortem を 5 → 10 件に拡充 (race 経路、Mobile UI フラグ、migration backfill)
- [ ] `FEAT-XXX_job_mastery_system.md` として指示書化 (Develop 委譲)
- [ ] PostHog イベント追加 (`job_mastery_level_up` / `job_mastery_maxed`) 計画
- [ ] リリースノート文言 (本 FEAT-430 リリースノート §8 を再利用)
