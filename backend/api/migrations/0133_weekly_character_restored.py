"""【BUG-98 (2026-06-13)】Weekly ガチャ 5% キャラ排出復活 (BUG-94 部分撤回)。

【背景】
ユーザー判断「Weekly 5% キャラ排出を維持したい」採択により、BUG-94 で is_active=False
にした「レアキャラ (SSR)」entry を以下に変換:
  - is_active: False → True
  - weight: 4 → 6
  - detail: ランダム1体 → 未開放キャラから1体 (BUG-97 と表記統一)

【Weekly SSR diamond の調整】
BUG-94 で SSR diamond × 200 weight 6 → 10 に再配分した +4 のうち、-2 を本 BUG で撤回:
  - weight: 10 → 8

【新合計 weight】
R 50 + SR 47 + SSR (diamond 8 + xp_boost 5 + weapon 4 + character 6 = 23) = 120
キャラ確率: 6/120 = 5.00% (厳密 5%、ユーザー要望と完全一致)

【BUG-94 ↔ BUG-98 の方針転換経緯】
BUG-94 (2026-06-12) で Weekly キャラ完全廃止 → ユーザー判断で「5% は維持したい」
採択により本 BUG で部分復活。BUG-97 (Monthly = キャラ専用) と協調で
「Monthly 確定 + Weekly 5% サプライズ + Shop 選択購入」の 3 経路に最終収束。

【CLAUDE.md master/seed data 例外条項適用】
1. 対象は GachaReward master/seed data のみ (user-generated content 含まない)
2. FK 走査: GachaHistory.reward / PendingDuplicateReward.reward → GachaReward
   本 migration は UPDATE のみで DELETE なし → CASCADE/PROTECT 影響なし
3. 冪等性: filter().update() で再 apply 安全 (BUG-94/95/97 と同パターン)
"""
from django.db import migrations


def _restore_weekly_character(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')

    # ── Step 1: 旧「レアキャラ (SSR)」を再活性化 + weight 調整 ──
    GachaReward.objects.filter(
        ticket_type='weekly',
        rarity='SSR',
        reward_type='character',
        name='レアキャラ (SSR)',
    ).update(
        is_active=True,
        weight=6,
        detail='未開放キャラから1体',  # BUG-97 と表記統一
    )

    # ── Step 2: SSR diamond × 200 weight を 10 → 8 に再配分 ──
    GachaReward.objects.filter(
        ticket_type='weekly',
        rarity='SSR',
        reward_type='diamond',
        name='ダイヤ',
        detail='× 200',
    ).update(weight=8)


def _reverse_weekly_character(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')

    # 旧仕様 (BUG-94 状態) に戻す
    GachaReward.objects.filter(
        ticket_type='weekly',
        rarity='SSR',
        reward_type='character',
        name='レアキャラ (SSR)',
    ).update(
        is_active=False,
        weight=4,
        detail='ランダム1体',
    )
    GachaReward.objects.filter(
        ticket_type='weekly',
        rarity='SSR',
        reward_type='diamond',
        name='ダイヤ',
        detail='× 200',
    ).update(weight=10)


class Migration(migrations.Migration):
    dependencies = [('api', '0132_monthly_character_only')]
    operations = [
        migrations.RunPython(_restore_weekly_character, _reverse_weekly_character),
    ]
