"""【FEAT-389 (2026-05-30)】Monthly ガチャに SSR キャラ排出を追加。

FEAT-312 (migration 0090) で Weekly に SR/SSR character を追加した同パターンを
Monthly に拡張。Monthly は「希少枠」のため SSR のみ (weight=15) で運用。
SR character は Weekly 限定として階層を保つ。

【get_or_create で冪等】
既存 Monthly レコード seed 済の環境 (Render production 含む) に対しても
冪等に挿入可能。lookup keys (ticket_type, rarity, name) で既存判定。

【weight 設計】
既存 Monthly SSR: diamond(25) + xp_boost(10) + title(5) = 40
新規 SSR character: weight=15
合計 SSR weight: 55 (旧 40 → 新 55)
"""
from django.db import migrations

_NEW_MONTHLY_CHARACTER_REWARD = dict(
    ticket_type='monthly',
    rarity='SSR',
    reward_type='character',
    container='stone',
    name='伝説キャラ (SSR)',
    detail='ランダム1体',
    icon='👑',
    weight=15,
    value=0,
    is_active=True,
)


def _add_monthly_character(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')
    lookup_keys = ('ticket_type', 'rarity', 'name')
    lookup = {k: _NEW_MONTHLY_CHARACTER_REWARD[k] for k in lookup_keys}
    defaults = {
        k: v for k, v in _NEW_MONTHLY_CHARACTER_REWARD.items()
        if k not in lookup_keys
    }
    _, created = GachaReward.objects.get_or_create(defaults=defaults, **lookup)
    if created:
        print('[migration 0111] Monthly SSR character 追加')
    else:
        print('[migration 0111] Monthly SSR character は既に存在、skip')


def _delete_monthly_character(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')
    deleted, _ = GachaReward.objects.filter(
        ticket_type='monthly',
        name=_NEW_MONTHLY_CHARACTER_REWARD['name'],
    ).delete()
    print(f'[migration 0111 reverse] Deleted {deleted} monthly character GachaReward')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0110_character_price_diamond_update'),
    ]

    operations = [
        migrations.RunPython(_add_monthly_character, _delete_monthly_character),
    ]
