"""【FEAT-295】バトルシステム MVP の Backend モデル。

設計ノート (`doc/design/battle_system.md`) §4.1 を真実値とする。

責務分担（設計ノート §3.1、Sabiowl 流中間案）:
  - Backend: 敵 + 武器マスタ提供 / token 発行 / 結果保存 / 物理的に
    あり得ない結果のチェック（戦闘秒数下限 + ダメージ合計上限）
  - Flutter: ATB タイマー / ダメージ計算 / 4 アビリティ実行 / 演出

**Pre-mortem #2** 対応: 厳密シミュレーション再現は **しない**。`Battle.token` で
セッションを紐付け、`/finish/` で「物理的にあり得ない結果」のみ reject する。
"""
from django.db import models

from .player import PlayerProfile


class Job(models.Model):
    """【FEAT-299】ジョブマスタ（5 種、ジョブ駆動設計の真実値）。

    既存 4 アビリティ（normal / strong / heal / ultimate）はそのまま維持し、
    Combatant の計算式に modifier を掛けることでジョブ別の個性を実装する。

    on_hit_effect:
      - `none`:  効果なし
      - `burn`:  攻撃時に敵 HP に `max_hp × 0.02 × 3` を即時加算（DoT 風、Pre-mortem #3 対応で
                tick 管理不要に簡略化、真の DoT は v1.1+）
      - `heal`:  攻撃時に自分の HP を `damage_dealt × 0.10` 回復（吸収）

    `ult_cost` は「ゲージ満タン保留」回数。Berserker=1（即発動）/ Warrior=Cleric=3（標準）/
    Thief=4（高コスト + 高速）。既存 `BattleConstants.ultimateChargeRequired = 3` の
    定数は Combatant.ultCost の default として残置（Pre-mortem #5 退行回避）。
    """

    ON_HIT_EFFECT_CHOICES = [
        ('none', '効果なし'),
        ('burn', '炎ダメージ (DoT 風)'),
        ('heal', 'HP 吸収'),
    ]

    job_id = models.CharField(
        max_length=32, unique=True,
        help_text="'warrior' / 'mage' / 'thief' / 'cleric' / 'berserker'",
    )
    job_name = models.CharField(max_length=64, help_text='表示名「戦士」等')
    # 【FEAT-489 Phase 2F-a】英語版表示名。空欄 = ja に silent fallback。
    # Phase 4 の `_en` 追加 (Enemy / Character / Announcement / TaskSuggestion) から
    # Job だけ漏れていたのを回収 (migration 0198)。
    job_name_en = models.CharField(
        max_length=64, blank=True, default='', verbose_name='表示名(英語版)',
    )
    atb_speed_modifier = models.FloatField(
        default=1.0,
        help_text='ATB ゲージ充填速度倍率 (0.6=狂戦士 / 1.5=盗賊)',
    )
    attack_power_modifier = models.FloatField(
        default=1.0,
        help_text='攻撃力倍率 (0.7=僧侶 / 1.6=狂戦士)',
    )
    on_hit_effect = models.CharField(
        max_length=32, choices=ON_HIT_EFFECT_CHOICES, default='none',
        help_text='攻撃時の追加効果 (none/burn/heal)',
    )
    ult_cost = models.IntegerField(
        default=3,
        help_text='大技解放に必要なゲージ満タン保留回数 (1=狂戦士 / 4=盗賊)',
    )
    description = models.CharField(
        max_length=200, blank=True, default='',
        help_text='UI 表示用説明（一行）',
    )
    # 【FEAT-516 (2026-08-04)】英語版。空欄なら ja にフォールバックする
    # (`get_i18n_field`)。投入は `translate_master_data` 経由。
    description_en = models.CharField(
        max_length=200,
        blank=True,
        default='',
        verbose_name='ジョブ説明(英語版)',
    )

    class Meta:
        app_label = 'api'
        verbose_name = 'ジョブマスタ'
        verbose_name_plural = 'ジョブマスタ'

    def __str__(self):
        return f'{self.job_name} ({self.job_id})'


