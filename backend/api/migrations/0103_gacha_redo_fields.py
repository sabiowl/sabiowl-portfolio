"""【FEAT-374 (2026-05-29)】PlayerGachaStatus にガチャ「もう 1 度」💎 50 向け redo 管理フィールドを追加。

直近 1 回分の pull を記録し、24h 以内・redo_used=False なら 1 度だけ追加引き直し可能。
rollback (前結果取消) ではなく「追加 1 回引き直し」(前結果保持) の設計で race リスクを排除。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0102_disable_gcal_push_for_v1_0'),
    ]

    operations = [
        migrations.AddField(
            model_name='playergachastatus',
            name='last_pull_id',
            field=models.IntegerField(
                null=True, blank=True,
                verbose_name='直近ガチャ履歴 ID (GachaHistory.pk)',
            ),
        ),
        migrations.AddField(
            model_name='playergachastatus',
            name='last_pull_at',
            field=models.DateTimeField(
                null=True, blank=True,
                verbose_name='直近ガチャ日時',
            ),
        ),
        migrations.AddField(
            model_name='playergachastatus',
            name='last_pull_pool',
            field=models.CharField(
                max_length=16, null=True, blank=True,
                verbose_name='直近ガチャ種別 (daily / weekly / monthly)',
            ),
        ),
        migrations.AddField(
            model_name='playergachastatus',
            name='redo_used',
            field=models.BooleanField(
                default=False,
                verbose_name='redo 使用済みフラグ',
            ),
        ),
    ]
