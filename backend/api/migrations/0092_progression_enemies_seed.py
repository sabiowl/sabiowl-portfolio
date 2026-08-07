"""【FEAT-320 (2026-05-27)】段階進行型 Enemy 3 体追加 + 既存 goblin level_scaling 緩和。

ユーザー画面操作中の要件 (PM 長期設計セッション 2026-05-27):
> 「ギルド画面のクエストについて、レベル1で倒せるモンスター、レベル5で倒せるモンスター、
>   レベル10で倒せるモンスターと、段階的に倒せるモンスターを追加したい。
>   現状はゴブリンが最弱だが、レベル6でも倒せないため、ユーザが途中で飽きてしまう可能性がある。」

設計確定 (PM、変更禁止):

### 新規追加 3 体 (段階解禁、level_scaling 緩め)

| key          | name           | tier | base_hp | base_atk | base_spd | level_scaling | coins | exp | unlock_lv |
|--------------|----------------|------|---------|----------|----------|---------------|-------|-----|-----------|
| slime        | スライム        | zako | 25      | 3        | 5        | 0.3           | 5     | 10  | 0  (常時)  |
| weak_goblin  | はぐれゴブリン  | zako | 60      | 5        | 7        | 0.4           | 12    | 25  | 5  (Lv5+)  |
| young_orc    | 若オーク        | zako | 100     | 8        | 6        | 0.5           | 25    | 50  | 10 (Lv10+) |

### 既存 goblin の調整 (level_scaling 1.0 → 0.5)

旧: Lv1=60HP, Lv5=300HP, Lv10=600HP (リニアスケールで「Lv 上がっても倒せない」体感)
新: Lv1=60HP, Lv5=150HP, Lv10=300HP (緩やかスケール、レベル成長の実感)

設計意図:
- **slime**: Lv1 から「倒せた!」体験を即提供 (HP 7 @ Lv1)、新規ユーザーのオンボーディング
- **weak_goblin** (Lv5 解禁): 「Lv5 で新しい敵が解禁」体験で次の目標を可視化
- **young_orc** (Lv10 解禁): 「Lv10 でさらに新しい敵」、ミドルゲーム入口
- **goblin scaling 緩和**: Lv6 で goblin が 60×6=360HP 化していた問題を解消、Lv6 で 180HP に

冪等性 (Pre-mortem 緩和):
- `update_or_create(key=...)` の lookup を `key` 一意 (unique=True) で行う
- defaults に全フィールド明示 → 仕様変更しても冪等
- 既存 goblin の level_scaling 変更は `Enemy.objects.filter(key='goblin').update(...)` で別途実行
- reverse 関数: 3 体だけ delete + goblin scaling を 1.0 に戻す
"""
from django.db import migrations


_PROGRESSION_ENEMIES = [
    {
        'key':                 'slime',
        'name':                'スライム',
        'sprite_key':          'enemy_slime',
        'base_hp':             25,
        'base_atk':            3,
        'base_spd':            5,
        'level_scaling':       0.3,
        'reward_coins':        5,
        'reward_exp':          10,
        'tier':                'zako',
        'unlock_level':        0,
        'physical_resistance': 1.0,
        'magical_resistance':  1.0,
        'weak_ult_cost':       None,
    },
    {
        'key':                 'weak_goblin',
        'name':                'はぐれゴブリン',
        'sprite_key':          'enemy_weak_goblin',
        'base_hp':             60,
        'base_atk':            5,
        'base_spd':            7,
        'level_scaling':       0.4,
        'reward_coins':        12,
        'reward_exp':          25,
        'tier':                'zako',
        'unlock_level':        5,
        'physical_resistance': 1.0,
        'magical_resistance':  1.0,
        'weak_ult_cost':       None,
    },
    {
        'key':                 'young_orc',
        'name':                '若オーク',
        'sprite_key':          'enemy_young_orc',
        'base_hp':             100,
        'base_atk':            8,
        'base_spd':            6,
        'level_scaling':       0.5,
        'reward_coins':        25,
        'reward_exp':          50,
        'tier':                'zako',
        'unlock_level':        10,
        'physical_resistance': 1.0,
        'magical_resistance':  1.0,
        'weak_ult_cost':       None,
    },
]


def _seed_progression_enemies(apps, schema_editor):
    """3 体の段階進行 Enemy を `update_or_create` で冪等投入する。

    既存 goblin の level_scaling も 1.0 → 0.5 に同時更新 (Lv6 で 360HP 化問題を解消)。
    """
    Enemy = apps.get_model('api', 'Enemy')

    # ── 1. 新規 3 体投入 ────────────────────────────────────────
    created_count = 0
    updated_count = 0
    for spec in _PROGRESSION_ENEMIES:
        key = spec['key']
        defaults = {k: v for k, v in spec.items() if k != 'key'}
        _, created = Enemy.objects.update_or_create(key=key, defaults=defaults)
        if created:
            created_count += 1
        else:
            updated_count += 1
    print(f'[migration 0092] Seeded {created_count} progression enemies '
          f'(updated {updated_count} existing)')

    # ── 2. 既存 goblin の level_scaling 緩和 ────────────────────
    try:
        goblin = Enemy.objects.get(key='goblin')
        old_scaling = goblin.level_scaling
        goblin.level_scaling = 0.5
        goblin.save(update_fields=['level_scaling'])
        print(f'[migration 0092] Updated goblin level_scaling: '
              f'{old_scaling} -> 0.5 (FEAT-320 緩和)')
    except Enemy.DoesNotExist:
        # 通常ありえないが防御的に
        print('[migration 0092] WARNING: goblin not found, skipping scaling update')


def _delete_progression_enemies(apps, schema_editor):
    """rollback: 3 体削除 + goblin scaling を 1.0 に戻す。

    Battle / BattleLog で参照されている場合は PROTECT 制約で失敗する可能性あり。
    防御的に try/except でラップし、後続 rollback を止めない。
    """
    Enemy = apps.get_model('api', 'Enemy')
    keys = [spec['key'] for spec in _PROGRESSION_ENEMIES]
    try:
        deleted, _ = Enemy.objects.filter(key__in=keys).delete()
        print(f'[migration 0092 reverse] Deleted {deleted} enemy rows')
    except Exception as e:  # noqa: BLE001
        print(f'[migration 0092 reverse] Delete failed (kept rows): {e}')

    # goblin scaling を 1.0 に戻す
    try:
        Enemy.objects.filter(key='goblin').update(level_scaling=1.0)
        print('[migration 0092 reverse] Restored goblin level_scaling: 0.5 -> 1.0')
    except Exception as e:  # noqa: BLE001
        print(f'[migration 0092 reverse] Goblin scaling restore failed: {e}')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0091_diamond_path_tracking'),
    ]

    operations = [
        migrations.RunPython(_seed_progression_enemies, _delete_progression_enemies),
    ]
