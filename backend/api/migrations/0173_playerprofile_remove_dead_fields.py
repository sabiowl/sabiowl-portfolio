"""【FEAT-478 Phase 2d (2026-07-06)】PlayerProfile から dead field 3 個を削除。

対象:
  - rest_fruits (FEAT-424 で機能廃止、State 移行対象外)
  - legendary_slots_bonus (FEAT-434 で Legendary 難易度廃止 → 枠制限廃止)
  - legendary_slots_purchase_count (FEAT-434 同、累進購入も廃止)

FEAT-434 の migration 0136 (2026-06-14) で購入済ユーザーへの返金 + 両 field の
0 リセットが完了しているため、単純削除で問題なし (既存データは全て 0 or default 値)。
"""
from django.db import migrations


class Migration(migrations.Migration):
    dependencies = [
        ('api', '0172_playerprofile_remove_streak_settings_fields'),
    ]
    operations = [
        migrations.RemoveField(model_name='playerprofile', name='rest_fruits'),
        migrations.RemoveField(model_name='playerprofile', name='legendary_slots_bonus'),
        migrations.RemoveField(model_name='playerprofile', name='legendary_slots_purchase_count'),
    ]
