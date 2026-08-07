"""【BUG-95 (2026-06-12)】Monthly SSR character (伝説キャラ) を is_active=False で廃止。

ユーザー認識「Monthly はダイヤ/ブースト/称号のみ」と実装の乖離を解消する。
migration 0111 (FEAT-389) で DB に直接 seed された「伝説キャラ (SSR)」weight=15
(約 13% の Monthly SSR pool) が排出継続していた。本 migration で廃止し、キャラ
入手経路を Monthly 天井 (交換券、FEAT-427) + Shop ダイヤ購入 (FEAT-389) の 2 経路
に集約する (BUG-94 の Weekly レアキャラ廃止と同一方針)。

weight=15 は再配分せず、Monthly 合計 115 → 100 に縮小 (CLAUDE.md「マンスリー:
SR=60% SSR=40%」設計復元、FEAT-389 で崩れていた比率を元に戻す)。

DB の旧 entry は `_pick_reward` が `GachaReward.objects.filter(is_active=True, ...)`
を真実値とするため、本 migration で `is_active=False` にすることで `_pick_reward`
の pool から除外される。`_ensure_gacha_rewards` は `get_or_create` で「欠落分のみ
追加」する idempotent 設計のため、_MONTHLY_REWARDS 配列にこの entry が元々無くても
DB entry が残り、ガチャから引かれ続けてしまう (BUG-94/FEAT-421 と同じ理由)。

master/seed data 例外条項 (CLAUDE.md) 適用:
  1. 対象は GachaReward master/seed data のみ (user-generated content 含まない)
  2. FK 走査: GachaHistory.reward / PendingDuplicateReward.reward → GachaReward
     本 migration は UPDATE のみで DELETE なし → CASCADE/PROTECT 影響なし
     (既存の GachaHistory レコードは過去の引きを記録するもので、is_active=False
      でも参照整合性は維持される)
  3. 冪等性: filter().update() で再 apply 安全
"""
from django.db import migrations


def _disable_monthly_legend_character(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')
    GachaReward.objects.filter(
        ticket_type='monthly',
        rarity='SSR',
        reward_type='character',
        name='伝説キャラ (SSR)',
    ).update(is_active=False)


def _enable_monthly_legend_character(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')
    GachaReward.objects.filter(
        ticket_type='monthly',
        rarity='SSR',
        reward_type='character',
        name='伝説キャラ (SSR)',
    ).update(is_active=True)


class Migration(migrations.Migration):
    dependencies = [('api', '0130_disable_ssr_rare_character')]
    operations = [
        migrations.RunPython(_disable_monthly_legend_character, _enable_monthly_legend_character),
    ]
