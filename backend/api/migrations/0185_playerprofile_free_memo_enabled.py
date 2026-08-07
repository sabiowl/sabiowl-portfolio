"""【FEAT-493 (2026-07-25)】PlayerProfile に free_memo_enabled opt-in flag を追加。

default=False (opt-in β 提供)。ユーザーが設定画面でトグルを ON にするまで
フリーメモ機能は無効。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0184_free_memo'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='free_memo_enabled',
            field=models.BooleanField(
                default=False,
                help_text='FEAT-493 フリーメモ機能の opt-in flag、default OFF',
                verbose_name='フリーメモ有効',
            ),
        ),
    ]
