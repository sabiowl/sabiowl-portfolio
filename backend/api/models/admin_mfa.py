"""【2026-06-29】Django 管理画面 ログイン強化 (メール OTP MFA)。

設計概要:
    Django 標準の username/password 認証成功後、is_staff ユーザーに対して
    6 桁の OTP コードをメール送信し、コード入力が一致した場合のみ admin
    画面へのアクセスを許可する 2 要素認証の状態管理モデル。

    抽選方式: views/admin_mfa.py で `secrets.randbelow(1_000_000):06d` 生成、
    本モデルに保存 + Resend HTTP API でメール送信 (FEAT-395 と同経路)。
    middleware/admin_mfa.py が session['admin_mfa_verified_at'] を見て gate。

冪等性:
    - 同一 user で active な (used=False かつ created_at が直近 10 分以内) の
      challenge は最大 1 件。新規発行時に既存 active を全 used=True で無効化。
    - User cascade 削除で MFA challenge も連鎖削除 (履歴保持の必要なし、
      session ベース認証のため過去 challenge は debug 用途のみ)。

【Pre-mortem 対策】
    - brute-force ガード: `attempt_count` で 5 回失敗を検出、used=True で無効化
    - 失効ガード: created_at + 10 分で expired 判定 (view 側で実装)
    - 再送 throttle: 同 user で前 challenge から 60 秒以内は新規発行禁止 (view)
"""
from django.contrib.auth import get_user_model
from django.db import models


class AdminMFAChallenge(models.Model):
    """admin 画面ログイン時の OTP チャレンジレコード。

    Lifecycle:
        1. user が admin/login/ で username/password 認証成功
        2. middleware が session の MFA verified 不在を検知 → views.admin_mfa_challenge へ redirect
        3. view が AdminMFAChallenge.objects.create(user, code) でレコード生成
        4. view が Resend HTTP API で code をメール送信
        5. user が verify ページで code 入力 → view が code 一致 + 期限内 + 未使用を確認
        6. 一致 → used=True + session['admin_mfa_verified_at'] = now → /admin/ へ
    """

    user = models.ForeignKey(
        get_user_model(),
        on_delete=models.CASCADE,
        related_name='mfa_challenges',
        verbose_name='ユーザー',
    )
    code = models.CharField(
        max_length=6,
        verbose_name='OTP コード (6 桁)',
        help_text='secrets.randbelow(1_000_000):06d で生成',
    )
    created_at = models.DateTimeField(
        auto_now_add=True,
        verbose_name='発行日時',
    )
    used = models.BooleanField(
        default=False,
        verbose_name='使用済 / 無効化',
        help_text='True = 既に検証成功 or 上限到達 or 新規発行で無効化された',
    )
    attempt_count = models.IntegerField(
        default=0,
        verbose_name='試行回数',
        help_text='brute-force ガード用、5 回失敗で used=True',
    )

    class Meta:
        app_label = 'api'
        verbose_name = 'admin MFA チャレンジ'
        verbose_name_plural = 'admin MFA チャレンジ'
        ordering = ['-created_at']
        indexes = [
            # 「直近の active challenge」検索を高速化 (view で頻出パターン)
            models.Index(fields=['user', 'used', '-created_at']),
        ]

    def __str__(self):
        status = '使用済' if self.used else '有効'
        return f'{self.user} — {self.code} ({status}, {self.created_at:%Y-%m-%d %H:%M})'
