"""【BUG-97 (2026-06-12)】Monthly ガチャをキャラ専用ランダム排出に変更。

【背景】
ユーザー判断「マンスリーガチャ = キャラ専用、未開放からランダム、天井廃止」採択。
BUG-95 で is_active=False にした「伝説キャラ (SSR)」を以下に変換:
  - name: 「伝説キャラ (SSR)」 → 「マンスリーキャラ (SSR)」
  - is_active: False → True
  - weight: 15 → 100 (Monthly 唯一の active entry に)
  - reward_type: 'character' (維持)
  - value: 0 (= _pick_random_character_id でランダム選択シグナル、維持)

【Monthly 非キャラ報酬の廃止】
SR (ダイヤ×150 / XPブースト×5 / 月間称号) + SSR (ダイヤ×500 / XPブースト×10 / 伝説称号)
を全て is_active=False。_pick_reward は is_active=True フィルタ後の pool で動作するため、
これらは Monthly 抽選から除外される。

【FEAT-427 天井経路の扱い】
Monthly pity (10 連目) でのキャラ交換券配布は GachaPullView から削除済 (本 BUG Phase 1)。
PlayerProfile.character_exchange_tickets field と CharacterExchangeView endpoint は
維持 (既存在庫を持つユーザー保護)。新規入手経路なし、自然に dead path 化。

【CLAUDE.md master/seed data 例外条項適用】
1. 対象は GachaReward master/seed data のみ (user-generated content 含まない)
2. FK 走査: GachaHistory.reward / PendingDuplicateReward.reward → GachaReward
   本 migration は UPDATE のみで DELETE なし → CASCADE/PROTECT 影響なし
3. 冪等性: filter().update() で再 apply 安全 (BUG-95 と同パターン)
"""
from django.db import migrations


def _monthly_character_only(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')

    # ── Step 1: 旧「伝説キャラ (SSR)」を「マンスリーキャラ (SSR)」に変換 ──
    GachaReward.objects.filter(
        ticket_type='monthly',
        rarity='SSR',
        reward_type='character',
        name='伝説キャラ (SSR)',
    ).update(
        name='マンスリーキャラ (SSR)',
        detail='未開放キャラから1体',
        icon='✨',
        weight=100,
        is_active=True,
    )

    # ── Step 2: Monthly 非キャラ報酬を全て is_active=False ──
    GachaReward.objects.filter(
        ticket_type='monthly',
        reward_type__in=['diamond', 'xp_boost', 'title'],
    ).update(is_active=False)


def _reverse_monthly_character_only(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')

    # 旧仕様 (BUG-95 状態) に戻す
    GachaReward.objects.filter(
        ticket_type='monthly',
        rarity='SSR',
        reward_type='character',
        name='マンスリーキャラ (SSR)',
    ).update(
        name='伝説キャラ (SSR)',
        detail='ランダム1体',
        icon='👑',
        weight=15,
        is_active=False,
    )
    GachaReward.objects.filter(
        ticket_type='monthly',
        reward_type__in=['diamond', 'xp_boost', 'title'],
    ).update(is_active=True)


class Migration(migrations.Migration):

    dependencies = [('api', '0131_disable_monthly_legend_character')]

    operations = [
        migrations.RunPython(_monthly_character_only, _reverse_monthly_character_only),
    ]
