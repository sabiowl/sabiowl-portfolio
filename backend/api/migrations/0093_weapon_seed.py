# Generated for FEAT-326: 武器装備システム実装 (Phase 1)
"""【FEAT-326】WeaponMaster に 5 種類の武器を seed 投入する。

Shop 購入用 3 種 (bronze/iron/steel) + ガチャ排出用 2 種 (mythril/dragon_slayer)。
既存 `starter_sword` (atk_bonus=10、migration 0082 で seed 済) は変更しない。

冪等性: `update_or_create(key=...)` で seed 投入、再 apply しても新規追加分のみ
作成され既存レコードは defaults で上書きされる。reverse は本 FEAT で投入した
5 種だけを削除 (starter_sword は残す)。
"""
from django.db import migrations


_NEW_WEAPONS = [
    {
        'key': 'bronze_sword',
        'name': '銅の剣',
        'atk_bonus': 5,
        'description': '初心者向けの軽い剣。最初の一振りに相応しい入門装備。',
    },
    {
        'key': 'iron_sword',
        'name': '鉄の剣',
        'atk_bonus': 10,
        'description': '一般的な戦士の剣。starter と同性能だが「自分で買った」達成感がある。',
    },
    {
        'key': 'steel_sword',
        'name': '鋼の剣',
        'atk_bonus': 20,
        'description': '熟練の戦士に相応しい剣。コイン購入の最高峰、Lv 10+ の戦力強化に。',
    },
    {
        'key': 'mythril_sword',
        'name': 'ミスリルの剣',
        'atk_bonus': 35,
        'description': '魔力を帯びた稀少な剣。ガチャの Daily SR でのみ入手可能。',
    },
    {
        'key': 'dragon_slayer',
        'name': '竜殺しの剣',
        'atk_bonus': 50,
        'description': '伝説の竜を屠った剣。ガチャの Weekly SSR でのみ入手可能な最強装備。',
    },
]


def _seed_weapons(apps, schema_editor):
    WeaponMaster = apps.get_model('api', 'WeaponMaster')
    created_count = 0
    for w in _NEW_WEAPONS:
        _obj, created = WeaponMaster.objects.update_or_create(
            key=w['key'],
            defaults={
                'name': w['name'],
                'atk_bonus': w['atk_bonus'],
                'description': w['description'],
            },
        )
        if created:
            created_count += 1
    print(
        f'[migration 0093] Seeded {len(_NEW_WEAPONS)} weapons '
        f'({created_count} newly created, {len(_NEW_WEAPONS) - created_count} already existed)'
    )


def _unseed_weapons(apps, schema_editor):
    """rollback: 本 FEAT で投入した 5 種のみ削除 (starter_sword は残す)。
    既に PlayerWeapon に紐付いている場合は on_delete=PROTECT で migration が
    失敗するが、ローカル開発時は意図的挙動 (本番では事前に PlayerWeapon を
    別 management command で剥がしてから rollback する想定)。"""
    WeaponMaster = apps.get_model('api', 'WeaponMaster')
    keys = [w['key'] for w in _NEW_WEAPONS]
    deleted, _ = WeaponMaster.objects.filter(key__in=keys).delete()
    print(f'[migration 0093 reverse] Deleted {deleted} WeaponMaster rows')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0092_progression_enemies_seed'),
    ]

    operations = [
        migrations.RunPython(_seed_weapons, _unseed_weapons),
    ]
