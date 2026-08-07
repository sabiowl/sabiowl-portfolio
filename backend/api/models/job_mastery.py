"""【FEAT-511 Phase A (v1.1、2026-07-30)】ジョブ熟練度モデル。"""
from django.db import models


class PlayerJobMastery(models.Model):
    """プレイヤーのジョブ別熟練度。PlayerProfile × Job のクロスでレコード管理。

    v1.0 で FEAT-430 により deactivate された `PlayerProfile.active_job` は、
    Phase B (v1.1+ 数週後、別 FEAT) で「Max 到達ジョブのみ他キャラに装着可能」
    として再活性化予定。Phase A では **read-only 表示 + 熟練度 EXP 加算のみ**。
    """
    player = models.ForeignKey(
        'api.PlayerProfile', on_delete=models.CASCADE,
        related_name='job_masteries',
    )
    job = models.ForeignKey(
        'api.Job', on_delete=models.CASCADE,
        related_name='masteries_by_player',
    )
    level    = models.IntegerField(default=1, verbose_name='熟練度レベル (1-10)')
    exp      = models.IntegerField(default=0, verbose_name='熟練度 EXP (current level 内)')
    is_maxed = models.BooleanField(default=False, verbose_name='Max 到達済')
    first_maxed_at = models.DateTimeField(null=True, blank=True, verbose_name='Max 到達日時')

    class Meta:
        app_label = 'api'
        constraints = [
            models.UniqueConstraint(fields=['player', 'job'], name='unique_player_job_mastery'),
        ]
        indexes = [
            models.Index(fields=['player', 'is_maxed'], name='idx_player_job_mastery_maxed'),
        ]
        verbose_name = 'ジョブ熟練度'
        verbose_name_plural = 'ジョブ熟練度'

    def __str__(self):
        return f'{self.player.name} × {self.job.job_name} Lv{self.level}'
