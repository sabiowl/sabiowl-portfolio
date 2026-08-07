"""【FEAT-436 Phase 2 (2026-06-17)】IAP 領収書記録モデル。

RevenueCat の webhook で受信した購入イベントを冪等性ガード付きで保存し、
ダイヤ付与履歴を残す。同一 event_id の再送 / 並列受信に対しては
unique 制約 + select_for_update でガード。

【設計】
- 領収書検証は RevenueCat (SaaS) が代行 → Backend は webhook を受信するだけ
- event_id = RevenueCat の event UUID (= 冪等性キー)
- app_user_id = `Purchases.configure(appUserID)` で渡した PlayerProfile.id (文字列)
- raw_payload = webhook ボディ全体を JSONField で保存 (デバッグ + ベンダーロックイン
  時の自前検証フォールバック用、Pre-mortem S10)
"""
from django.db import models

from .player import PlayerProfile


class IAPReceipt(models.Model):
    """RevenueCat webhook で受信した購入イベントの記録。

    冪等性: event_id (RevenueCat の event UUID) で unique。
    同一 event を 2 回受信しても 1 度しかダイヤ付与されない。
    """
    STORE_CHOICES = [
        ('app_store',  'Apple App Store'),
        ('play_store', 'Google Play'),
        ('sandbox',    'Sandbox/Test'),
    ]
    EVENT_TYPE_CHOICES = [
        ('INITIAL_PURCHASE',      '初回購入'),
        ('NON_RENEWING_PURCHASE', '買い切り'),
        ('CANCELLATION',          '返金/取消'),
        ('UNCATEGORIZED_PURCHASE','その他'),
    ]
    STATUS_CHOICES = [
        ('pending',  '受信済 (処理中)'),
        ('granted',  'ダイヤ付与済'),
        ('skipped',  '対象外 (entitlement のみ等)'),
        ('failed',   'エラー (ログ記録)'),
        ('refunded', '返金処理済'),
    ]

    player = models.ForeignKey(
        PlayerProfile, on_delete=models.CASCADE,
        related_name='iap_receipts',
        null=True, blank=True,
        verbose_name='プレイヤー',
        help_text='webhook 受信時に PlayerProfile が見つからない場合 null 許容',
    )
    event_id         = models.CharField(
        max_length=64, unique=True,
        verbose_name='RevenueCat event UUID',
        help_text='冪等性キー、同一 event は 1 度しか付与しない',
    )
    event_type       = models.CharField(
        max_length=32, choices=EVENT_TYPE_CHOICES,
        verbose_name='イベント種別',
    )
    product_id       = models.CharField(
        max_length=100,
        verbose_name='商品 ID',
        help_text='例: diamond_pack_120',
    )
    transaction_id   = models.CharField(
        max_length=100, blank=True, default='',
        verbose_name='トランザクション ID',
        help_text='Apple/Google 由来の transaction_id',
    )
    store            = models.CharField(
        max_length=20, choices=STORE_CHOICES,
        verbose_name='ストア',
    )
    app_user_id      = models.CharField(
        max_length=64,
        verbose_name='App User ID',
        help_text='Purchases.configure(appUserID) で渡した PlayerProfile.id 文字列',
    )
    status           = models.CharField(
        max_length=10, choices=STATUS_CHOICES, default='pending',
        verbose_name='処理状態',
    )
    granted_diamonds = models.IntegerField(
        default=0,
        verbose_name='付与ダイヤ数',
    )
    raw_payload      = models.JSONField(
        verbose_name='webhook 生ペイロード',
        help_text='デバッグ + ベンダーロックイン時の自前検証フォールバック用',
    )
    error_message    = models.TextField(
        blank=True, default='',
        verbose_name='エラー詳細',
    )
    created_at       = models.DateTimeField(
        auto_now_add=True,
        verbose_name='受信時刻',
    )
    processed_at     = models.DateTimeField(
        null=True, blank=True,
        verbose_name='処理完了時刻',
    )

    class Meta:
        app_label = 'api'
        verbose_name = 'IAP 領収書'
        verbose_name_plural = 'IAP 領収書'
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['player', '-created_at']),
            models.Index(fields=['event_id']),
            models.Index(fields=['status']),
        ]

    def __str__(self):
        return f'IAPReceipt({self.event_id[:8]}…, {self.product_id}, {self.status})'
