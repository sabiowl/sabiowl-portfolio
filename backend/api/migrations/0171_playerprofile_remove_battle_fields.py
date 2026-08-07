"""【FEAT-478 Phase 2d (2026-07-06)】PlayerProfile から Battle 系 12 field を削除。

前提条件は 0170 と同じ (Phase 2b 書換完了 + Phase 2c data 移行完了 + @property 書換済)。
"""
from django.db import migrations


class Migration(migrations.Migration):
    dependencies = [
        ('api', '0170_playerprofile_remove_economy_fields'),
    ]
    operations = [
        migrations.RemoveField(model_name='playerprofile', name='level'),
        migrations.RemoveField(model_name='playerprofile', name='current_exp'),
        migrations.RemoveField(model_name='playerprofile', name='max_exp'),
        migrations.RemoveField(model_name='playerprofile', name='allocatable_points'),
        migrations.RemoveField(model_name='playerprofile', name='battle_charges'),
        migrations.RemoveField(model_name='playerprofile', name='battle_charges_date'),
        migrations.RemoveField(model_name='playerprofile', name='daily_exp_count'),
        migrations.RemoveField(model_name='playerprofile', name='daily_exp_count_date'),
        migrations.RemoveField(model_name='playerprofile', name='daily_battle_count'),
        migrations.RemoveField(model_name='playerprofile', name='daily_battle_count_date'),
        migrations.RemoveField(model_name='playerprofile', name='daily_battle_limit_bonus'),
        migrations.RemoveField(model_name='playerprofile', name='daily_battle_limit_purchase_count'),
    ]
