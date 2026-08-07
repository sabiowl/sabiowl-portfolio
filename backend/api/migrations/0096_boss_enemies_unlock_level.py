"""【FEAT-329 (2026-05-27)】既存 boss 敵 3 体 (goblin_king / shadow_mage / dragon) の
段階解禁化。

ユーザー報告: 「ゴブリンキングやシャドウメイジ、ドラゴンもレベルアップで解禁する
ようにしたい」

### 経緯
migration 0083 (FEAT-296、2026-05-24) で 3 体を seed した時、`unlock_level` フィールドは
**migration 0087 (FEAT-302、2026-05-25) で追加される前** だったため、default 0 のまま
残された。結果として 3 体とも常時解禁状態 = 段階解禁の意義が崩れていた。

FEAT-320 で slime/weak_goblin/young_orc の Lv 0/5/10 を整備した際にも 3 体の
unlock_level は据置のまま (FEAT-320 対象外) = 取り残し。

### PM 確定設計 (変更禁止)

| Enemy        | 旧 unlock_level | 新 unlock_level | 設計意図                                          |
|--------------|----------------:|----------------:|---------------------------------------------------|
| goblin_king  | 0               | **8**           | weak_goblin (Lv5) と young_orc (Lv10) の中間ボス  |
| shadow_mage  | 0               | **12**          | 魔法系ミドル、armored_knight (Lv15) の手前        |
| dragon       | 0               | **20**          | HP 800 = 「初めての強敵」感、ice_witch (Lv25) 前  |

### 採用後の段階階段 (Lv 1-35 で 9 段階解禁)

- Lv 0:  goblin / slime / giant_slime (常時、3 体)
- Lv 5:  weak_goblin
- Lv 8:  goblin_king (本 migration 新規解禁)
- Lv 10: young_orc
- Lv 12: shadow_mage (本 migration 新規解禁)
- Lv 15: armored_knight (mid_boss)
- Lv 20: dragon (本 migration 新規解禁)
- Lv 25: ice_witch (boss)
- Lv 35: void_dragon (hidden_boss)

→ ユーザーが「次の目標」を常に見える設計、JRPG / DQ ウォーク的な lv-progression の
完成。

冪等性: `update_or_create` ではなく `Enemy.objects.filter(key=...).update(unlock_level=...)`
で「既存レコードの値だけ更新」する設計 (新規 seed はせず、既に migration 0083 で
seed 済の 3 体を更新するだけ)。再実行しても同じ unlock_level に収束。

reverse 関数: 3 体の unlock_level を 0 に戻す (元の常時解禁状態に復元)。
"""
from django.db import migrations


_UNLOCK_UPDATES = [
    # (key, new_unlock_level)
    ('goblin_king', 8),
    ('shadow_mage', 12),
    ('dragon',      20),
]


def _update_boss_unlock_levels(apps, schema_editor):
    """既存 boss 敵 3 体の unlock_level を段階解禁値に更新。

    migration 0083 で seed 済のレコードを update_or_create でなく直接 update する。
    既存レコードが存在しない場合 (テスト DB 等) はスキップ、致命エラーにしない。
    """
    Enemy = apps.get_model('api', 'Enemy')
    updated_count = 0
    for key, new_level in _UNLOCK_UPDATES:
        rows = Enemy.objects.filter(key=key).update(unlock_level=new_level)
        if rows > 0:
            updated_count += rows
            print(f'[migration 0096] Updated {key}: unlock_level = {new_level}')
        else:
            print(f'[migration 0096] WARNING: {key} not found, skipping')
    print(f'[migration 0096] Total {updated_count} boss enemies unlock_level updated.')


def _revert_boss_unlock_levels(apps, schema_editor):
    """rollback: 3 体の unlock_level を 0 (常時解禁) に戻す。

    Battle / BattleLog で参照されている場合も unlock_level は別フィールドのため
    PROTECT 制約には引っかからない。
    """
    Enemy = apps.get_model('api', 'Enemy')
    keys = [key for key, _ in _UNLOCK_UPDATES]
    rows = Enemy.objects.filter(key__in=keys).update(unlock_level=0)
    print(f'[migration 0096 reverse] Restored {rows} boss enemies unlock_level to 0.')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0095_add_weapon_gacha_rewards'),
    ]

    operations = [
        migrations.RunPython(_update_boss_unlock_levels, _revert_boss_unlock_levels),
    ]
