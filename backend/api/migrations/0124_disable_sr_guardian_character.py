"""【FEAT-421 (2026-06-10)】Weekly SR character (守護獣) を is_active=False で廃止。

ユーザー報告「SR の魔法石・守護獣の使い道が分からない」(2026-06-10) を受けて、
SR character (守護獣) ガチャ報酬を廃止する。weight=12 は SR diamond (20→32) で
再配分済 (gacha.py で _WEEKLY_REWARDS 配列を修正、Weekly 合計 116 維持)。

DB の旧 entry は `_pick_reward` が `GachaReward.objects.filter(is_active=True, ...)`
を真実値とするため、本 migration で `is_active=False` にすることで `_pick_reward`
の pool から除外される。`_ensure_gacha_rewards` は `get_or_create` で「欠落分のみ
追加」する idempotent 設計のため、_WEEKLY_REWARDS 配列から守護獣を削除しただけ
では DB entry が残り、ガチャから引かれ続けてしまう。

SSR レアキャラ (Weekly weight=4) はキャラ装備機構が実装済のため維持。

master/seed data 例外条項 (CLAUDE.md) 適用:
  1. 対象は GachaReward master/seed data のみ (user-generated content 含まない)
  2. FK 走査: GachaHistory.reward / PendingDuplicateReward.reward → GachaReward
     本 migration は UPDATE のみで DELETE なし → CASCADE/PROTECT 影響なし
     (既存の GachaHistory レコードは過去の引きを記録するもので、is_active=False
      でも参照整合性は維持される)
  3. 冪等性: filter().update() で再 apply 安全
"""
from django.db import migrations


def _disable_sr_guardian(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')
    GachaReward.objects.filter(
        ticket_type='weekly',
        rarity='SR',
        reward_type='character',
        name='守護獣 (SR)',
    ).update(is_active=False)


def _enable_sr_guardian(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')
    GachaReward.objects.filter(
        ticket_type='weekly',
        rarity='SR',
        reward_type='character',
        name='守護獣 (SR)',
    ).update(is_active=True)


class Migration(migrations.Migration):
    dependencies = [('api', '0123_streak_protection_pending')]
    operations = [
        migrations.RunPython(_disable_sr_guardian, _enable_sr_guardian),
    ]
