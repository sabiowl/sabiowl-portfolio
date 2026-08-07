"""【FEAT-419 (2026-06-10)】TimelineEvent.on_time_bonus_awarded BooleanField 追加。

通常 AddField のみ・破壊的変更なし。既存 TimelineEvent はすべて default=False で
「bonus 履歴なし」扱い (migration バックフィル不要、本フィールドは前向き運用)。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0120_battle_charges_daily_reset'),
    ]

    operations = [
        migrations.AddField(
            model_name='timelineevent',
            name='on_time_bonus_awarded',
            field=models.BooleanField(
                default=False,
                verbose_name='予定時刻ボーナス受領済',
            ),
        ),
    ]
