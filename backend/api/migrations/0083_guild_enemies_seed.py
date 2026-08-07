"""【FEAT-296 Phase 2-1】ギルド画面で表示する追加 Enemy 4 体の seed。

既存 `goblin` (migration 0082) はそのまま BattleWidget の「練習相手」として
維持し、追加の 4 体（巨大スライム / ゴブリンキング / ドラゴン / シャドウメイジ）
を `RunPython` で投入する。

設計（指示書 §1.2 のバランス表）:
  | key            | name           | base_hp | base_atk | base_spd | scaling | coins | exp  | tier |
  | giant_slime    | 巨大スライム   | 200     | 8        | 6        | 1.5     | 15    | 30   | zako |
  | goblin_king    | ゴブリンキング | 350     | 14       | 9        | 1.8     | 30    | 60   | boss |
  | dragon         | ドラゴン       | 800     | 25       | 7        | 2.5     | 80    | 150  | boss |
  | shadow_mage    | シャドウメイジ | 500     | 20       | 12       | 2.0     | 60    | 120  | boss |

冪等性: `get_or_create` を採用、再実行でも複製しない。reverse 関数で
4 体だけ削除（ゴブリンは保持）。
"""
from django.db import migrations


_BOSS_SEED = [
    {
        'key':           'giant_slime',
        'name':          '巨大スライム',
        'sprite_key':    'enemy_giant_slime',
        'base_hp':       200,
        'base_atk':      8,
        'base_spd':      6,
        'level_scaling': 1.5,
        'reward_coins':  15,
        'reward_exp':    30,
        'tier':          'zako',
    },
    {
        'key':           'goblin_king',
        'name':          'ゴブリンキング',
        'sprite_key':    'enemy_goblin_king',
        'base_hp':       350,
        'base_atk':      14,
        'base_spd':      9,
        'level_scaling': 1.8,
        'reward_coins':  30,
        'reward_exp':    60,
        'tier':          'boss',
    },
    {
        'key':           'dragon',
        'name':          'ドラゴン',
        'sprite_key':    'enemy_dragon',
        'base_hp':       800,
        'base_atk':      25,
        'base_spd':      7,
        'level_scaling': 2.5,
        'reward_coins':  80,
        'reward_exp':    150,
        'tier':          'boss',
    },
    {
        'key':           'shadow_mage',
        'name':          'シャドウメイジ',
        'sprite_key':    'enemy_shadow_mage',
        'base_hp':       500,
        'base_atk':      20,
        'base_spd':      12,
        'level_scaling': 2.0,
        'reward_coins':  60,
        'reward_exp':    120,
        'tier':          'boss',
    },
]


def _seed_bosses(apps, schema_editor):
    """4 体の追加 Enemy を冪等に投入する。"""
    Enemy = apps.get_model('api', 'Enemy')
    created_count = 0
    for spec in _BOSS_SEED:
        key = spec['key']
        defaults = {k: v for k, v in spec.items() if k != 'key'}
        _, created = Enemy.objects.get_or_create(key=key, defaults=defaults)
        if created:
            created_count += 1
    print(f'[migration 0083] Seeded {created_count} additional enemies '
          f'(skipped {len(_BOSS_SEED) - created_count} already-existing)')


def _delete_bosses(apps, schema_editor):
    """rollback: 4 体だけ削除し、ゴブリン (migration 0082) は保持。

    注: Battle / BattleLog レコードが ForeignKey で参照している場合、
    PROTECT 制約により削除が失敗する可能性がある。リリース前段階の
    開発リセット用途を想定しているため、Battle 履歴は事前削除が必要。
    """
    Enemy = apps.get_model('api', 'Enemy')
    keys = [spec['key'] for spec in _BOSS_SEED]
    deleted, _ = Enemy.objects.filter(key__in=keys).delete()
    print(f'[migration 0083 reverse] Deleted {deleted} enemy rows')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0082_battle_seed'),
    ]

    operations = [
        migrations.RunPython(_seed_bosses, _delete_bosses),
    ]
