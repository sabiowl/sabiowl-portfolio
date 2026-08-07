"""【FEAT-463 (2026-06-22)】緊急メンテナンスモードのモデル定義。

Django admin から ON/OFF できる「緊急メンテナンスモード」。障害発生時 / 計画停止時に
運営が即座に全ユーザーへ告知できる手段がなかった課題への対応。

【設計判断】
- Singleton (常に pk=1 の 1 行のみ)。admin から複数行作成できないよう
  has_add_permission / has_delete_permission で抑制 (admin.py 側)。
- middleware が毎リクエスト読み取り、is_enabled_now() が True のとき
  レスポンスに X-Maintenance: 1 を付与 (DB 書き込みなし、race 回避)。
- 自動失効 (expires_at) は判定のみで is_enabled の DB 書き込みは行わない。
  admin が手動で OFF にする運用 (PM 確定設計、doc/instructions/FEAT-463 §2-1)。
"""
from django.conf import settings
from django.db import models
from django.utils import timezone


class MaintenanceConfig(models.Model):
    """緊急メンテナンス設定 (Singleton: 常に pk=1 の 1 行のみ)。

    Django admin から ON/OFF + タイトル / 本文 / 失効時刻を編集する。
    """

    is_enabled = models.BooleanField(
        default=False,
        verbose_name='メンテナンスモード有効',
        help_text='ON にすると全クライアントに maintenance overlay を表示します。',
    )
    title = models.CharField(
        max_length=60, blank=True,
        default='現在、システムに手当てをしております',
        verbose_name='タイトル',
    )
    # 【FEAT-516 (2026-08-04)】英語版。空欄なら ja にフォールバックする
    # (`get_i18n_field`)。投入は `translate_master_data` 経由。
    title_en = models.CharField(
        max_length=60,
        blank=True,
        default='',
        verbose_name='タイトル(英語版)',
    )
    body = models.TextField(
        max_length=400, blank=True,
        default='少し時間をおいて、もう一度お試しください 🪶',
        verbose_name='本文 (サビ口調推奨)',
    )
    # 【FEAT-516 (2026-08-04)】英語版。空欄なら ja にフォールバックする
    # (`get_i18n_field`)。投入は `translate_master_data` 経由。
    body_en = models.TextField(
        blank=True,
        default='',
        verbose_name='本文(英語版)',
    )
    expires_at = models.DateTimeField(
        null=True, blank=True,
        verbose_name='自動失効時刻',
        help_text=(
            'この時刻を過ぎたら maintenance は自動的に解除されます '
            '(DB の is_enabled は admin が手動 OFF してください。未入力時は無期限です)。'
        ),
    )
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, null=True, blank=True,
        on_delete=models.SET_NULL,
        related_name='maintenance_changes',
        verbose_name='最終更新者',
    )
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        app_label = 'api'
        verbose_name = '緊急メンテナンス設定'
        verbose_name_plural = '緊急メンテナンス設定'

    def __str__(self):
        status = 'ON' if self.is_enabled_now() else 'OFF'
        return f'MaintenanceConfig({status})'

    def is_enabled_now(self):
        """is_enabled が True かつ expires_at が未来 (or None) なら True。"""
        if not self.is_enabled:
            return False
        if self.expires_at is None:
            return True
        return timezone.now() < self.expires_at

    @classmethod
    def get_solo(cls):
        """Singleton: pk=1 を get_or_create で取得する。"""
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj
