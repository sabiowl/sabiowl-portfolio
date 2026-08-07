"""【FEAT-375 (2026-05-29)】PlayerProfile に legendary_slots_bonus フィールドを追加。

ダイヤ 💎 200 で Legendary 習慣の枠を +1 (上限 5 枠) できるようにするための
ボーナス管理フィールド。
Lv 連動の主軸 (calc_legendary_slots) に加算される形で上限を拡張する。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0103_gacha_redo_fields'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='legendary_slots_bonus',
            field=models.IntegerField(
                default=0,
                verbose_name='Legendary 枠ボーナス (ダイヤ購入分)',
            ),
        ),
    ]
