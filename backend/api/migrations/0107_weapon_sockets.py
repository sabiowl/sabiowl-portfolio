"""【FEAT-379 (2026-05-29)】WeaponMaster.socket_count + PlayerWeapon.socket_*_crystal_type 追加。

WeaponMaster socket_count 初期値 seed (RunPython):
  - starter_sword:  1 (入門)
  - bronze_sword:   1 (入門)
  - iron_sword:     2 (標準)
  - steel_sword:    2 (標準)
  - mythril_sword:  3 (SR 上位)
  - dragon_slayer:  3 (SSR 最強)

PlayerWeapon.socket_*_crystal_type: v1.0 は NULL デフォルト (装着 UI は v1.1+ 解禁)。
"""
from django.db import migrations, models


def _seed_socket_counts(apps, schema_editor):
    WeaponMaster = apps.get_model('api', 'WeaponMaster')

    socket_map = {
        'starter_sword':  1,
        'bronze_sword':   1,
        'iron_sword':     2,
        'steel_sword':    2,
        'mythril_sword':  3,
        'dragon_slayer':  3,
    }
    updated = 0
    for key, count in socket_map.items():
        rows = WeaponMaster.objects.filter(key=key).update(socket_count=count)
        updated += rows
    print(f'[FEAT-379 weapon socket seed] {updated} weapons updated')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0106_player_crystal_counts'),
    ]

    operations = [
        # WeaponMaster.socket_count (default=1 = 後方互換)
        migrations.AddField(
            model_name='weaponmaster',
            name='socket_count',
            field=models.IntegerField(default=1),
        ),
        # PlayerWeapon.socket_*_crystal_type (v1.0 は NULL 維持)
        migrations.AddField(
            model_name='playerweapon',
            name='socket_1_crystal_type',
            field=models.CharField(max_length=32, null=True, blank=True),
        ),
        migrations.AddField(
            model_name='playerweapon',
            name='socket_2_crystal_type',
            field=models.CharField(max_length=32, null=True, blank=True),
        ),
        migrations.AddField(
            model_name='playerweapon',
            name='socket_3_crystal_type',
            field=models.CharField(max_length=32, null=True, blank=True),
        ),
        # 各武器の socket_count を設定
        migrations.RunPython(
            _seed_socket_counts,
            reverse_code=migrations.RunPython.noop,
        ),
    ]
