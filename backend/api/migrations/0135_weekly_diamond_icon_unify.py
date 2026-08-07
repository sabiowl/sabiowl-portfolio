"""【2026-06-14】Weekly ダイヤ entry の icon を 💎 統一。

【背景】
ユーザー報告「ウィークリーガチャでダイヤが排出された際、ダイヤなのに
星のイラストが表示されている」を受けて、Weekly SR diamond の icon を
🌟 → 💎 に変更。整合性のため SSR の 🔮 → 💎 も同時統一。

【対象】
- weekly / SR / diamond / 'ダイヤ' / '× 80': icon 🌟 → 💎
- weekly / SSR / diamond / 'ダイヤ' / '× 200': icon 🔮 → 💎

Daily / Monthly の diamond entry は既に 💎 なので変更不要。

【真実値】
backend/api/views/gacha.py の `_WEEKLY_REWARDS` 配列も同時更新済。
`_ensure_gacha_rewards` は欠落分のみ追加する設計のため、本 migration で
既存 DB entry の icon を直接 update することが必要。

【CLAUDE.md master/seed data 例外条項適用】
1. 対象は GachaReward master/seed data のみ (user-generated content 含まない)
2. FK 走査: GachaHistory.reward → GachaReward
   本 migration は UPDATE のみで DELETE なし → CASCADE/PROTECT 影響なし
3. 冪等性: filter().update() で再 apply 安全
"""
from django.db import migrations


def _unify_diamond_icons(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')
    # Weekly SR diamond × 80
    GachaReward.objects.filter(
        ticket_type='weekly',
        rarity='SR',
        reward_type='diamond',
        name='ダイヤ',
        detail='× 80',
    ).update(icon='💎')
    # Weekly SSR diamond × 200
    GachaReward.objects.filter(
        ticket_type='weekly',
        rarity='SSR',
        reward_type='diamond',
        name='ダイヤ',
        detail='× 200',
    ).update(icon='💎')


def _restore_diamond_icons(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')
    GachaReward.objects.filter(
        ticket_type='weekly',
        rarity='SR',
        reward_type='diamond',
        name='ダイヤ',
        detail='× 80',
    ).update(icon='🌟')
    GachaReward.objects.filter(
        ticket_type='weekly',
        rarity='SSR',
        reward_type='diamond',
        name='ダイヤ',
        detail='× 200',
    ).update(icon='🔮')


class Migration(migrations.Migration):
    dependencies = [('api', '0134_xp_boost_active_until')]
    operations = [
        migrations.RunPython(_unify_diamond_icons, _restore_diamond_icons),
    ]
