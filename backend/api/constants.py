"""
Sabiowl ゲームバランス定数・マジックストリング定義。
ビジネスロジックに関わる数値・文字列はここに集約し、
各モジュールはここから import して使用する。
"""


# ──────────────────────────────────────────────────────────────────────────────
# EXP / ゴールド
# ──────────────────────────────────────────────────────────────────────────────

class GameBalance:
    # 【FEAT-406 (2026-06-01)】20 → 30 (× 1.5 倍、習慣プレイを EXP 主収入化)。
    # Easy=30 / Normal=45 / Hard=60 / Legendary=150 (DIFFICULTY_MULTIPLIER で倍率乗算)。
    # バトル EXP は × 0.3 に削減 (BattleFinishView) で補助的報酬化。
    EXP_PER_COUNT             = 30     # 基本EXP（Easy難易度）
    GOLD_PER_COUNT            = 10     # 基本ゴールド

    # 【FEAT-497 (2026-08-04)】出陣チケット (battle_charges) の在庫上限。
    #
    # 習慣達成で +1 する経路 (habit_count_service) と、交換ピースで +5 する経路
    # (shop.py の piece_battle_charge) の**両方**が同じ上限を見る必要がある。
    # 元は habit_count_service.py に `< 30` のリテラルが直書きされていたので、
    # 2 つ目の加算経路を足すにあたりここへ引き上げた。
    #
    # 数値根拠: DAILY_BATTLE_LIMIT=10 + 本上限 30 で構造的にファーミング不可
    # (3 charges で 1 戦なので、満タンでも 10 戦分)。
    BATTLE_CHARGES_MAX        = 30

    # 【FEAT-334 (2026-05-27)】legendary multiplier 3.0 → 5.0 に増額
    # (20 × 5 = 100 EXP / 達成、+67%)。FEAT-334 スロット制 (6 軸 Lv 5 ALL で +1)
    # で「育成コストに見合う報酬」感を確保。CharacterStat → 高難度習慣解禁の
    # 連動線が完成し、FEAT-333 (stat → バトル能力) と対称な「習慣達成が
    # 世界を動かす」コア哲学のメカニクス化を完結。
    DIFFICULTY_MULTIPLIER = {
        'easy':      1.0,
        'normal':    1.5,
        'hard':      2.0,
        'legendary': 5.0,
    }

    # 【FEAT-334 (2026-05-27)】LEGENDARY_UNLOCK_LEVEL = 20 撤廃。
    # 旧 Lv 20 ゲートは「習慣達成 → Player Lv」「習慣達成 → stat → ご褒美」の
    # 2 経路を並走させる UX 上の罠 (Lv 20 未達時に隠れた EXP degrade) だった。
    # FEAT-334 で導入する「6 軸 Lv 5 ALL でスロット +1」が新ゲートとして
    # 機能 (案 W、ボトルネック方式)、Lv 20 縛りは構造的に不要化されたため撤廃。

    # 【FEAT-319 (2026-05-27)】レベルアップ必要 EXP 計算式の単一真実値。
    # 旧式 `max_exp = level * 100` (Lv1=100, Lv10=1000, Lv20=2000) はユーザー
    # 体感「少し多く感じる」+ 試算 (Normal 1 件/日で Lv 1→10 約 150 日) より
    # 過剰と判明 → `level * 70 + 30` (Lv1=100, Lv10=730, Lv20=1430、約 30% 短縮) に調整。
    # Lv1 初期値 100 は維持して「初期体験」のリズムは保護、以降のカーブを緩やかに。
    # 計算式は `level_to_max_exp(level)` ヘルパーで参照、定数直書きは禁止
    # (habit_count_service.py / battle.py / gacha.py の 3 経路から呼ばれる)。
    EXP_PER_LEVEL_COEFFICIENT = 70     # max_exp の係数 (level に乗算)
    EXP_PER_LEVEL_BASE        = 30     # max_exp の base (level=1 で結果 100)

    @classmethod
    def level_to_max_exp(cls, level: int) -> int:
        """レベル → そのレベルでの max_exp (累計でなく単一レベル分)。

        Lv1 → 100 / Lv10 → 730 / Lv20 → 1430 (旧式 level*100 比で約 30% 短縮)。
        単一真実値 = 本メソッドのみ。直接 level * 100 を書かない。
        """
        return level * cls.EXP_PER_LEVEL_COEFFICIENT + cls.EXP_PER_LEVEL_BASE

    # 【FEAT-285】レベルアップ時に付与する手動配分ポイント（経路別）。
    # CLAUDE.md「経路別の意図的な傾斜」哲学に従い、コアループ（習慣）を厚く、
    # 副次収入（タイムライン / ガチャ）を軽めに設計。
    ALLOCATABLE_POINTS_HABIT     = 10  # 習慣 / ToDo / チェックリスト
    ALLOCATABLE_POINTS_TIMELINE  = 3   # タイムライン予定の完了
    ALLOCATABLE_POINTS_GACHA_EXP = 3   # ガチャ報酬で EXP 獲得時のレベルアップ
    ALLOCATABLE_POINTS_CHALLENGE_EXP = 3  # 【FEAT-465】チャレンジ報酬で EXP 獲得時のレベルアップ

    # 【FEAT-465 (2026-06-24)】月次カテゴリチャレンジ: 1 ユーザー 1 日 1 回までの
    # 進捗加算ガード。将来 v1.1+ で緩和する場合はこの定数のみ変更すればよい (Q2)。
    CHALLENGE_DAILY_CONTRIBUTION_LIMIT = 1

    # 【FEAT-466 (2026-06-24)】月次カテゴリチャレンジ Ver1.1: 3 段階報酬 EXP の
    # デフォルト値 (Challenge.reward_exp_bronze/silver/gold の model default に使用)。
    # admin が個別チャレンジで上書き可能、将来の一括調整はこの定数のみ変更すればよい。
    CHALLENGE_REWARD_EXP_BRONZE_DEFAULT = 100
    CHALLENGE_REWARD_EXP_SILVER_DEFAULT = 300
    CHALLENGE_REWARD_EXP_GOLD_DEFAULT = 1000

    # ステータス名（CharacterStat）
    # 【FEAT-233】順序を `PlayerStatsView._STAT_ORDER` と統一（健康 ⇄ 精神を入れ替え）。
    # `create_default_stats` 等で参照される作成順序にも影響するが、`pk` が変わるだけで
    # 意味的な差異はない。機能レビュー 20260518 P3-2（BUG-66）を本 FEAT で吸収。
    STAT_NAMES = ['運動力', '学習力', '健康力', '精神力', '創造力', '貢献力']

    # 【FEAT-213】カテゴリ → 6 ステータス分散マッピング。
    # 値は `[(ステータス名, 比率), ...]` のリスト。比率の合計は 1.0（浮動小数誤差許容）。
    # 全 11 カテゴリが必ず 1 つ以上のステータスにマップされるため、FEAT-201 が
    # 解消したサイレント喪失バグは再発しない。FEAT-171 で予約された創造力・貢献力も
    # カテゴリ経由で増分するようになり、FEAT-171 が真に完成する位置付け。
    # 既存 4 値データ（運動 / 学習 / 健康 / メンタル）は:
    #   - '運動' → そのまま運動力 1.0（挙動不変）
    #   - '学習' → 学習力 0.5 + 創造力 0.5（新マッピング、創造力にも EXP が入る）
    #   - '健康' → そのまま健康力 1.0（挙動不変）
    #   - 'メンタル' → マイグレーション 0066 で '精神' に変換 → 精神力 1.0
    CATEGORY_STAT_MAP: dict = {
        # 運動系
        '運動':   [('運動力', 1.0)],
        '体力':   [('運動力', 0.5), ('健康力', 0.5)],
        '美容':   [('健康力', 1.0)],
        # 学習系
        '学習':   [('学習力', 0.5), ('創造力', 0.5)],
        '仕事':   [('学習力', 0.5), ('貢献力', 0.5)],
        '創造':   [('創造力', 1.0)],
        # 健康系
        '健康':   [('健康力', 1.0)],
        '休息':   [('健康力', 0.5), ('精神力', 0.5)],
        # 精神系
        '精神':   [('精神力', 1.0)],
        '社交':   [('貢献力', 1.0)],
        # その他 — 6 ステータス均等分散
        'その他': [
            ('運動力', 1 / 6), ('学習力', 1 / 6), ('健康力', 1 / 6),
            ('精神力', 1 / 6), ('創造力', 1 / 6), ('貢献力', 1 / 6),
        ],
    }

    # 【FEAT-379 (2026-05-29)】ステータス結晶: CATEGORY_STAT_MAP 英語キーと完全整合。
    # Gemini 提案の 3 軸 (str/int/luc) は Sabiowl 6 軸決定 (PM セッション 2026-05-29) により不採用。
    # `STAT_NAME_TO_CRYSTAL_FIELD`: stat.name (日本語) → PlayerProfile の結晶カウンターフィールド名
    # `STAT_NAME_TO_CRYSTAL_KEY`:   stat.name (日本語) → 英語キー (crystals dict / Flutter 向け)
    STAT_NAME_TO_CRYSTAL_FIELD: dict = {
        '運動力': 'exercise_crystal_count',
        '学習力': 'learning_crystal_count',
        '健康力': 'health_crystal_count',
        '精神力': 'mental_crystal_count',
        '創造力': 'creation_crystal_count',
        '貢献力': 'contribution_crystal_count',
    }
    STAT_NAME_TO_CRYSTAL_KEY: dict = {
        '運動力': 'exercise',
        '学習力': 'learning',
        '健康力': 'health',
        '精神力': 'mental',
        '創造力': 'creation',
        '貢献力': 'contribution',
    }

    # キャラクターモード
    MODE_TRAINING  = 'training'
    MODE_ADVENTURE = 'adventure'

    # 【FEAT-285】冒険モードの EXP 加算率（base に対する additive bonus）。
    # 旧 `ADVENTURE_EXP_MULTIPLIER = 1.2` は名称が乗算倍率を示唆するが、
    # 実装は `bonus_exp += round(exp_gain * 0.20)` の加算であり、semantic を一致させた。
    ADVENTURE_EXP_BONUS_RATE = 0.20

    # 【FEAT-495 (2026-07-25)】旧 BATTLE_EXP_MULTIPLIER = 0.3 は撤廃。
    # FEAT-406 の × 0.3 削減率は migration 0187 で Enemy.reward_exp に bake-in 済。
    # 以降 code は enemy.reward_exp を直接使う (DB 値 = 表示値 = 実獲得値)。


