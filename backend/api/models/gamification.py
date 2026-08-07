from django.db import models

from .player import PlayerProfile


class Character(models.Model):
    """選択可能なキャラクター定義"""

    key          = models.CharField(max_length=50, unique=True, verbose_name='キー')
    name         = models.CharField(max_length=50, verbose_name='名前')
    # 【FEAT-489 Phase 4】英語版 name / role / tagline / description。空欄 = ja に silent fallback。
    name_en      = models.CharField(max_length=50, blank=True, default='', verbose_name='名前(英語版)')
    role         = models.CharField(max_length=50, verbose_name='役職')
    role_en      = models.CharField(max_length=50, blank=True, default='', verbose_name='役職(英語版)')
    description  = models.TextField(blank=True, default='', verbose_name='説明文')
    description_en = models.TextField(blank=True, default='', verbose_name='説明文(英語版)')
    # 【2026-06-27】キャッチコピー (新キャラ追加機能、Gemini 要件)。
    # キャラ詳細シート / 紹介ポップアップで role の下に小さく表示する。
    # 既存キャラは空文字 default のまま、運営が admin で追記。
    tagline      = models.CharField(
        max_length=80,
        blank=True,
        default='',
        verbose_name='キャッチコピー',
        help_text='例: 「静かな航路を共に行く者」 — 詳細シート / 紹介 popup で表示',
    )
    tagline_en   = models.CharField(max_length=80, blank=True, default='', verbose_name='キャッチコピー(英語版)')
    image_path   = models.CharField(
        max_length=100,
        verbose_name='画像パス',
        help_text='識別子のみ（例: normal_1, archer）。Flutter は assets/images/characters/character_{identifier}.png に解決する。',
    )
    # 【2026-06-27】公開日 (新キャラ追加機能、Gemini 要件)。
    # release_date が直近 N 日以内 + release_date <= 今日 のとき Mobile 側で
    # 「NEW」バッジを表示する。null = 既存キャラ (NEW 扱いしない)。
    # CharacterSerializer.get_is_new() で is_new フラグを計算して返す。
    release_date = models.DateField(
        null=True,
        blank=True,
        verbose_name='公開日',
        help_text='null = 既存キャラ。設定日 (≤ 今日) から 30 日間は NEW バッジ表示',
    )
    price        = models.IntegerField(default=1500, verbose_name='購入価格（ゴールド）')
    unlock_level = models.IntegerField(default=1, verbose_name='解放レベル')
    is_starter   = models.BooleanField(default=False, verbose_name='初期選択可能')
    # 【2026-06-27】公開フラグ (運営による段階リリース運用)。
    # False = 非公開 (キャラ一覧 / ガチャ / 購入経路から完全除外)。
    # True  = 公開 (通常通り利用可能)。
    # starter キャラ (is_starter=True) は CharacterListView 側で本フラグに関わらず
    # 強制表示してオンボーディング破壊を防ぐ (admin 誤操作対策)。
    # 初回リリース: sol/aria (starter) + rune/lucia/beatrix/faye の 6 体を公開、
    # 残り 8 体は非公開 → 月 1-2 体ずつ admin で True に切替えて段階公開。
    is_published = models.BooleanField(
        default=False,
        verbose_name='公開フラグ',
        help_text='False = 非公開 (一覧 / ガチャ / 購入から除外)。starter は本フラグに関わらず常時公開',
    )
    order        = models.IntegerField(default=0, verbose_name='表示順')
    # 【FEAT-299】ジョブ駆動設計のキャラ → ジョブ紐付け。
    # null 許容（migration 0086 で 8 既存キャラに割り振り、不明 / Sabi フォールバックは
    # Flutter / Backend 側で warrior 既定にフォールバック）。
    # 文字列 FK 'api.Job' で循環 import 回避（battle.py の Job は同 app の別ファイル）。
    job          = models.ForeignKey(
        'api.Job',
        on_delete=models.PROTECT,
        null=True, blank=True,
        related_name='characters',
        verbose_name='ジョブ',
        help_text='FEAT-299: ジョブ駆動設計の修飾子源。null なら Backend が warrior フォールバック',
    )

    class Meta:
        app_label        = 'api'
        verbose_name     = 'キャラクター'
        verbose_name_plural = 'キャラクター'
        ordering         = ['order']

    def __str__(self):
        return f'{self.name}（{self.role}）'


class OwnedCharacter(models.Model):
    """プレイヤーが所持しているキャラクター"""

    player       = models.ForeignKey(PlayerProfile, on_delete=models.CASCADE, related_name='owned_characters', verbose_name='プレイヤー')
    character    = models.ForeignKey(Character,     on_delete=models.CASCADE, related_name='owners',           verbose_name='キャラクター')
    purchased_at = models.DateTimeField(auto_now_add=True, verbose_name='取得日時')

    class Meta:
        app_label        = 'api'
        verbose_name     = '所持キャラクター'
        verbose_name_plural = '所持キャラクター'
        unique_together  = ('player', 'character')

    def __str__(self):
        return f'{self.player.name} → {self.character.name}'


class PlayerItem(models.Model):
    """プレイヤーの所持アイテム"""

    player       = models.ForeignKey(PlayerProfile, on_delete=models.CASCADE, related_name='items', verbose_name='プレイヤー')
    item_id      = models.CharField(max_length=50, verbose_name='アイテムID')
    quantity     = models.IntegerField(default=1, verbose_name='所持数')
    purchased_at = models.DateTimeField(auto_now_add=True, verbose_name='購入日時')

    class Meta:
        app_label        = 'api'
        verbose_name     = '所持アイテム'
        verbose_name_plural = '所持アイテム'
        unique_together  = ('player', 'item_id')

    def __str__(self):
        return f'{self.player.name} - {self.item_id} ×{self.quantity}'
