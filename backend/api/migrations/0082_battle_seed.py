"""【FEAT-295 Phase 1e】Enemy / WeaponMaster の初期データ投入。

MVP は 1 種ずつのみ（雑魚: ゴブリン / 武器: 見習いの剣）。

Phase 2 以降で雑魚を複数 + ボス + 武器多種を追加する際は、別 migration で
追加 seed する設計（idempotent でない RunPython を増やさない）。

ロールバック時の noop は安全（追加された Enemy/WeaponMaster がデータに残ったまま
でも、unique key で守られているため再 apply 時に重複しない）。
"""
from django.db import migrations


def _seed_initial(apps, schema_editor):
    """ゴブリン + 見習いの剣を `get_or_create` で冪等に投入する。"""
    Enemy = apps.get_model('api', 'Enemy')
    WeaponMaster = apps.get_model('api', 'WeaponMaster')

    enemy, e_created = Enemy.objects.get_or_create(
        key='goblin',
        defaults={
            'name':          'ゴブリン',
            'sprite_key':    'enemy_goblin',
            'base_hp':       60,
            'base_atk':      8,
            'base_spd':      10,
            'level_scaling': 1.0,
            'reward_coins':  10,
            'reward_exp':    20,
            'tier':          'zako',
        },
    )
    if e_created:
        print('[migration 0082] Seeded Enemy "goblin"')
    else:
        print('[migration 0082] Enemy "goblin" already exists, skipping')

    weapon, w_created = WeaponMaster.objects.get_or_create(
        key='starter_sword',
        defaults={
            'name':        '見習いの剣',
            'atk_bonus':   10,
            'description': '握りなじみの良い、刃こぼれひとつない一振り。',
        },
    )
    if w_created:
        print('[migration 0082] Seeded WeaponMaster "starter_sword"')
    else:
        print('[migration 0082] WeaponMaster "starter_sword" already exists, skipping')


def _reverse_noop(apps, schema_editor):
    """ロールバック不可（seed されたデータがプレイヤー所持に紐付いている可能性、
    また MVP リリース前段階のためデータ削除は不要）。"""
    pass


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0081_battle_system'),
    ]

    operations = [
        migrations.RunPython(_seed_initial, _reverse_noop),
    ]