class Enemy(models.Model):
    """敵マスタ（MVP は 'goblin' 1 種のみ、Phase 2 で複数追加予定）。

    【FEAT-302】v1.0 追加スコープ δ:
      - `physical_resistance` / `magical_resistance` / `weak_ult_cost` で
        弱点 / 耐性システム導入（ジョブ駆動 FEAT-299 を活かす戦略性）
      - tier に `mid_boss` / `hidden_boss` 追加（段階解放、Lv.15/25/35 解禁）
      - 既存 5 体（goblin/giant_slime/goblin_king/dragon/shadow_mage）は
        default 値で「耐性なし」のまま動作維持（Pre-mortem #5 退行回避）
    """

    TIER_CHOICES = [
        ('zako',        '雑魚'),
        ('mid_boss',    '中ボス'),      # 【FEAT-302】新規（Lv.15 解禁）
        ('boss',        'ボス'),
        ('hidden_boss', '隠しボス'),    # 【FEAT-302】新規（Lv.35 解禁）
    ]

    key = models.CharField(max_length=32, unique=True,
                           help_text="識別子 'goblin' / 'orc' 等")
    name = models.CharField(max_length=64, help_text='表示名「ゴブリン」等')
    # 【FEAT-489 Phase 4】英語版表示名。空欄 = ja に silent fallback。
    name_en = models.CharField(
        max_length=64, blank=True, default='', verbose_name='表示名(英語版)',
    )
    sprite_key = models.CharField(
        max_length=64,
        help_text='Flutter 側 assets/images/battle/<key>.png',
    )
    base_hp = models.IntegerField(
        default=100,
        help_text='戦闘中 HP。Lv 連動しない (FEAT-400 v3)',
    )
    # 【FEAT-522 (2026-08-07)】設定値 = 1 発のダメージ。
    # 旧式 `base_atk * level_scaling * level` では admin の数字から実ダメージが
    # 読めなかった (12 と入れた ice_witch が Lv 25 で 150)。
    base_atk = models.IntegerField(
        default=10,
        help_text='1 発のダメージそのもの (設定値 = 実ダメージ、FEAT-522)',
    )
    base_spd = models.IntegerField(default=10, help_text='ATB 充填速度')
    # 【FEAT-522】既定を 0 (固定) に変更。式は
    # `base_atk * (1 + level_scaling * max(0, level - unlock_level))`。
    # unlock_level 基点なので、0 でなくても「解禁時のダメージ = 設定値」は成立する。
    level_scaling = models.FloatField(
        default=0.0,
        help_text=(
            '0 = 固定 (推奨・全 24 体の既定) / '
            '0 より大きい値は unlock_level 以降だけ緩やかに追随 (FEAT-522)'
        ),
    )
    reward_coins = models.IntegerField(default=10)
    reward_exp = models.IntegerField(default=20)
    tier = models.CharField(max_length=16, choices=TIER_CHOICES, default='zako')

    # 【FEAT-302】物理攻撃 (warrior/berserker/thief = jobName 駆動) のダメージ倍率。
    # 1.0 = 等倍、0.7 = 30% 軽減、1.3 = 30% 増幅。
    physical_resistance = models.FloatField(
        default=1.0,
        help_text='FEAT-302: 物理攻撃ダメージ倍率 (1.0=等倍 / 0.7=30%軽減 / 1.3=30%増幅)',
    )

    # 【FEAT-302】魔法攻撃 (mage burn / cleric heal = jobName 駆動) の効果倍率。
    magical_resistance = models.FloatField(
        default=1.0,
        help_text='FEAT-302: 魔法攻撃 (burn / heal) 効果倍率 (default 1.0)',
    )

    # 【FEAT-302】指定 ult_cost のジョブから受けるダメージが +30% (Critical 表示)。
    # null = 弱点なし。例: ice_witch.weak_ult_cost = 4 → thief (ultCost=4) で +30% ダメージ。
    weak_ult_cost = models.IntegerField(
        null=True, blank=True, default=None,
        help_text='FEAT-302: 弱点 ult_cost (null=弱点なし / 例: 4 で thief 限定で +30%)',
    )

    # 【FEAT-302】解禁レベル。Flutter ギルド画面が player.level < unlock_level なら 🔒 表示。
    # 0 = 解禁条件なし（既存 5 体は default 0 で常時解禁、後方互換）。
    unlock_level = models.IntegerField(
        default=0,
        help_text='FEAT-302: 解禁プレイヤーレベル (0=常時解禁 / 15=mid_boss / 25=boss / 35=hidden_boss)',
    )

    # 【FEAT-381 (2026-05-29)】戦闘画面の背景画像 asset path (Flutter 側)。
    # tier 別汎用 4 枚で運用 (zako/mid_boss/boss/hidden_boss)、Enemy 別 override も可能。
    # 空文字 '' = 背景画像なし (戦闘画面は AppTheme.background 単色フォールバック)。
    # 例: 'assets/images/backgrounds/battle/bg_zako.webp'
    # 画像欠落時は Flutter 側 errorBuilder で単色フォールバックするため Backend は安全。
    # 【FEAT-513 v1.1 hotfix 4 follow-up (2026-07-31、migration 0197)】FEAT-510
    # Phase 1 WebP 変換の DB catch-up 済。新規 seed migration は '.webp' で書くこと。
    background_image_path = models.CharField(
        max_length=128, blank=True, default='',
        help_text='FEAT-381: 戦闘画面背景画像 asset path (空=背景なし)',
    )

    class Meta:
        app_label = 'api'
        verbose_name = '敵マスタ'
        verbose_name_plural = '敵マスタ'

    def __str__(self):
        return f'{self.name} ({self.key})'