# ──────────────────────────────────────────────────────────────────────────────
# 【FEAT-379 (2026-05-29)】ステータス結晶の choices (PlayerWeapon ソケット装着種別)
# CATEGORY_STAT_MAP 英語キーと完全整合 (Gemini 3 軸案は不採用)
# ──────────────────────────────────────────────────────────────────────────────

CRYSTAL_TYPE_CHOICES = [
    ('exercise',     '運動の結晶'),
    ('learning',     '学習の結晶'),
    ('health',       '健康の結晶'),
    ('mental',       '精神の結晶'),
    ('creation',     '創造の結晶'),
    ('contribution', '貢献の結晶'),
]

# ──────────────────────────────────────────────────────────────────────────────
# ガチャ
# ──────────────────────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────────────
# 【FEAT-398 (2026-05-31)】日次スロットル定数。
# 友人フィードバック「ファーミング防止 + アプリ価値維持」採択 (PM 案 X-2/X-3)。
# リリース後 PostHog で「閾値到達率 / 継続率」を計測、Backend constants 変更のみで hotfix 対応可能。
# ──────────────────────────────────────────────────────────────────────────────

DAILY_EXP_THROTTLE_LIMIT  = 25  # 件 / 日 / 経路 1-2 合算 (習慣 + ToDo + タイムライン予定)
DAILY_EXP_THROTTLED_VALUE = 1   # 閾値到達後の EXP / 配分 pt 固定値 (健全な最小単位)
DAILY_BATTLE_LIMIT        = 10  # 出陣回数 / 日 (超過時 BattleStartView で 403 拒否)


