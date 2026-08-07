"""【FEAT-478 Phase 2 最終 (2026-07-06)】PlayerProfile 4 分割の State モデル。

arch_review 20260702 §優先度トップ10 #10 で「PlayerProfile 30+ field 肥大 +
責務混在」を指摘。段階的に PlayerProfile → 4 モデルへ分離。

  PlayerProfile (基本、user/name/friend_id/gender/created_at/active_character/active_job)
  ├── PlayerEconomyState (経済系: diamonds / coins / character_exchange_tickets 等)
  ├── PlayerBattleState  (バトル系: level / exp / battle_charges 等)
  ├── PlayerStreakState  (ストリーク系: streak / login / daily counters)
  └── PlayerSettings     (設定系: all_private / week_start_day 等)

本ファイルは Phase 2a の Migration 0169 (CreateModel × 4) 後、Phase 2 最終仕上げで
`models/player.py` から切出したもの。app_label='api' 継続、Migration state は不変
(Django は class Meta.app_label で判定するため、ファイル物理位置は無関係)。
Migration 0170-0173 (Phase 2d、PlayerProfile 側の RemoveField) と併せて完全分離達成。
"""
from django.db import models


class PlayerEconomyState(models.Model):
    """【FEAT-478 Phase 2】プレイヤー経済状態 (diamonds / coins / tickets / streak protection)。

    PlayerProfile と OneToOne (primary_key)。Phase 2d の Migration 0170 で
    PlayerProfile 側の該当 field を全削除済 (proxy @property 経由アクセスに一本化)。
    """
    player = models.OneToOneField(
        'PlayerProfile',
        on_delete=models.CASCADE,
        primary_key=True,
        related_name='economy_state',
        verbose_name='プレイヤー',
    )
    # 経済 (現金 / ダイヤ / 消費履歴)
    diamonds       = models.IntegerField(default=0, verbose_name='ダイヤモンド残高')
    diamonds_total = models.IntegerField(default=0, verbose_name='累計獲得ダイヤ')
    bonus_coins    = models.IntegerField(default=0, verbose_name='クエスト報酬コイン')
    coins_spent   = models.IntegerField(default=0, verbose_name='使用コイン合計')
    diamond_bonus_date = models.DateField(
        null=True, blank=True, verbose_name='最終ダイヤボーナス日',
    )
    # チケット (交換券系)
    character_exchange_tickets = models.PositiveIntegerField(
        default=0, verbose_name='キャラ交換券',
    )
    # ストリーク保護 (経済系に含める — 購入 = ダイヤ消費、消費 = 在庫減、経済連動)
    streak_protection_count = models.IntegerField(
        default=0, verbose_name='ストリーク保護 在庫',
    )
    streak_protection_auto_enabled = models.BooleanField(
        default=False, verbose_name='自動保護 ON/OFF',
    )
    streak_protection_pending = models.BooleanField(
        default=False, verbose_name='ストリーク保護 予約中',
    )
    last_streak_protection_used_at = models.DateField(
        null=True, blank=True, verbose_name='直近保護発動日',
    )
    # XP boost (アイテム使用状態、経済連動)
    xp_boost_active_until = models.DateTimeField(
        null=True, blank=True, verbose_name='XPブースト有効期限',
    )

    class Meta:
        app_label = 'api'
        verbose_name = 'プレイヤー経済状態'
        verbose_name_plural = 'プレイヤー経済状態'

    def __str__(self):
        return f'{self.player.name} — 💎 {self.diamonds}'


class PlayerBattleState(models.Model):
    """【FEAT-478 Phase 2】プレイヤーバトル状態 (level / exp / battle_charges 等)。"""
    player = models.OneToOneField(
        'PlayerProfile',
        on_delete=models.CASCADE,
        primary_key=True,
        related_name='battle_state',
        verbose_name='プレイヤー',
    )
    # レベル / EXP
    level              = models.IntegerField(default=1, verbose_name='レベル')
    current_exp        = models.IntegerField(default=0, verbose_name='現在EXP')
    max_exp            = models.IntegerField(default=100, verbose_name='最大EXP')
    allocatable_points = models.IntegerField(default=0, verbose_name='割り振りポイント')
    # バトル出陣チャージ
    battle_charges = models.IntegerField(
        default=0,
        help_text='FEAT-295/406/410: 出陣チケット、3 で 1 戦、上限 30 = 10 戦分、日次リセット',
    )
    battle_charges_date = models.DateField(
        null=True, blank=True, verbose_name='バトルチャージ最終リセット日',
    )
    # 日次スロットル
    daily_exp_count      = models.IntegerField(default=0, verbose_name='本日 EXP 獲得回数')
    daily_exp_count_date = models.DateField(
        null=True, blank=True, verbose_name='本日 EXP カウントの起点日',
    )
    daily_battle_count      = models.IntegerField(default=0, verbose_name='本日のバトル出陣回数')
    daily_battle_count_date = models.DateField(
        null=True, blank=True, verbose_name='本日バトルカウントの起点日',
    )
    # クエスト枠 (FEAT-429 累進価格)
    daily_battle_limit_bonus = models.PositiveIntegerField(
        default=0, verbose_name='クエスト受注枠 ボーナス',
    )
    daily_battle_limit_purchase_count = models.PositiveIntegerField(
        default=0, verbose_name='クエスト枠拡張 累計購入回数',
    )

    class Meta:
        app_label = 'api'
        verbose_name = 'プレイヤーバトル状態'
        verbose_name_plural = 'プレイヤーバトル状態'

    def __str__(self):
        return f'{self.player.name} — Lv.{self.level}'


