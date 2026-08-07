"""【FEAT-400 v3 (2026-05-31)】Enemy 全 12 体バランス再調整 + level_scaling 0.5 統一。

計算式変更 (battle.py で scaled_hp = base_hp に固定化) と合わせて、全 12 体の
base_hp を「Lv 関わらず固定」基準で再設計。

zako 系 7 体: FEAT-332 「unlock で 5 撃」設計を base_hp 固定値で再現
boss 系 5 体: 「unlock で 6-7 撃 (辛い)、指定 Lv で 5 撃 (倒せる)」設計

level_scaling は HP 連動から外れ、ATK 連動係数として 0.5 統一
(旧 boss 系の 1.4-2.5 から大幅調整、ATK の現実化)。

master/seed data 例外条項 (CLAUDE.md) 適用:
  1. 対象が master/seed data のみ (user-generated content を含まない)
  2. FK を網羅: Enemy への FK は Battle.enemy / BattleLog.battle → Enemy (PROTECT)
     本 migration は UPDATE のみで DELETE なし → CASCADE / PROTECT 問題なし
  3. 冪等性: filter().update() で再 apply 安全
"""
from django.db import migrations


# (key, base_hp, base_atk, level_scaling)
_ENEMY_UPDATES = [
    # zako 系 7 体
    ('slime',          130, 3,  0.5),  # Lv 1 で 5.9 撃 (onboarding)
    ('weak_goblin',    150, 5,  0.5),  # Lv 5 で 5 撃
    ('goblin',         150, 8,  0.5),  # Lv 5 で 5 撃
    ('giant_slime',    180, 9,  0.5),  # Lv 8 で 5 撃
    ('young_orc',      200, 8,  0.5),  # Lv 10 で 5 撃
    ('goblin_king',    220, 9,  0.5),  # Lv 12 で 5 撃
    ('shadow_mage',    250, 10, 0.5),  # Lv 15 で 5 撃
    # boss 系 5 体
    ('armored_knight', 320, 9,  0.5),  # unlock 18 で 5.7 撃、Lv 20 で 5.3 撃
    ('dragon',         350, 10, 0.5),  # unlock 20 で 5.8 撃、Lv 25 で 5 撃
    ('ice_witch',      400, 12, 0.5),  # unlock 25 で 5.7 撃、Lv 30 で 5 撃
    ('void_dragon',    500, 11, 0.5),  # unlock 35 で 5.6 撃、Lv 40 で 5 撃
    ('griffin',        600, 11, 0.5),  # unlock 35 で 6.7 撃、Lv 50 で 5 撃
]


# rollback 用旧値 (FEAT-332 / 各 FEAT の最終値)
_ENEMY_PREVIOUS = [
    ('slime',          25,   3,  0.3),
    ('weak_goblin',    60,   5,  0.4),
    ('goblin',         60,   8,  0.5),
    ('giant_slime',    45,   9,  0.5),
    ('young_orc',      40,   8,  0.5),
    ('goblin_king',    37,   9,  0.5),
    ('shadow_mage',    33,   10, 0.5),
    ('armored_knight', 31,   9,  0.5),
    ('dragon',         800,  25, 2.5),
    ('ice_witch',      600,  28, 1.4),
    ('void_dragon',    1200, 40, 1.6),
    ('griffin',        750,  38, 2.0),
]


def _apply_full_rebalance(apps, schema_editor):
    Enemy = apps.get_model('api', 'Enemy')
    for key, hp, atk, scaling in _ENEMY_UPDATES:
        Enemy.objects.filter(key=key).update(
            base_hp=hp, base_atk=atk, level_scaling=scaling,
        )


def _revert_full_rebalance(apps, schema_editor):
    Enemy = apps.get_model('api', 'Enemy')
    for key, hp, atk, scaling in _ENEMY_PREVIOUS:
        Enemy.objects.filter(key=key).update(
            base_hp=hp, base_atk=atk, level_scaling=scaling,
        )


class Migration(migrations.Migration):
    dependencies = [('api', '0116_daily_throttle')]
    operations = [migrations.RunPython(_apply_full_rebalance, _revert_full_rebalance)]
