"""【FEAT-302 Phase 1】v1.0 追加スコープ δ: 敵 3 体 (中ボス / ボス / 隠しボス) seed。

PM 確定設計（指示書 §2.1、変更禁止）:
  | key            | name       | tier        | unlock | base_hp | base_atk | base_spd | scaling | coins | exp  | 弱点 / 耐性                           |
  | armored_knight | 鎧の騎士   | mid_boss    | 15     | 400     | 20       | 8        | 1.3     | 30    | 60   | physical_resistance=0.7              |
  | ice_witch      | 氷の魔女   | boss        | 25     | 600     | 28       | 12       | 1.4     | 50    | 120  | magical_resistance=0.5, weak_ult=4   |
  | void_dragon    | 虚空の竜   | hidden_boss | 35     | 1200    | 40       | 10       | 1.6     | 100   | 300  | なし（純粋ステ勝負）                  |

設計意図:
  - **段階解放** (15 / 25 / 35) でユーザーに「次の目標」を可視化
  - **弱点 / 耐性** で FEAT-299 ジョブ駆動を活かす（戦略性 in v1.0）
  - **報酬曲線**: zako (10/20) < mid (30/60) < boss (50/120) < hidden (100/300)

冪等性 (Pre-mortem #2):
  - `update_or_create(key=...)` の lookup を `key` 一意 (unique=True) で行う
  - defaults に全フィールド明示 → 仕様変更しても冪等
  - reverse 関数: 3 体だけ `delete()` (Battle/BattleLog 未参照のため PROTECT 影響なし、
    防御的に try/except で例外を握る)
"""
from django.db import migrations


_NEW_ENEMIES = [
    {
        'key':                 'armored_knight',
        'name':                '鎧の騎士',
        'sprite_key':          'enemy_armored_knight',
        'base_hp':             400,
        'base_atk':            20,
        'base_spd':            8,
        'level_scaling':       1.3,
        'reward_coins':        30,
        'reward_exp':          60,
        'tier':                'mid_boss',
        'unlock_level':        15,
        'physical_resistance': 0.7,   # warrior 系の物理ダメージ -30%
        'magical_resistance':  1.0,
        'weak_ult_cost':       None,
    },
    {
        'key':                 'ice_witch',
        'name':                '氷の魔女',
        'sprite_key':          'enemy_ice_witch',
        'base_hp':             600,
        'base_atk':            28,
        'base_spd':            12,
        'level_scaling':       1.4,
        'reward_coins':        50,
        'reward_exp':          120,
        'tier':                'boss',
        'unlock_level':        25,
        'physical_resistance': 1.0,
        'magical_resistance':  0.5,   # mage burn / cleric heal -50%
        'weak_ult_cost':       4,     # thief (ultCost=4) のみ Critical +30%
    },
    {
        'key':                 'void_dragon',
        'name':                '虚空の竜',
        'sprite_key':          'enemy_void_dragon',
        'base_hp':             1200,
        'base_atk':            40,
        'base_spd':            10,
        'level_scaling':       1.6,
        'reward_coins':        100,
        'reward_exp':          300,
        'tier':                'hidden_boss',
        'unlock_level':        35,
        'physical_resistance': 1.0,
        'magical_resistance':  1.0,
        'weak_ult_cost':       None,  # エンドコンテンツ、純粋ステ勝負
    },
]


def _seed_new_enemies(apps, schema_editor):
    """3 体の追加 Enemy を `update_or_create` で冪等投入する。"""
    Enemy = apps.get_model('api', 'Enemy')
    created_count = 0
    updated_count = 0
    for spec in _NEW_ENEMIES:
        key = spec['key']
        defaults = {k: v for k, v in spec.items() if k != 'key'}
        _, created = Enemy.objects.update_or_create(key=key, defaults=defaults)
        if created:
            created_count += 1
        else:
            updated_count += 1
    print(f'[migration 0088] Seeded {created_count} new enemies '
          f'(updated {updated_count} existing)')


def _delete_new_enemies(apps, schema_editor):
    """rollback: 3 体だけ削除し、既存 5 体 (goblin/giant_slime/...) は保持。

    Battle / BattleLog で未参照のため PROTECT 制約は無効。万一参照されていた場合は
    防御的に握って、後段の migration rollback パイプラインを止めない。
    """
    Enemy = apps.get_model('api', 'Enemy')
    keys = [spec['key'] for spec in _NEW_ENEMIES]
    try:
        deleted, _ = Enemy.objects.filter(key__in=keys).delete()
        print(f'[migration 0088 reverse] Deleted {deleted} enemy rows')
    except Exception as e:  # noqa: BLE001
        # PROTECT 違反など想定外エラー: 後段 rollback を止めず、ログのみ。
        print(f'[migration 0088 reverse] Delete failed (kept rows): {e}')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0087_enemy_resistance_and_tiers'),
    ]

    operations = [
        migrations.RunPython(_seed_new_enemies, _delete_new_enemies),
    ]