# ──────────────────────────────────────────────────────────────────────────────
# 【FEAT-429 (2026-06-12)】Shop 累進価格 (クエスト枠拡張)
# N 回目 (0-indexed) の購入価格 = (N + 1) * SHOP_PROGRESSIVE_PRICE_BASE
# 1 回目=200 / 2 回目=400 / 3 回目=600 / 4 回目=800 / 5 回目=1000 (合計 3000)
# 上限 +5 (SHOP_PROGRESSIVE_MAX_COUNT)。
# 【FEAT-434 (2026-06-14)】旧 Legendary 枠拡張 (legendary_slot_expand) は廃止、
# 本累進価格ヘルパーは daily_quest_slot_expand 専用。
# ──────────────────────────────────────────────────────────────────────────────

SHOP_PROGRESSIVE_PRICE_BASE = 200
SHOP_PROGRESSIVE_MAX_COUNT  = 5


def calc_progressive_price(purchase_count: int) -> int:
    """購入回数 (0-indexed) から次回購入価格を算出する。"""
    return (purchase_count + 1) * SHOP_PROGRESSIVE_PRICE_BASE


class GachaBalance:
    # 【20260729 user feedback (silent loss 実質ゼロ化)】
    # 旧値 (Daily 5 / Weekly 4 / Monthly 3、BUG-62 実装時の arbitrary spec) は
    # user が「5 枚溜まった状態で日付跨ぐと明日分の daily チケットが黙って消える」
    # 体験を報告 → mental model「7 日 = 1 週間分」「30 日 = 1 ヶ月分」の cap を
    # 提案。以下を採用:
    #   - DAILY 5 → 30: 「1 ヶ月使わなくても失わない」= Sabi 哲学「無理せず」と整合。
    #     Daily gacha は character 排出なし (Weekly 0.5% + Monthly 100% + Shop 6000💎
    #     の 3 経路のみ) のため、cap 引き上げが character 経済に影響しない。
    #   - WEEKLY 4 → 10: 「~2.5 ヶ月分」溜められる。Weekly は SSR キャラ 0.5% 排出、
    #     +6 枚で期待値 +3% 増だが Monthly 100% + Shop 経路との対比で軽微。
    #   - MONTHLY 3 → 据置: 21 日達成 → 1/月配布 (FEAT-433)、cap 3 で「3 ヶ月分」
    #     既に十分余裕あり。
    # 併せて gacha.py で just_reached_max フラグを返し、Mobile 側で「満タン到達
    # おめでとう SnackBar」を発火 (案 C)。
    DAILY_TICKET_MAX    = 30
    WEEKLY_TICKET_MAX   = 10
    MONTHLY_TICKET_MAX  = 3

    # 天井（このカウントに達したら SR+ / SSR 確定）
    DAILY_PITY_LIMIT    = 49    # 50回目で SR+ 確定
    WEEKLY_PITY_LIMIT   = 24    # 25回目で SR+ 確定
    MONTHLY_PITY_LIMIT  = 9     # 10回目で SSR 確定

    # チケット種別
    TICKET_DAILY   = 'daily'
    TICKET_WEEKLY  = 'weekly'
    TICKET_MONTHLY = 'monthly'

    # レアリティ
    RARITY_N   = 'N'
    RARITY_R   = 'R'
    RARITY_SR  = 'SR'
    RARITY_SSR = 'SSR'