class PlayerStreakState(models.Model):
    """【FEAT-478 Phase 2】プレイヤーストリーク / 日次カウンタ状態。"""
    player = models.OneToOneField(
        'PlayerProfile',
        on_delete=models.CASCADE,
        primary_key=True,
        related_name='streak_state',
        verbose_name='プレイヤー',
    )
    # ダイヤ付与冪等性
    last_battle_diamond_at  = models.DateField(
        null=True, blank=True, verbose_name='最終バトル勝利ダイヤ付与日',
    )
    last_streak_diamond_day = models.IntegerField(
        default=0, verbose_name='最終ストリークダイヤ付与 streak 日',
    )
    # ログインストリーク (FEAT-331)
    last_login_diamond_at = models.DateField(
        null=True, blank=True, verbose_name='最終ログインダイヤ付与日',
    )
    login_streak_days = models.IntegerField(
        default=0, verbose_name='連続ログイン日数',
    )
    # フレンドプレゼント popup 判定 (FEAT-452)
    daily_task_count = models.IntegerField(
        default=0, verbose_name='当日タスク完了数',
    )
    daily_task_count_date = models.DateField(
        null=True, blank=True, verbose_name='当日タスク完了数 基準日',
    )
    last_friend_gift_popup_date = models.DateField(
        null=True, blank=True, verbose_name='フレンドプレゼント popup 最終表示日',
    )
    # 実績チェックスロットル (P0-3、60 秒)
    last_achievement_check_at = models.DateTimeField(
        null=True, blank=True, verbose_name='最終実績チェック日時',
    )
    # 【FEAT-479】パズル世界システムの日次冪等性フラグ (プレイヤー単位管理)
    # シーン切替による日次上限リセットの悪用を構造的に防ぐ (指示書 §3.2)
    last_task_piece_date  = models.DateField(
        null=True, blank=True, verbose_name='最終 task piece 付与日',
    )
    last_quest_piece_date = models.DateField(
        null=True, blank=True, verbose_name='最終 quest piece 付与日',
    )

    class Meta:
        app_label = 'api'
        verbose_name = 'プレイヤーストリーク状態'
        verbose_name_plural = 'プレイヤーストリーク状態'

    def __str__(self):
        return f'{self.player.name} — login {self.login_streak_days}d'


class PlayerSettings(models.Model):
    """【FEAT-478 Phase 2】プレイヤー設定 (privacy / notifications / week/month reset 等)。"""
    player = models.OneToOneField(
        'PlayerProfile',
        on_delete=models.CASCADE,
        primary_key=True,
        related_name='settings_state',
        verbose_name='プレイヤー',
    )
    # プライバシー
    all_private = models.BooleanField(default=False, verbose_name='全習慣非公開')
    # リセットタイミング
    week_start_day  = models.IntegerField(
        default=0, verbose_name='週起点曜日',
        help_text='0=月, 1=火, 2=水, 3=木, 4=金, 5=土, 6=日',
    )
    month_reset_day = models.IntegerField(
        default=1, verbose_name='月次リセット日', help_text='1〜28',
    )
    # 通知
    fcm_token        = models.TextField(blank=True, default='', verbose_name='FCMトークン')
    reminder_enabled = models.BooleanField(default=False, verbose_name='リマインダー有効')
    reminder_time    = models.TimeField(null=True, blank=True, verbose_name='通知時刻')
    mode = models.CharField(
        max_length=10, default='training', verbose_name='プレイモード',
        help_text='training=鍛錬, adventure=冒険',
    )
    # Google カレンダー連動
    gcal_push_enabled = models.BooleanField(
        default=False,
        help_text='FEAT-257/263: Sabiowl の予定を Google カレンダーに書き出す',
    )
    timeline_uncompleted_reminder_enabled = models.BooleanField(
        default=False,
        help_text='FEAT-273: タイムライン予定の +15 分後未完了通知',
    )
    # 【FEAT-489 Phase 4】優先言語 (ja/en)。I18nMiddleware が request.locale 確定に使用。
    LANGUAGE_CHOICES = [
        ('ja', '日本語'),
        ('en', 'English'),
    ]
    preferred_language = models.CharField(
        max_length=8,
        choices=LANGUAGE_CHOICES,
        default='ja',
        verbose_name='優先言語',
        help_text='FEAT-489 Phase 4 (v1.1)。null 相当時は Accept-Language header → ja default の順で解決。',
    )

    class Meta:
        app_label = 'api'
        verbose_name = 'プレイヤー設定'
        verbose_name_plural = 'プレイヤー設定'

    def __str__(self):
        return f'{self.player.name} — {self.mode}'
