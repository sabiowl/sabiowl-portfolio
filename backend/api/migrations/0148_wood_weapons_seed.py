"""【FEAT-443 (2026-06-20)】WeaponMaster に木製/練習用武器 11 種を seed 投入する。

PM 確定: 全 11 種とも atk_bonus=5 / コイン 100 の入門装備 (機能等価、見た目変化のみ)。
ジョブ 11 種への対応イメージで武器バリエーションを充実させる + バトル勝利時の
10% ドロップ報酬としても機能。

【冪等性】
`update_or_create(key=...)` で seed 投入、再 apply しても新規追加分のみ
作成され既存レコードは defaults で上書きされる。reverse は本 FEAT で投入した
11 種だけを削除 (既存 starter_sword / bronze_sword 等は残す)。

【CLAUDE.md「master/seed data 例外条項」適用】
- 対象は WeaponMaster master/seed data のみ (user-generated content 不変更)
- 冪等性 update_or_create で再 apply 安全
- FK 影響: PlayerWeapon.weapon FK は WeaponMaster.id 不変なので無影響

【全 FK 影響分析】
- PlayerWeapon.weapon (PROTECT) → 新規 WeaponMaster 11 件追加、既存 row 不変、FK 影響ゼロ
- GachaReward.weapon_key → 新規 key 文字列は GachaReward から参照されない
"""
from django.db import migrations


_NEW_WEAPONS = [
    {
        'key': 'wood_sword',
        'name': '木の剣',
        'atk_bonus': 5,
        'description': '練習用の木製の剣。軽くて扱いやすく、最初の一振りに相応しい。',
    },
    {
        'key': 'wood_axe',
        'name': '木の斧',
        'atk_bonus': 5,
        'description': '木製の練習用斧。素朴な作りだが、振り抜く感触は本物。',
    },
    {
        'key': 'wood_spear',
        'name': '木の槍',
        'atk_bonus': 5,
        'description': '木製の練習用槍。間合いを掴むための入門装備。',
    },
    {
        'key': 'wood_knife',
        'name': '木のナイフ',
        'atk_bonus': 5,
        'description': '木を削って作られた小さな練習用ナイフ。素早さの基本を学ぶ。',
    },
    {
        'key': 'wood_staff',
        'name': '木の杖',
        'atk_bonus': 5,
        'description': '魔力を秘めた素朴な木の杖。詠唱の練習に欠かせない。',
    },
    {
        'key': 'practice_foil',
        'name': '練習用フルーレ',
        'atk_bonus': 5,
        'description': '刃を潰した訓練用の細剣。優雅な所作の習得に。',
    },
    {
        'key': 'wood_bow',
        'name': '木の弓',
        'atk_bonus': 5,
        'description': '柔軟な若木で作られた練習用の弓。狙いの基本を養う。',
    },
    {
        'key': 'hemp_bandage',
        'name': '麻のバンテージ',
        'atk_bonus': 5,
        'description': '麻布で作られた拳の保護布。素手の打撃を支える。',
    },
    {
        'key': 'wood_lute',
        'name': '木彫りのリュート',
        'atk_bonus': 5,
        'description': '手彫りの素朴なリュート。優しい音色で仲間を励ます。',
    },
    {
        'key': 'glass_flask',
        'name': 'ガラスの試験管',
        'atk_bonus': 5,
        'description': '錬金の実験用ガラス試験管。割れやすいので慎重に。',
    },
    {
        'key': 'wood_scythe',
        'name': '木の鎌',
        'atk_bonus': 5,
        'description': '農具を模した練習用の木製鎌。死神への第一歩。',
    },
]


def _seed_weapons(apps, schema_editor):
    WeaponMaster = apps.get_model('api', 'WeaponMaster')
    created_count = 0
    for w in _NEW_WEAPONS:
        _obj, created = WeaponMaster.objects.update_or_create(
            key=w['key'],
            defaults={
                'name':        w['name'],
                'atk_bonus':   w['atk_bonus'],
                'description': w['description'],
                'socket_count': 1,  # 入門装備は 1 ソケット (既存 bronze_sword と同等)
            },
        )
        if created:
            created_count += 1
    print(
        f'[migration 0148 FEAT-443] Seeded {len(_NEW_WEAPONS)} wood weapons '
        f'({created_count} newly created, '
        f'{len(_NEW_WEAPONS) - created_count} already existed)'
    )


def _unseed_weapons(apps, schema_editor):
    """rollback: 本 FEAT で投入した 11 種のみ削除 (既存 weapon は残す)。
    PlayerWeapon.weapon on_delete=PROTECT のため、既に PlayerWeapon に紐付いて
    いる場合は migration が失敗する。ローカル開発時のみ有効な経路。
    """
    WeaponMaster = apps.get_model('api', 'WeaponMaster')
    keys = [w['key'] for w in _NEW_WEAPONS]
    deleted, _ = WeaponMaster.objects.filter(key__in=keys).delete()
    print(f'[migration 0148 FEAT-443 reverse] Deleted {deleted} WeaponMaster rows')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0147_rename_healer_to_white_mage'),
    ]

    operations = [
        migrations.RunPython(_seed_weapons, _unseed_weapons),
    ]