class WeaponMaster(models.Model):
    """武器マスタ（MVP: +10 固定値の初期武器 1 種のみ、Phase 2 で拡張）。"""

    TIER_CHOICES = [
        ('starter', 'スターター (オンボーディング配布)'),
        ('normal',  'Normal (バトル 15% ドロップ)'),
        ('rare',    'Rare (バトル 10% ドロップ)'),
        ('shop',    'Shop 購入のみ (ドロップ対象外)'),
    ]

    key = models.CharField(max_length=32, unique=True)
    name = models.CharField(max_length=64)
    # 【FEAT-516 (2026-08-04)】英語版。空欄なら ja にフォールバックする
    # (`get_i18n_field`)。投入は `translate_master_data` 経由。
    name_en = models.CharField(
        max_length=64,
        blank=True,
        default='',
        verbose_name='武器名(英語版)',
    )
    atk_bonus = models.IntegerField(default=10)
    description = models.CharField(max_length=128, blank=True, default='')
    # 【FEAT-516 (2026-08-04)】英語版。空欄なら ja にフォールバックする
    # (`get_i18n_field`)。投入は `translate_master_data` 経由。
    description_en = models.CharField(
        max_length=128,
        blank=True,
        default='',
        verbose_name='武器説明(英語版)',
    )

    # 【FEAT-379 (2026-05-29)】武器ソケット数 (v1.0 は固定値、v1.1+ で Lv 連動化予定)。
    # starter/bronze=1、iron/steel=2、mythril/dragon_slayer=3 (migration 0107 で seed)。
    socket_count = models.IntegerField(default=1)

    # 【FEAT-461 (2026-06-22)】battle.py の _NORMAL_WEAPON_KEYS / _RARE_WEAPON_KEYS
    # ハードコード tuple を撤廃し、master data 経由で動的取得するための tier 分類。
    # 既存 24 武器 (migration 0148/0149 seed) は migration 0153 で 'normal'/'rare' に
    # backfill、starter_sword (migration 0082) は 'starter' に backfill。
    # bronze_sword 等の Shop 専売武器 (migration 0093) は default 'shop' のまま。
    tier = models.CharField(
        max_length=16, choices=TIER_CHOICES, default='shop',
        help_text='FEAT-461: 武器ドロップ tier 分類 (battle.py が動的取得)',
    )

    class Meta:
        app_label = 'api'
        verbose_name = '武器マスタ'
        verbose_name_plural = '武器マスタ'

    def __str__(self):
        return f'{self.name} (+{self.atk_bonus})'


