from django.db import models

from .player import PlayerProfile


class GachaReward(models.Model):
    """ガチャ報酬マスターデータ"""

    RARITY_CHOICES = [
        ('N',   'Normal'),
        ('R',   'Rare'),
        ('SR',  'Super Rare'),
        ('SSR', 'Special Super Rare'),
    ]
    REWARD_TYPE_CHOICES = [
        ('exp',       '経験値'),
        ('diamond',   'ダイヤ'),
        ('xp_boost',  'XPブースト'),
        ('title',     '称号'),
        ('character', 'キャラクター'),
        # 【FEAT-326】武器排出 (Daily SR / Weekly SSR、value=0 でランダム選択シグナル)
        ('weapon',    '武器'),
        # 【FEAT-427 (2026-06-11)】マンスリー天井専用、キャラ交換券 (ユーザー選択)
        ('character_ticket', 'キャラ交換券'),
    ]
    CONTAINER_CHOICES = [
        ('chest', '宝箱'),
        ('stone', '召喚石'),
    ]
    TICKET_TYPE_CHOICES = [
        ('daily',   'デイリー'),
        ('weekly',  'ウィークリー'),
        ('monthly', 'マンスリー'),
        # 【FEAT-427 (2026-06-11)】マンスリー天井専用の擬似報酬カテゴリ。
        # SHOP_CATALOG / 通常ガチャの ticket_type とは別枠で、_pick_reward の
        # weight 抽選プールに混入しない (weight=0 固定 + GachaPullView の天井
        # 経路でのみ参照される)。
        ('monthly_pity', 'マンスリー天井'),
    ]

    rarity       = models.CharField(max_length=3,   choices=RARITY_CHOICES,      verbose_name='レアリティ')
    reward_type  = models.CharField(max_length=20,  choices=REWARD_TYPE_CHOICES, verbose_name='報酬種別')
    container    = models.CharField(max_length=10,  choices=CONTAINER_CHOICES,   default='chest', verbose_name='コンテナ')
    ticket_type  = models.CharField(max_length=16,  choices=TICKET_TYPE_CHOICES, default='daily', verbose_name='対応チケット種別')
    name         = models.CharField(max_length=100, verbose_name='報酬名')
    # 【FEAT-516 (2026-08-04)】英語版。空欄なら ja にフォールバックする
    # (`get_i18n_field`)。投入は `translate_master_data` 経由。
    name_en = models.CharField(
        max_length=100,
        blank=True,
        default='',
        verbose_name='報酬名(英語版)',
    )
    detail       = models.CharField(max_length=200, verbose_name='詳細テキスト')
    # 【FEAT-516 (2026-08-04)】英語版。空欄なら ja にフォールバックする
    # (`get_i18n_field`)。投入は `translate_master_data` 経由。
    detail_en = models.CharField(
        max_length=200,
        blank=True,
        default='',
        verbose_name='報酬詳細(英語版)',
    )
    icon         = models.CharField(max_length=10,  default='⭐', verbose_name='アイコン絵文字')
    weight       = models.IntegerField(default=10,  verbose_name='排出ウェイト')
    value        = models.IntegerField(default=0,   verbose_name='数値（EXP量・ダイヤ数など）')
    # 【FEAT-326】reward_type='weapon' のときに WeaponMaster.key を保持。
    # 'weapon' 以外の reward_type では空文字列 (default='') で無視される。
    # value 経由ではなく専用フィールドにする理由: WeaponMaster は AutoField の pk
    # ではなく `key` (例: 'mythril_sword') で参照する設計のため、IntegerField の
    # value では表現できない (Pre-mortem #3 weight 整合性検証も別フィールドのほうが
    # 静的解析しやすい)。
    weapon_key   = models.CharField(
        max_length=32, blank=True, default='',
        verbose_name='武器キー (FEAT-326)',
        help_text='reward_type="weapon" のとき WeaponMaster.key を保持',
    )
    is_active    = models.BooleanField(default=True, verbose_name='有効')

    class Meta:
        app_label        = 'api'
        verbose_name     = 'ガチャ報酬'
        verbose_name_plural = 'ガチャ報酬'
        ordering         = ['rarity', 'id']

    def __str__(self):
        return f'[{self.rarity}] {self.name} — {self.detail}'


