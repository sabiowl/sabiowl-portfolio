"""【BUG-131 (2026-06-17)】Weekly SSR character 5.00% → 0.50% に削減。

【背景】
PM 判断: Weekly のキャラ排出サプライズ性を強める方向。Monthly 確定 (FEAT-433、
21 日達成で SSR 確定チケット) + Shop ダイヤ購入 (BUG-131 で 6000💎、migration
0144 同梱) との 3 経路バランス再調整の一環。

【weight 再配分方針 (Option B: SSR コンソリエーション吸収)】
合計 weight 120 → 200 にスケールアップし、R / SR tier の % 比率は厳密維持、
character から解放された 4.5% は SSR 非キャラ枠 (diamond / xp_boost / weapon)
が比例吸収。R/SR の体感 (= 共通報酬) は変えず character のみレア化。

| Entry                  | 旧 weight | 新 weight | 旧 % (/120) | 新 % (/200) |
|------------------------|-----------|-----------|-------------|-------------|
| R diamond × 30         |        22 |        36 |      18.33% |      18.00% |
| R xp_boost ×2          |        18 |        30 |      15.00% |      15.00% |
| R title                |        10 |        17 |       8.33% |       8.50% |
| SR diamond × 80        |        32 |        53 |      26.67% |      26.50% |
| SR xp_boost ×3         |        10 |        17 |       8.33% |       8.50% |
| SR title               |         5 |         8 |       4.17% |       4.00% |
| SSR diamond × 200      |         8 |        18 |       6.67% |       9.00% |
| SSR xp_boost ×5        |         5 |        11 |       4.17% |       5.50% |
| SSR weapon             |         4 |         9 |       3.33% |       4.50% |
| SSR character          |         6 |         1 |       5.00% |  **0.50%**  |
| Total                  |       120 |       200 |     100.00% |     100.00% |

検証: 36+30+17+53+17+8+18+11+9+1 = 200、character 1/200 = 0.5% (厳密).
Tier 内訳: R 83/200=41.5% (旧 41.67%)、SR 78/200=39.0% (旧 39.17%)、SSR 39/200=19.5% (旧 19.17%).

【CLAUDE.md「master/seed data 例外条項」適用】
1. 対象は GachaReward master/seed data の weight のみ、user-generated content
   (GachaHistory / PendingDuplicateReward) は破壊しない。
2. 全 FK 走査: GachaHistory.reward / PendingDuplicateReward.reward → GachaReward
   いずれも本 migration は UPDATE のみで DELETE なし → CASCADE/PROTECT 影響なし。
3. 冪等性: (ticket_type, rarity, reward_type, name, detail) で一意 filter() →
   update() で再 apply 安全 (BUG-94/95/97/98 と同パターン)。

【ロールバック】
直前の BUG-98 (migration 0133) 状態 (合計 120、character 6) に完全復元。
"""
from django.db import migrations


# (ticket_type, rarity, reward_type, name, detail) -> new_weight
_NEW_WEIGHTS = {
    ('weekly', 'R',   'diamond',   'ダイヤ',          '× 30'):              36,
    ('weekly', 'R',   'xp_boost',  'XPブースト×2',   '30分 ×1.5倍'):       30,
    ('weekly', 'R',   'title',     '限定称号',        '「習慣の守護者」'):  17,
    ('weekly', 'SR',  'diamond',   'ダイヤ',          '× 80'):              53,
    ('weekly', 'SR',  'xp_boost',  'XPブースト×3',   '45分 ×1.5倍'):       17,
    ('weekly', 'SR',  'title',     '限定称号',        '「鋼の意志」'):      8,
    ('weekly', 'SSR', 'diamond',   'ダイヤ',          '× 200'):             18,
    ('weekly', 'SSR', 'xp_boost',  'XPブースト×5',   '75分 ×1.5倍'):       11,
    ('weekly', 'SSR', 'weapon',    '竜殺しの剣',      'ATK +50'):           9,
    ('weekly', 'SSR', 'character', 'レアキャラ (SSR)', '未開放キャラから1体'): 1,
}

# BUG-98 (migration 0133) 状態への reverse 用 (合計 120、character 6)
_OLD_WEIGHTS = {
    ('weekly', 'R',   'diamond',   'ダイヤ',          '× 30'):              22,
    ('weekly', 'R',   'xp_boost',  'XPブースト×2',   '30分 ×1.5倍'):       18,
    ('weekly', 'R',   'title',     '限定称号',        '「習慣の守護者」'):  10,
    ('weekly', 'SR',  'diamond',   'ダイヤ',          '× 80'):              32,
    ('weekly', 'SR',  'xp_boost',  'XPブースト×3',   '45分 ×1.5倍'):       10,
    ('weekly', 'SR',  'title',     '限定称号',        '「鋼の意志」'):      5,
    ('weekly', 'SSR', 'diamond',   'ダイヤ',          '× 200'):             8,
    ('weekly', 'SSR', 'xp_boost',  'XPブースト×5',   '75分 ×1.5倍'):       5,
    ('weekly', 'SSR', 'weapon',    '竜殺しの剣',      'ATK +50'):           4,
    ('weekly', 'SSR', 'character', 'レアキャラ (SSR)', '未開放キャラから1体'): 6,
}


def _apply_new_weights(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')
    total = 0
    for (ticket_type, rarity, reward_type, name, detail), weight in _NEW_WEIGHTS.items():
        updated = GachaReward.objects.filter(
            ticket_type=ticket_type,
            rarity=rarity,
            reward_type=reward_type,
            name=name,
            detail=detail,
        ).update(weight=weight)
        total += updated
    print(
        f'[migration 0145 BUG-131] Updated Weekly weights for 0.5% character drop'
        f' ({total} row(s) updated, expected 10)'
    )


def _revert_old_weights(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')
    for (ticket_type, rarity, reward_type, name, detail), weight in _OLD_WEIGHTS.items():
        GachaReward.objects.filter(
            ticket_type=ticket_type,
            rarity=rarity,
            reward_type=reward_type,
            name=name,
            detail=detail,
        ).update(weight=weight)
    print('[migration 0145 reverse] Reverted Weekly weights to BUG-98 (5.0% character drop)')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0144_char_price_6000'),
    ]

    operations = [
        migrations.RunPython(_apply_new_weights, _revert_old_weights),
    ]
