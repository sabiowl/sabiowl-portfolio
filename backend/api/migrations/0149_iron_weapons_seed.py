"""【FEAT-444 (2026-06-20)】WeaponMaster に Normal/Rare 武器を追加 seed する。

PM 確定:
- Normal 追加 1 種: iron_pistol (鉄の小銃、atk +5、コイン 100) ← gunner ジョブ対応
- Rare 追加 12 種: 鉄シリーズ (atk +10、コイン 200) ← 12 ジョブ網羅 v2

Normal は FEAT-443 の 11 種 (wood シリーズ) と合わせて 12 種。
Rare は本 FEAT で新規に追加する Tier。Rare ドロップ率は 10%、
Normal は本 FEAT で 10% → 15% に引き上げ (battle.py で別途実装)。

【冪等性】
`update_or_create(key=...)` で seed 投入、再 apply しても新規追加分のみ
作成され既存レコードは defaults で上書きされる。reverse は本 FEAT で投入した
13 種だけを削除 (既存 wood シリーズ / starter / bronze 等は残す)。

【CLAUDE.md「master/seed data 例外条項」適用】
- 対象は WeaponMaster master/seed data のみ (user-generated content 不変更)
- 冪等性 update_or_create で再 apply 安全
- FK 影響: PlayerWeapon.weapon FK は WeaponMaster.id 不変なので無影響

【全 FK 影響分析】
- PlayerWeapon.weapon (PROTECT) → 新規 WeaponMaster 13 件追加、既存 row 不変、FK 影響ゼロ
- GachaReward.weapon_key → 新規 key 文字列は GachaReward から参照されない
"""
from django.db import migrations


# Normal tier 追加 (1 種): wood シリーズ 11 + 本 FEAT で +1 = 12 種に揃える
_NORMAL_WEAPONS = [
    {
        'key': 'iron_pistol',
        'name': '鉄の小銃',
        'atk_bonus': 5,
        'description': '練習用の小型銃器。反動を抑えるための入門装備。',
    },
]


# Rare tier 新規 (12 種): 全 12 ジョブイメージに対応
_RARE_WEAPONS = [
    {
        'key': 'iron_small_sword',
        'name': '鉄の小剣',
        'atk_bonus': 10,
        'description': '使いやすさを追求した鉄製の小剣。素早い斬撃に向く。',
    },
    {
        'key': 'iron_hand_axe',
        'name': '鉄の手斧',
        'atk_bonus': 10,
        'description': '片手で扱える鉄製の手斧。堅実な威力を誇る。',
    },
    {
        'key': 'iron_thrust_spear',
        'name': '鉄の突槍',
        'atk_bonus': 10,
        'description': '一撃突きに特化した鉄製の槍。間合いを支配する。',
    },
    {
        'key': 'iron_dagger',
        'name': '鉄のダガー',
        'atk_bonus': 10,
        'description': '研ぎ澄まされた鉄のダガー。急所を狙うための短剣。',
    },
    {
        'key': 'apprentice_grimoire',
        'name': '見習いの魔導書',
        'atk_bonus': 10,
        'description': '見習い魔導士のための魔導書。基礎呪文がぎっしり。',
    },
    {
        'key': 'iron_fine_needle',
        'name': '鉄の細針',
        'atk_bonus': 10,
        'description': '魔法剣士の儀礼用、細く鋭い鉄の針。精緻な斬撃を可能にする。',
    },
    {
        'key': 'iron_short_bow',
        'name': '鉄の短弓',
        'atk_bonus': 10,
        'description': '鉄の補強が施された短弓。取り回しがよく狙いが安定する。',
    },
    {
        'key': 'iron_knuckle',
        'name': '鉄のナックル',
        'atk_bonus': 10,
        'description': '拳に纏う鉄製のナックル。素手の打撃に重みを加える。',
    },
    {
        'key': 'hunting_rifle',
        'name': '猟銃',
        'atk_bonus': 10,
        'description': '長距離狙撃に向いた猟銃。狩人の本格装備。',
    },
    {
        'key': 'iron_string_harp',
        'name': '鉄弦のハープ',
        'atk_bonus': 10,
        'description': '鉄の弦を張った小型ハープ。澄んだ音色で味方を鼓舞する。',
    },
    {
        'key': 'iron_frame_flask',
        'name': '鉄枠のフラスコ',
        'atk_bonus': 10,
        'description': '鉄枠で補強されたフラスコ。錬金の実験を安全に行える。',
    },
    {
        'key': 'iron_scythe',
        'name': '鉄の鎌',
        'atk_bonus': 10,
        'description': '鉄製の鋭利な鎌。死神の本格的な一撃を打つ。',
    },
]


_ALL_NEW_WEAPONS = _NORMAL_WEAPONS + _RARE_WEAPONS


def _seed_weapons(apps, schema_editor):
    WeaponMaster = apps.get_model('api', 'WeaponMaster')
    created_count = 0
    for w in _ALL_NEW_WEAPONS:
        _obj, created = WeaponMaster.objects.update_or_create(
            key=w['key'],
            defaults={
                'name':         w['name'],
                'atk_bonus':    w['atk_bonus'],
                'description':  w['description'],
                'socket_count': 1,  # Normal/Rare ともに 1 ソケット (既存 bronze/wood と同等)
            },
        )
        if created:
            created_count += 1
    print(
        f'[migration 0149 FEAT-444] Seeded {len(_ALL_NEW_WEAPONS)} weapons '
        f'({len(_NORMAL_WEAPONS)} Normal + {len(_RARE_WEAPONS)} Rare, '
        f'{created_count} newly created, '
        f'{len(_ALL_NEW_WEAPONS) - created_count} already existed)'
    )


def _unseed_weapons(apps, schema_editor):
    """rollback: 本 FEAT で投入した 13 種のみ削除 (既存 weapon は残す)。
    PlayerWeapon.weapon on_delete=PROTECT のため、既に PlayerWeapon に紐付いて
    いる場合は migration が失敗する。ローカル開発時のみ有効な経路。
    """
    WeaponMaster = apps.get_model('api', 'WeaponMaster')
    keys = [w['key'] for w in _ALL_NEW_WEAPONS]
    deleted, _ = WeaponMaster.objects.filter(key__in=keys).delete()
    print(f'[migration 0149 FEAT-444 reverse] Deleted {deleted} WeaponMaster rows')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0148_wood_weapons_seed'),
    ]

    operations = [
        migrations.RunPython(_seed_weapons, _unseed_weapons),
    ]
