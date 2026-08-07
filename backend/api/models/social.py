from django.db import models

from .player import PlayerProfile
from ..constants import FriendStatus


class Friendship(models.Model):
    """フレンド関係（申請中 or 承認済み）"""

    STATUS_CHOICES = [
        (FriendStatus.PENDING,  '申請中'),
        (FriendStatus.ACCEPTED, '承認済み'),
    ]

    from_player = models.ForeignKey(PlayerProfile, on_delete=models.CASCADE, related_name='sent_friend_requests',     verbose_name='申請者')
    to_player   = models.ForeignKey(PlayerProfile, on_delete=models.CASCADE, related_name='received_friend_requests', verbose_name='受信者')
    status      = models.CharField(max_length=10, choices=STATUS_CHOICES, default=FriendStatus.PENDING, verbose_name='状態')
    created_at  = models.DateTimeField(auto_now_add=True, verbose_name='作成日時')

    class Meta:
        app_label        = 'api'
        verbose_name     = 'フレンド関係'
        verbose_name_plural = 'フレンド関係'
        unique_together  = ('from_player', 'to_player')

    def __str__(self):
        return f'{self.from_player.name} → {self.to_player.name} ({self.status})'


class Message(models.Model):
    """フレンド間メッセージ（最大40文字）"""

    sender    = models.ForeignKey(PlayerProfile, on_delete=models.CASCADE, related_name='sent_messages',     verbose_name='送信者')
    receiver  = models.ForeignKey(PlayerProfile, on_delete=models.CASCADE, related_name='received_messages', verbose_name='受信者')
    content   = models.CharField(max_length=40, verbose_name='内容')
    created_at = models.DateTimeField(auto_now_add=True, verbose_name='送信日時')

    class Meta:
        app_label        = 'api'
        verbose_name     = 'メッセージ'
        verbose_name_plural = 'メッセージ'
        ordering         = ['created_at']

    def __str__(self):
        return f'{self.sender.name} → {self.receiver.name}: {self.content[:20]}'


class Notification(models.Model):
    """アプリ内通知"""

    # 【FEAT-284 Phase 1】`quest` は SEC-06 で機能廃止済みのため `TYPE_CHOICES` から削除。
    # 既存の `notif_type='quest'` レコードは migration 0080 で `achievement` に
    # backfill されているため、バリデーション失敗は発生しない。
    # `title_unlocked` は Phase 3 で create コードを実装する予定のため残置する
    # （現状はモデル定義のみで、これを put する経路はまだ存在しない）。
    # 【FEAT-446 (2026-06-20)】`message` は FEAT-446 で MessageView 撤去 + UI 廃止に伴い
    # 新規発火経路ゼロのため TYPE_CHOICES から削除。既存 `notif_type='message'` レコードは
    # residual で残置 (Mobile 通知画面で「メッセージ通知」は filter 漏れも tap 経路もなく
    # 表示されない設計、FEAT-250 反省遵守で破壊的データ削除なし)。
    TYPE_CHOICES = [
        ('friend_request',  'フレンド申請'),
        ('friend_accepted', 'フレンド成立'),
        ('level_up',        'レベルアップ'),
        ('streak_alert',    'ストリーク危機'),
        ('title_unlocked',  '称号解除'),
        ('gift',            'ギフト'),
        ('achievement',     '実績解除'),
    ]

    player     = models.ForeignKey(PlayerProfile, on_delete=models.CASCADE, related_name='notifications', verbose_name='受信プレイヤー')
    notif_type = models.CharField(max_length=20, choices=TYPE_CHOICES, verbose_name='通知種別')
    title      = models.CharField(max_length=100, verbose_name='タイトル')
    body       = models.CharField(max_length=200, verbose_name='本文')
    related_id = models.IntegerField(null=True, blank=True, verbose_name='関連ID')
    is_read    = models.BooleanField(default=False, verbose_name='既読')
    created_at = models.DateTimeField(auto_now_add=True, verbose_name='作成日時')

    class Meta:
        app_label        = 'api'
        verbose_name     = '通知'
        verbose_name_plural = '通知'
        ordering         = ['-created_at']

    def __str__(self):
        return f'{self.player.name} — {self.notif_type}: {self.title}'


class Gift(models.Model):
    """フレンド間ギフト履歴。

    【schema 変遷】
      〜 FEAT-451: `diamonds` に贈ったダイヤ数 (1〜3) を保存 (旧: zero-sum ダイヤ transfer)
      FEAT-451 (2026-06-20): `diamonds=0` を「XP ブースト 1 個型 gift」の sentinel として再利用
      【2026-07-09 FEAT-490】: coins_awarded / charges_awarded 2 field 追加、
                              「XP ブースト + コイン + バトルチャージ」3 種セット化。
                              cap 判定 (受け取り側 3 sender/日) で 0 になる可能性あり
                              (XP ブーストは常時付与、これら 2 種のみ cap 対象)。
    """

    sender          = models.ForeignKey(PlayerProfile, on_delete=models.CASCADE, related_name='sent_gifts',     verbose_name='送信者')
    receiver        = models.ForeignKey(PlayerProfile, on_delete=models.CASCADE, related_name='received_gifts', verbose_name='受信者')
    diamonds        = models.IntegerField(verbose_name='贈ったダイヤ数')
    sent_at         = models.DateTimeField(auto_now_add=True, verbose_name='送信日時')
    # 【FEAT-490 (2026-07-09)】cap (3 senders/日) を通過した場合の実付与量。
    # capped 到達で 0、通常 20 coins / 1 charge を記録。residual 既存レコードは default 0
    # (旧 gift は XP boost or diamond のみで coins/charges 経路が存在しなかったため
    # 意味論的に 0 で正しい)。
    coins_awarded   = models.IntegerField(default=0, verbose_name='付与コイン (cap 到達時 0)')
    charges_awarded = models.IntegerField(default=0, verbose_name='付与バトルチャージ (cap 到達時 0)')

    class Meta:
        app_label = 'api'
        ordering  = ['-sent_at']

    def __str__(self):
        return f'{self.sender.name} → {self.receiver.name}: {self.diamonds}💎'
