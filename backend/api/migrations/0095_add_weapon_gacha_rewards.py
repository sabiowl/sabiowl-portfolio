# Generated for FEAT-326: 武器装備システム (Phase 3 ガチャ排出)
"""【FEAT-326】 ガチャ報酬に weapon 排出 2 件を追加 + weight を再分配。

`_ensure_gacha_rewards()` ランタイム seed は「ticket_type が 1 件でも存在
すれば skip」する設計のため、既存 Daily / Weekly レコード環境では新規
weapon 報酬が永久 dead code 状態になる。本 migration で `get_or_create`
による冪等 upsert を実施 (FEAT-312 migration 0090 と同パターン)。

追加:
    - Daily SR weapon (mythril_sword, weight=4, weapon_key='mythril_sword')
    - Weekly SSR weapon (dragon_slayer, weight=4, weapon_key='dragon_slayer')

再分配 (Pre-mortem #3 weight 合計の不変式維持):
    - Daily SR exp +350: weight 5 → 1  (Daily 合計 100 維持)
    - Weekly SSR diamond ×200: weight 10 → 6  (Weekly 合計 116 維持)
"""
from django.db import migrations


_NEW_REWARDS = [
    {
        'lookup': {'ticket_type': 'daily', 'name': 'ミスリルの剣',
                   'reward_type': 'weapon'},
        'defaults': {
            'rarity':      'SR',
            'container':   'stone',
            'detail':      'ATK +35',
            'icon':        '⚔️',
            'weight':      4,
            'value':       0,
            'weapon_key':  'mythril_sword',
            'is_active':   True,
        },
    },
    {
        'lookup': {'ticket_type': 'weekly', 'name': '竜殺しの剣',
                   'reward_type': 'weapon'},
        'defaults': {
            'rarity':      'SSR',
            'container':   'stone',
            'detail':      'ATK +50',
            'icon':        '⚔️',
            'weight':      4,
            'value':       0,
            'weapon_key':  'dragon_slayer',
            'is_active':   True,
        },
    },
]


def _seed_weapon_rewards(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')

    # ── weapon 報酬 2 件追加 (冪等、get_or_create で重複検出) ───────────
    created_count = 0
    for entry in _NEW_REWARDS:
        _obj, created = GachaReward.objects.get_or_create(
            **entry['lookup'],
            defaults=entry['defaults'],
        )
        if created:
            created_count += 1
    print(
        f'[migration 0095] Added {created_count} weapon GachaReward '
        f'(skipped {len(_NEW_REWARDS) - created_count} already-existing)'
    )

    # ── weight 再分配 (FEAT-326 §2.2 Pre-mortem #3 合計値の契約) ────────
    # Daily SR exp +350: weight 5 → 1
    updated_daily = GachaReward.objects.filter(
        ticket_type='daily', reward_type='exp', value=350,
    ).update(weight=1)
    # Weekly SSR diamond ×200: weight 10 → 6
    updated_weekly = GachaReward.objects.filter(
        ticket_type='weekly', reward_type='diamond', value=200,
    ).update(weight=6)
    print(
        f'[migration 0095] Rebalanced weights: Daily SR exp 350 → 1 '
        f'({updated_daily} row), Weekly SSR diamond 200 → 6 ({updated_weekly} row)'
    )


def _revert_weapon_rewards(apps, schema_editor):
    """rollback: 本 migration で追加した weapon 報酬を削除 + 再分配を戻す。"""
    GachaReward = apps.get_model('api', 'GachaReward')

    # weapon 報酬削除
    keys = [r['lookup']['name'] for r in _NEW_REWARDS]
    deleted, _ = GachaReward.objects.filter(
        reward_type='weapon', name__in=keys,
    ).delete()
    print(f'[migration 0095 reverse] Deleted {deleted} weapon GachaReward')

    # weight 戻し
    GachaReward.objects.filter(
        ticket_type='daily', reward_type='exp', value=350,
    ).update(weight=5)
    GachaReward.objects.filter(
        ticket_type='weekly', reward_type='diamond', value=200,
    ).update(weight=10)


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0094_gacha_reward_weapon_key'),
    ]

    operations = [
        migrations.RunPython(_seed_weapon_rewards, _revert_weapon_rewards),
    ]
