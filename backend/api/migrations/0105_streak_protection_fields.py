"""【FEAT-377 (2026-05-29)】PlayerProfile にストリーク保護機能フィールドを追加。

ストリーク保護: 連続記録が途切れた瞬間に 💎 30 / 個のアイテムを消費し streak を維持する。
自動 ON/OFF + 手動ボタンの両方をサポート。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0104_legendary_slots_bonus'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='streak_protection_count',
            field=models.IntegerField(
                default=0,
                verbose_name='ストリーク保護 在庫',
            ),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='streak_protection_auto_enabled',
            field=models.BooleanField(
                default=False,
                verbose_name='自動保護 ON/OFF',
            ),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='last_streak_protection_used_at',
            field=models.DateField(
                null=True, blank=True,
                verbose_name='直近保護発動日',
            ),
        ),
    ]