class PlayerGachaStatus(models.Model):
    """プレイヤーごとのガチャ状態（チケット・天井）"""

    player                     = models.OneToOneField(PlayerProfile, on_delete=models.CASCADE, related_name='gacha_status', verbose_name='プレイヤー')
    daily_tickets              = models.IntegerField(default=0, verbose_name='デイリーチケット枚数')
    daily_last_granted         = models.DateField(null=True, blank=True, verbose_name='最終デイリー付与日')
    daily_pity                 = models.IntegerField(default=0, verbose_name='デイリー天井カウンター')
    weekly_tickets             = models.IntegerField(default=0, verbose_name='ウィークリーチケット枚数')
    weekly_pity                = models.IntegerField(default=0, verbose_name='ウィークリー天井カウンター')
    weekly_last_granted_week   = models.DateField(null=True, blank=True, verbose_name='最終ウィークリー付与週（月曜日付）')
    monthly_tickets            = models.IntegerField(default=0, verbose_name='マンスリーチケット枚数')
    monthly_pity               = models.IntegerField(default=0, verbose_name='マンスリー天井カウンター')
    monthly_last_granted_month = models.DateField(null=True, blank=True, verbose_name='最終マンスリー付与月（1日付）')

    # 【FEAT-374 (2026-05-29)】ガチャ「もう 1 度」💎 50 機能向けの redo 管理フィールド。
    # 設計: 直近 1 回分の pull を記録し、24h 以内・redo_used=False なら 1 度だけ追加引き直し可能。
    # rollback (前結果取消) ではなく「追加 1 回引き直し」(前結果保持) = race リスク排除。
    # 別ガチャを引くたびに last_pull_* が上書きされ redo_used=False にリセットされる。
    last_pull_id   = models.IntegerField(
        null=True, blank=True,
        verbose_name='直近ガチャ履歴 ID (GachaHistory.pk)',
        # FEAT-374: redo 対象の GachaHistory.pk。null = まだガチャを引いていない
    )
    last_pull_at   = models.DateTimeField(
        null=True, blank=True,
        verbose_name='直近ガチャ日時',
        # FEAT-374: redo 24h 制限の基準時刻
    )
    last_pull_pool = models.CharField(
        max_length=16, null=True, blank=True,
        verbose_name='直近ガチャ種別 (daily / weekly / monthly)',
        # FEAT-374: redo 時に同じ pool を引くために使用
    )
    redo_used      = models.BooleanField(
        default=False,
        verbose_name='redo 使用済みフラグ',
        # FEAT-374: True = 直近のガチャに対して既に引き直し済み
    )

    class Meta:
        app_label        = 'api'
        verbose_name     = 'プレイヤーガチャ状態'
        verbose_name_plural = 'プレイヤーガチャ状態'

    def __str__(self):
        return f'{self.player.name} — チケット:{self.daily_tickets} 天井:{self.daily_pity}'


class GachaHistory(models.Model):
    """ガチャ引き履歴"""

    TICKET_TYPE_CHOICES = [
        ('daily',   'デイリー'),
        ('weekly',  'ウィークリー'),
        ('monthly', 'マンスリー'),
    ]

    player      = models.ForeignKey(PlayerProfile, on_delete=models.CASCADE, related_name='gacha_histories', verbose_name='プレイヤー')
    reward      = models.ForeignKey(GachaReward,   on_delete=models.CASCADE, verbose_name='獲得報酬')
    ticket_type = models.CharField(max_length=10, choices=TICKET_TYPE_CHOICES, default='daily', verbose_name='チケット種別')
    pulled_at   = models.DateTimeField(auto_now_add=True, verbose_name='引いた日時')
    # 【BUG-119 (2026-06-14)】character 型の reward 排出時に具体的キャラを保存。
    # GachaStatusView.history で h.character.name を優先表示し「マンスリーキャラ
    # (SSR)」→「ルーン (SSR)」等の具体的表示を実現する。非 character 型 reward と
    # 既存履歴 (backfill 対象外) は null。on_delete=SET_NULL で履歴の整合性確保。
    character   = models.ForeignKey(
        'api.Character',
        on_delete=models.SET_NULL,
        null=True, blank=True,
        related_name='gacha_histories',
        verbose_name='排出キャラ',
        help_text='character 型の reward 排出時のみ非 null',
    )

    class Meta:
        app_label        = 'api'
        verbose_name     = 'ガチャ履歴'
        verbose_name_plural = 'ガチャ履歴'
        ordering         = ['-pulled_at']

    def __str__(self):
        return f'{self.player.name} — [{self.reward.rarity}] {self.reward.name} ({self.pulled_at:%Y-%m-%d})'


class PendingDuplicateReward(models.Model):
    """月次ガチャ重複報酬（交換待ち）"""

    PENDING_STATUS_CHOICES = [
        ('pending',   '未交換'),
        ('exchanged', '交換済み'),
        ('expired',   '期限切れ'),
    ]
    EXCHANGE_TYPE_CHOICES = [
        ('pieces',      '交換ピース × 100'),
        ('stat_points', 'ステータスポイント × 5'),
    ]

    player        = models.ForeignKey(
        PlayerProfile, on_delete=models.CASCADE, related_name='pending_duplicate_rewards',
        verbose_name='プレイヤー',
    )
    reward        = models.ForeignKey(
        GachaReward, on_delete=models.CASCADE, verbose_name='重複した報酬',
    )
    status        = models.CharField(
        max_length=10, choices=PENDING_STATUS_CHOICES, default='pending', verbose_name='状態',
    )
    exchange_type = models.CharField(
        max_length=15, choices=EXCHANGE_TYPE_CHOICES, blank=True, verbose_name='交換種別',
    )
    expires_at    = models.DateTimeField(verbose_name='有効期限')
    created_at    = models.DateTimeField(auto_now_add=True, verbose_name='作成日時')

    class Meta:
        app_label = 'api'
        ordering  = ['-created_at']
        verbose_name        = '重複報酬待ち'
        verbose_name_plural = '重複報酬待ち'

    def __str__(self):
        return f'{self.player.name} — [{self.reward.rarity}] {self.reward.name} ({self.status})'