# ──────────────────────────────────────────────────────────────────────────────
# フレンド・ソーシャル
# ──────────────────────────────────────────────────────────────────────────────

class FriendStatus:
    PENDING  = 'pending'
    ACCEPTED = 'accepted'
    BLOCKED  = 'blocked'


# ──────────────────────────────────────────────────────────────────────────────
# 通知
#   ※【FEAT-285】NotifType クラス（ACHIEVEMENT/QUEST/FRIEND/GIFT/SYSTEM）は
#   import 0 件の死定数だったため削除。Notification.notif_type は
#   `Notification.TYPE_CHOICES` を真実値とし、各 view で文字列リテラル直書きする。
#   QUEST は FEAT-284 で choices から削除済（migration 0080）。
# ──────────────────────────────────────────────────────────────────────────────


# 【廃止 (2026-06-26)】 称号 (TITLES) 6 段階システムは実績 (Achievement) 30 件
# 拡張 (FEAT-Z) で機能重複したため完全撤去。`diamonds_total` 閾値ベースの
# title 階梯 (sprout/swordsman/warrior/legend/sage/myth) は、Achievement の
# level_reached / total_logs などの個別 milestone で十分カバーされる。
#
# 削除されたもの: TITLES list / current_title() helper / TitlesView /
# /api/player/titles/ endpoint / TitlesPage (Mobile) / Title/TitlesData models。
#
# award_diamond_for_title_acquired() (diamond_service.py) は名称に「title」
# を含むが実体は **Achievement unlock 時の +20 ダイヤ祝福ボーナス** のため保持。
# 関数名は将来 award_diamond_for_achievement_unlocked に rename 検討余地あり。


