"""【FEAT-312】Weekly Character 報酬 2 件を `GachaReward` に追加。

`_ensure_gacha_rewards()` は「ticket_type=weekly の GachaReward が 1 件もない
場合のみ bulk_create する」設計のため、既に Weekly レコード seed 済の環境
（Render production 含む）には新規 2 件が流入しない。本 migration で
冪等に `get_or_create` する。

指示書 §Phase 1-4 / §Pre-mortem #3 対応:
  - `get_or_create(ticket_type='weekly', rarity, name)` で冪等
  - rerun でも複製しない (lookup keys で既存判定)
"""
from django.db import migrations


_NEW_WEEKLY_CHARACTER_REWARDS = [
    dict(
        ticket_type='weekly',
        rarity='SR',
        reward_type='character',
        container='stone',
        name='守護獣 (SR)',
        detail='ランダム1体',
        icon='🐾',
        weight=12,
        value=0,
        is_active=True,
    ),
    dict(
        ticket_type='weekly',
        rarity='SSR',
        reward_type='character',
        container='stone',
        name='レアキャラ (SSR)',
        detail='ランダム1体',
        icon='✨',
        weight=4,
        value=0,
        is_active=True,
    ),
]


def _add_weekly_characters(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')
    created_count = 0
    for spec in _NEW_WEEKLY_CHARACTER_REWARDS:
        # `get_or_create` の lookup keys は (ticket_type, rarity, name) の 3 軸で
        # 「同名 Weekly SR Character は 1 件まで」を冪等に保証する。defaults で
        # 残りフィールドを明示。
        _, created = GachaReward.objects.get_or_create(
            ticket_type=spec['ticket_type'],
            rarity=spec['rarity'],
            name=spec['name'],
            defaults={
                k: v for k, v in spec.items()
                if k not in ('ticket_type', 'rarity', 'name')
            },
        )
        if created:
            created_count += 1
    print(f'[migration 0090] Added {created_count} weekly character GachaReward '
          f'(skipped {len(_NEW_WEEKLY_CHARACTER_REWARDS) - created_count} already-existing)')


def _delete_weekly_characters(apps, schema_editor):
    """rollback: 本 FEAT で追加した 2 件のみ削除（既存 Weekly 報酬は保持）。"""
    GachaReward = apps.get_model('api', 'GachaReward')
    names = [spec['name'] for spec in _NEW_WEEKLY_CHARACTER_REWARDS]
    deleted, _ = GachaReward.objects.filter(
        ticket_type='weekly', name__in=names,
    ).delete()
    print(f'[migration 0090 reverse] Deleted {deleted} weekly character GachaReward')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0089_player_active_job'),
    ]

    operations = [
        migrations.RunPython(_add_weekly_characters, _delete_weekly_characters),
    ]
