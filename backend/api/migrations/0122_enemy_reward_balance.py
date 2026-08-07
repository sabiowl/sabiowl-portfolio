"""【BUG-81 (2026-06-10)】Enemy 報酬曲線の単調増加性回復 (5 体上方修正)。

ユーザー報告「リザード戦士と鎧の騎士の順番が逆。鎧の方が経験値が少ない」
+ 「他の boss の並び方も適切か確認」を受けて、unlock_level 順の reward
(coins / exp) で発生していた逆転を全件解消する。

【真因】
旧 boss (migration 0083 / 0088 / 0109 で seed された 7 体: goblin_king /
dragon / shadow_mage / armored_knight / ice_witch / void_dragon / griffin)
は FEAT-332 以前の古い設計値を維持していた。一方で migration 0118
(FEAT-401) で追加された新 12 体は +5 ずつ綺麗な単調増加で設計された。
結果として両者を unlock_level 順に並べると 3 箇所で逆転が発生していた:

  - armored_knight (ulv 18) 30c/60xp ← ulv 17 lizard 40/85 より低い
  - ice_witch (ulv 25) 50c/120xp ← ulv 22 dark_knight と coin 同値
  - chimera (ulv 38) 85c/200xp ← ulv 35 griffin/void 100c より低い

さらに chimera を上方修正すると lich_king (ulv 42) 90c との逆転が発生、
lich_king を上方修正すると leviathan (ulv 48) 110c との逆転が連鎖、と
段階的に上方修正が必要 → 5 体上方修正で全体の単調増加性を回復する。

【修正値】
unlock_level 順、coin/xp 共に「次の Lv で必ず増加」を保証:

  Lv 14 ogre           35 /  70   (据置)
  Lv 17 lizard         40 /  85   (据置)
  Lv 18 armored_knight 30 /  60   →  45 /  95  ← BUG-81 修正
  Lv 20 dragon         80 / 150   (据置)
  Lv 22 dark_knight    50 / 100   (据置)
  Lv 25 ice_witch      50 / 120   →  55 / 125  ← BUG-81 修正
  Lv 28 fire_demon     60 / 130   (据置)
  Lv 32 vampire_lord   70 / 145   (据置)
  Lv 35 griffin       100 / 200   (据置)
  Lv 35 void_dragon   100 / 300   (据置、xp 突出設計維持)
  Lv 38 chimera        85 / 200   → 105 / 215  ← BUG-81 修正
  Lv 42 lich_king      90 / 230   → 115 / 245  ← BUG-81 修正
  Lv 48 leviathan     110 / 280   → 125 / 280  ← BUG-81 修正 (xp 据置)

leviathan の xp 280 は新 lich xp 245 より +35 で順序維持 = xp は据置で OK。

【master/seed data 例外条項 (CLAUDE.md) 適用】
  1. 対象は Enemy master/seed data のみ (user-generated content 含まない)
  2. FK 走査: Battle.enemy / BattleLog.enemy / Battle.battle_log.enemy (PROTECT)
     本 migration は UPDATE のみで DELETE なし → CASCADE / PROTECT 影響なし
  3. 冪等性: filter().update() で再 apply 安全
"""
from django.db import migrations


# (key, new_reward_coins, new_reward_exp)
_ENEMY_REWARD_UPDATES = [
    ('armored_knight',  45,  95),
    ('ice_witch',       55, 125),
    ('chimera',        105, 215),
    ('lich_king',      115, 245),
    ('leviathan',      125, 280),
]


# rollback 用旧値
_ENEMY_REWARD_PREVIOUS = [
    ('armored_knight',  30,  60),
    ('ice_witch',       50, 120),
    ('chimera',         85, 200),
    ('lich_king',       90, 230),
    ('leviathan',      110, 280),
]


def _apply_reward_balance(apps, schema_editor):
    Enemy = apps.get_model('api', 'Enemy')
    for key, coins, exp in _ENEMY_REWARD_UPDATES:
        Enemy.objects.filter(key=key).update(
            reward_coins=coins, reward_exp=exp,
        )


def _revert_reward_balance(apps, schema_editor):
    Enemy = apps.get_model('api', 'Enemy')
    for key, coins, exp in _ENEMY_REWARD_PREVIOUS:
        Enemy.objects.filter(key=key).update(
            reward_coins=coins, reward_exp=exp,
        )


class Migration(migrations.Migration):
    # 【BUG-81 hotfix (2026-06-10)】FEAT-419 (0121_timeline_on_time_bonus) と
    # leaf node 衝突したため renumber + dependencies 修正
    # (CLAUDE.md「並列稼働の場合の注意点 = 後発が rebase + renumber」準拠)。
    dependencies = [('api', '0121_timeline_on_time_bonus')]
    operations = [
        migrations.RunPython(_apply_reward_balance, _revert_reward_balance),
    ]
