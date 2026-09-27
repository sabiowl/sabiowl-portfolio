"""認証関連モデル。

FEAT-178 で Magic Link / メール連携を完全廃止したため、本モジュールには
SocialAccount のみが残る（旧 MagicLinkToken / SocialPendingMerge は migration 0061 で drop 済み）。

FEAT-187 でゲスト基盤サーバー化に伴い GuestSession を追加。
FEAT-189 でゲスト→既存ユーザー衝突時の確認用 GuestPromotePending を追加。
"""
import secrets
from datetime import timedelta

from django.conf import settings
from django.db import models
from django.utils import timezone


def _generate_guest_token():
    """ゲスト用の認証トークンを生成する（URL-safe 40 文字相当）"""
    return secrets.token_urlsafe(30)


class SocialAccount(models.Model):
    """Google / Apple ソーシャル認証とDjangoユーザーの紐付け"""

    PROVIDER_GOOGLE = 'google'
    PROVIDER_APPLE  = 'apple'
    PROVIDER_CHOICES = [
        (PROVIDER_GOOGLE, 'Google'),
        (PROVIDER_APPLE,  'Apple'),
    ]

    user         = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='social_accounts',
        verbose_name='ユーザー',
    )
    provider     = models.CharField(
        max_length=10, choices=PROVIDER_CHOICES, verbose_name='プロバイダー'
    )
    provider_uid = models.CharField(
        max_length=128, unique=True, verbose_name='プロバイダーUID'
    )
    email        = models.EmailField(blank=True, verbose_name='メールアドレス')
    created_at   = models.DateTimeField(auto_now_add=True, verbose_name='登録日時')

    class Meta:
        app_label        = 'api'
        verbose_name     = 'ソーシャルアカウント'
        verbose_name_plural = 'ソーシャルアカウント'
        indexes          = [models.Index(fields=['provider', 'provider_uid'])]

    def __str__(self):
        return f'{self.user.email} via {self.provider}'


class GuestSession(models.Model):
    """ゲストモードのセッション（FEAT-187）。

    アプリ起動時に POST /api/auth/guest-init/ で発行される。
    `PlayerProfile.user = null` の player_profile を 1 つ持ち、ゲスト時の
    全データ（習慣・タイムライン・ガチャ・キャラ等）は通常通り PlayerProfile
    に紐づく形で保存される。

    正式登録時に SocialAuthView で player_profile.user に認証済み User を
    紐付けて昇格し、本セッションは削除される（FEAT-189）。
    """

    token = models.CharField(
        max_length=64,
        unique=True,
        default=_generate_guest_token,
        verbose_name='ゲストトークン',
    )
    player_profile = models.OneToOneField(
        'api.PlayerProfile',
        on_delete=models.CASCADE,
        related_name='guest_session',
        verbose_name='プレイヤープロフィール',
    )
    created_at     = models.DateTimeField(auto_now_add=True, verbose_name='作成日時')
    last_active_at = models.DateTimeField(auto_now=True, verbose_name='最終アクティブ')

    class Meta:
        app_label    = 'api'
        verbose_name = 'ゲストセッション'
        verbose_name_plural = 'ゲストセッション'
        indexes = [
            models.Index(fields=['last_active_at']),  # 自動削除バッチ用
        ]

    def __str__(self):
        return f'GuestSession({self.player_profile.name})'


class GuestPromotePending(models.Model):
    """ゲスト → 既存ユーザー衝突時の確認待ちトークン（FEAT-189）。

    Flutter で「ゲストデータを破棄して既存アカウントに切り替えますか?」の
    確認ダイアログを表示する間、サーバー側で次の昇格処理に必要な情報を保持する。
    10 分で自動失効。
    """

    token = models.CharField(
        max_length=64,
        unique=True,
        default=_generate_guest_token,
        verbose_name='確認トークン',
    )
    guest_session = models.OneToOneField(
        'api.GuestSession',
        on_delete=models.CASCADE,
        related_name='promote_pending',
        verbose_name='ゲストセッション',
    )
    target_user   = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='guest_promote_pendings',
        verbose_name='切替先ユーザー',
    )
    created_at    = models.DateTimeField(auto_now_add=True)
    expires_at    = models.DateTimeField(verbose_name='有効期限')

    class Meta:
        app_label    = 'api'
        verbose_name = 'ゲスト昇格確認保留'
        verbose_name_plural = 'ゲスト昇格確認保留'

    def save(self, *args, **kwargs):
        if not self.expires_at:
            self.expires_at = timezone.now() + timedelta(minutes=10)
        super().save(*args, **kwargs)

    @property
    def is_expired(self):
        return timezone.now() >= self.expires_at

    def __str__(self):
        return f'GuestPromotePending → {self.target_user_id}'


class AccountSuspensionLog(models.Model):
    """【FEAT-541 (2026-09-06)】`User.is_active` の切替履歴。

    🔴 **これは履歴であって、状態の真実値ではない。**
    停止しているかどうかの真実値は `User.is_active` **単独**である ——
    認証がそれを見ており、admin にチェックボックスがあり、Django admin への
    ログインも塞ぐ。2 つ目のフラグを作ると**必ず食い違う**。

    ## なぜ履歴が要るか

    🔴 **理由・日時・実行者が残らない ban は運用できない。**
    解除の判断も、問い合わせへの回答もできなくなる。

    ⚠️ **理由が空でも行は作る。** 何も残らないより、
    「いつ誰が」だけでも残るほうが良い。

    ⚠️ `reason` は**運営内部用**で、ユーザーの画面には出さない
    (出すと回避方法を教えることになる)。
    """

    ACTION_CHOICES = [
        ('suspend', '停止'),
        ('lift',    '解除'),
    ]

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='suspension_logs',
        verbose_name='対象ユーザー',
    )
    action = models.CharField(
        max_length=10, choices=ACTION_CHOICES, verbose_name='操作',
    )
    reason = models.TextField(
        blank=True, default='', verbose_name='理由 (運営内部用)',
        help_text='ユーザーの画面には表示されません。解除判断と問い合わせ回答のための記録です。',
    )
    performed_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True, blank=True,
        on_delete=models.SET_NULL,
        related_name='+',
        verbose_name='実行者',
    )
    created_at = models.DateTimeField(auto_now_add=True, verbose_name='日時')

    class Meta:
        app_label    = 'api'
        verbose_name = 'アカウント停止履歴'
        verbose_name_plural = 'アカウント停止履歴'
        ordering     = ['-created_at']
        indexes      = [models.Index(fields=['user', '-created_at'])]

    def __str__(self):
        return f'{self.user_id} {self.get_action_display()} @ {self.created_at:%Y-%m-%d}'

