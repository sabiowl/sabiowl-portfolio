"""【BUG-94 (2026-06-12)】Weekly SSR character (レアキャラ) を is_active=False で廃止。

ユーザー認識「Weekly ではキャラ排出なし」と実装の乖離を解消する。FEAT-421 で
SR 守護獣のみ廃止したが、SSR レアキャラ weight=4 が排出継続していた (約 3.4%)。
本 migration で SSR レアキャラも廃止し、キャラ入手経路を Monthly 天井 (交換券、
FEAT-427) + Shop ダイヤ購入 (FEAT-389) の 2 経路に集約する。

weight=4 は SR diamond (6→10) で再配分済 (gacha.py で _WEEKLY_REWARDS を修正、
Weekly 合計 116 維持)。

DB の旧 entry は `_pick_reward` が `GachaReward.objects.filter(is_active=True, ...)`
を真実値とするため、本 migration で `is_active=False` にすることで `_pick_reward`
の pool から除外される。`_ensure_gacha_rewards` は `get_or_create` で「欠落分のみ
追加」する idempotent 設計のため、_WEEKLY_REWARDS 配列から削除しただけでは DB
entry が残り、ガチャから引かれ続けてしまう (FEAT-421 と同じ理由)。

master/seed data 例外条項 (CLAUDE.md) 適用:
  1. 対象は GachaReward master/seed data のみ (user-generated content 含まない)
  2. FK 走査: GachaHistory.reward / PendingDuplicateReward.reward → GachaReward
     本 migration は UPDATE のみで DELETE なし → CASCADE/PROTECT 影響なし
     (既存の GachaHistory レコードは過去の引きを記録するもので、is_active=False
      でも参照整合性は維持される)
  3. 冪等性: filter().update() で再 apply 安全
"""
from django.db import migrations


def _disable_ssr_rare_character(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')
    # SSR レアキャラを無効化
    GachaReward.objects.filter(
        ticket_type='weekly',
        rarity='SSR',
        reward_type='character',
        name='レアキャラ (SSR)',
    ).update(is_active=False)
    # SSR diamond の weight を 6 → 10 に再配分 (Weekly 合計 116 維持)
    GachaReward.objects.filter(
        ticket_type='weekly',
        rarity='SSR',
        reward_type='diamond',
        name='ダイヤ',
        detail='× 200',
    ).update(weight=10)


def _enable_ssr_rare_character(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')
    GachaReward.objects.filter(
        ticket_type='weekly',
        rarity='SSR',
        reward_type='character',
        name='レアキャラ (SSR)',
    ).update(is_active=True)
    GachaReward.objects.filter(
        ticket_type='weekly',
        rarity='SSR',
        reward_type='diamond',
        name='ダイヤ',
        detail='× 200',
    ).update(weight=6)


class Migration(migrations.Migration):
    dependencies = [('api', '0129_shop_progressive_pricing')]
    operations = [
        migrations.RunPython(_disable_ssr_rare_character, _enable_ssr_rare_character),
    ]