# ──────────────────────────────────────────────────────────────────────────────
# IAP ダイヤパック (FEAT-436、v1.0.1 hot fix、iOS 先行)
#   - Mobile / RevenueCat の Package identifier と一致必須
#   - Apple Tier 整合: 120 円 = Tier 1、600 円 = Tier 6、1200 円 = Tier 12
#   - Backend は webhook 受信時に product_id でこの定数を参照、ダイヤ加算
#   - 真実値: 本定数 + RevenueCat ダッシュボードの Offering "default"
# ──────────────────────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────────────
# 【FEAT-511 Phase A (v1.1、2026-07-30)】ジョブ熟練度定数
# ──────────────────────────────────────────────────────────────────────────────

JOB_MASTERY_MAX_LEVEL           = 10   # Lv 上限
JOB_MASTERY_EXP_PER_BATTLE_WIN  = 5    # zako base、Enemy.tier 倍率で修飾
JOB_MASTERY_EXP_PER_BATTLE_LOSS = 1    # 敗北時 EXP (装着体験の微 EXP)

# Enemy.tier 別倍率 (job_mastery_v1_1.md §S1 farming 対策)
JOB_MASTERY_TIER_MULTIPLIER = {
    'zako':         1.0,
    'mid_boss':     1.5,
    'boss':         2.5,
    'hidden_boss':  4.0,
}


def calc_job_mastery_exp_to_next(level: int) -> int:
    """Lv N → Lv N+1 に必要な EXP (指数曲線)。

    Lv 1→2: 10 EXP (~2 戦勝利)
    Lv 5→6: 50 EXP (~10 戦勝利)
    Lv 9→10: 200 EXP (~40 戦勝利、Max 直前に達成感重み)
    """
    return level * level * 2 + level * 4 + 4


IAP_PRODUCTS = {
    'diamond_pack_120': {
        'diamonds':  120,
        'price_jpy': 120,
        'label':     'ダイヤ 120 個',
    },
    'diamond_pack_660': {
        'diamonds':  660,
        'price_jpy': 600,
        'label':     'ダイヤ 660 個 (10% お得)',
        'bonus_pct': 10,
    },
    # 【新規 (2026-06-25)】1200 円 / 1440 個 (+20% ボーナス) 枠。
    # 単価 1200 ÷ 1440 = 約 0.833 円/ダイヤ (660 パックの 0.91 円より得な階梯)。
    # キャラ 6000 ダイヤ購入 (CLAUDE.md「ガチャ Shop」§) を 4 回購入で到達可能、
    # 660 パック × 9 (5400 円) より 660 パック × 1 + 1440 パック × 3 (3600+1200=
    # 4800 円) のほうが安い構成を実現する。
    'diamond_pack_1440': {
        'diamonds':  1440,
        'price_jpy': 1200,
        'label':     'ダイヤ 1440 個 (20% お得)',
        'bonus_pct': 20,
    },
}