class PlayerWeapon(models.Model):
    """プレイヤーが所持している武器（MVP は 1 人 1 つの想定）。

    オンボーディング完了時に「見習いの剣 (starter_sword)」を自動付与する経路で
    レコードが作成される（FEAT-295 指示書「私が引き取り」セクション）。
    """

    player = models.ForeignKey(
        PlayerProfile, on_delete=models.CASCADE, related_name='weapons',
    )
    weapon = models.ForeignKey(WeaponMaster, on_delete=models.PROTECT)
    is_equipped = models.BooleanField(
        default=True,
        help_text='MVP は 1 人 1 武器のため通常 True、Phase 2 で複数所持に拡張',
    )
    acquired_at = models.DateTimeField(auto_now_add=True)

    # 【FEAT-379 (2026-05-29)】ソケット装着結晶種別 (v1.0 は Null 維持、v1.1+ で装着 UI 解禁)。
    # CRYSTAL_TYPE_CHOICES = [('exercise', ...), ...] は backend/api/constants.py に定義済み。
    socket_1_crystal_type = models.CharField(max_length=32, null=True, blank=True)
    socket_2_crystal_type = models.CharField(max_length=32, null=True, blank=True)
    socket_3_crystal_type = models.CharField(max_length=32, null=True, blank=True)

    class Meta:
        app_label = 'api'
        verbose_name = 'プレイヤー武器'
        verbose_name_plural = 'プレイヤー武器'
        constraints = [
            models.UniqueConstraint(
                fields=['player', 'weapon'],
                name='unique_player_weapon',
            ),
        ]

    def __str__(self):
        return f'{self.player.name} - {self.weapon.name}'


class Battle(models.Model):
    """戦闘セッション（token 発行 + 開始 → /finish/ で検証）。"""

    RESULT_CHOICES = [
        ('win',     '勝利'),
        ('lose',    '敗北'),
        ('abandon', '中断'),
    ]

    player = models.ForeignKey(
        PlayerProfile, on_delete=models.CASCADE, related_name='battles',
    )
    enemy = models.ForeignKey(Enemy, on_delete=models.PROTECT)
    enemy_hp_init = models.IntegerField(
        help_text='戦闘開始時の敵 HP (player.level * level_scaling 適用済)',
    )
    enemy_atk_init = models.IntegerField()
    started_at = models.DateTimeField(auto_now_add=True)
    finished_at = models.DateTimeField(null=True, blank=True, db_index=True)
    result = models.CharField(
        max_length=16, choices=RESULT_CHOICES, null=True, blank=True,
    )
    token = models.CharField(
        max_length=64, unique=True, db_index=True,
        help_text='/finish/ 検証用、32 文字ランダム + 30 分期限',
    )
    # 【FEAT-298】戦闘前に設定された回復薬使用予定数（0-3）。
    # `BattleStartView` で `potions_to_use` パラメータから設定、
    # 戦闘中の実消費数は `potions_used` で別途記録される。
    potions_planned = models.IntegerField(
        default=0,
        help_text='FEAT-298: 戦闘開始前に設定された回復薬使用予定数 (0-3)',
    )
    # 【FEAT-298】戦闘中に実際に使用された回復薬数。
    # `BattleFinishView` で `potions_used <= potions_planned` を検証して保存。
    potions_used = models.IntegerField(
        default=0,
        help_text='FEAT-298: 戦闘中に実際に使用された回復薬数 (履歴)',
    )

    class Meta:
        app_label = 'api'
        verbose_name = '戦闘セッション'
        verbose_name_plural = '戦闘セッション'
        ordering = ['-started_at']

    def __str__(self):
        return f'{self.player.name} vs {self.enemy.name} ({self.result or "in progress"})'


class BattleLog(models.Model):
    """戦闘履歴（リプレイ表示用、最新 N 件保持、MVP では無制限）。"""

    battle = models.OneToOneField(
        Battle, on_delete=models.CASCADE, related_name='log',
    )
    summary_text = models.TextField(
        help_text='Flutter 側で生成 (例: "サビ 通常攻撃 → ゴブリン -15HP\\n...")',
    )
    total_damage_dealt = models.IntegerField(default=0)
    total_damage_taken = models.IntegerField(default=0)
    rounds = models.IntegerField(default=0)
    rewards_coins = models.IntegerField(default=0)
    rewards_exp = models.IntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        app_label = 'api'
        verbose_name = '戦闘ログ'
        verbose_name_plural = '戦闘ログ'
        ordering = ['-created_at']

    def __str__(self):
        return f'Log({self.battle.id}, rounds={self.rounds})'
