"""【FEAT-401 v2 (2026-05-31)】Enemy 12 体追加 (12 → 24 体)。

v2 バランス調整 (2026-05-31):
  zako 系: unlock 撃数 3.8-4.4 (v1) → 5.0-5.1 (v2) に引き上げ (base_hp 増加)
  mid_boss/boss/hidden_boss 系:
    - 撃数を「unlock で 6 撃辛い」目標に合わせ HP 引き上げ
    - base_atk を削減し Player が 3-4 turn 生存できる設計に

設計指針:
- Lv 1-48 で 2-3 Lv ごとに新敵解禁 = 「次の目標」常時可視化
- 属性多様化: 飛行 (bat), 不死 (skeleton/vampire_lord/lich_king), 獣 (wolf/chimera),
  巨人 (ogre/leviathan), 物理特化 (dark_knight), 魔法特化 (fire_demon)
- FEAT-400 v3 計算式 (HP 固定、scaled_hp = base_hp) に整合
- master/seed data 例外条項 (CLAUDE.md) 適用:
    1. 対象が master/seed data のみ (user-generated content を含まない)
    2. DELETE なし (INSERT のみ)、FK 影響なし
    3. 冪等性: update_or_create で再 apply 安全

依存: migration 0117 (FEAT-400 v3 全 12 体バランス再調整) 適用後に本 migration を apply。
"""
from django.db import migrations


# v2 数値 (§2.2 表)
# zako 系: base_hp 引き上げ (unlock 撃数 5.0-5.1 目標)、base_atk 変更なし
# mid_boss 系: base_hp 引き上げ (unlock 撃数 6.0-6.1 目標)、Lv14-17 は atk 変更なし
# mid_boss~hidden_boss 上位: HP 引き上げ + atk 削減 (Player 3-4 turn 生存確保)
_NEW_ENEMIES = [
    # Lv 2 ── 飛行系、素早い (spd 8) | unlock 撃数 5.0 (Lv2, ATK≈44, hp170)
    {
        'key': 'bat', 'name': 'コウモリ', 'sprite_key': 'enemy_bat',
        'base_hp': 170, 'base_atk': 3, 'base_spd': 8,
        'level_scaling': 0.5, 'reward_coins': 8, 'reward_exp': 18,
        'tier': 'zako', 'unlock_level': 2,
        'physical_resistance': 1.0, 'magical_resistance': 1.0, 'weak_ult_cost': None,
    },
    # Lv 3 ── 害獣系、標準 | unlock 撃数 5.0 (Lv3, ATK≈46, hp180)
    {
        'key': 'rat', 'name': 'ジャイアントラット', 'sprite_key': 'enemy_rat',
        'base_hp': 180, 'base_atk': 3, 'base_spd': 6,
        'level_scaling': 0.5, 'reward_coins': 10, 'reward_exp': 22,
        'tier': 'zako', 'unlock_level': 3,
        'physical_resistance': 1.0, 'magical_resistance': 1.0, 'weak_ult_cost': None,
    },
    # Lv 7 ── 不死系、物理耐性 | unlock 撃数 5.0 (Lv7, ATK≈54, hp220)
    {
        'key': 'skeleton', 'name': 'スケルトン', 'sprite_key': 'enemy_skeleton',
        'base_hp': 220, 'base_atk': 4, 'base_spd': 5,
        'level_scaling': 0.5, 'reward_coins': 18, 'reward_exp': 35,
        'tier': 'zako', 'unlock_level': 7,
        'physical_resistance': 0.8,   # 骨は物理耐性
        'magical_resistance': 1.0, 'weak_ult_cost': None,
    },
    # Lv 11 ── 群れの獣、物理特化 (spd 9) | unlock 撃数 5.1 (Lv11, ATK≈62, hp265)
    {
        'key': 'wolf', 'name': 'ダイアウルフ', 'sprite_key': 'enemy_wolf',
        'base_hp': 265, 'base_atk': 5, 'base_spd': 9,
        'level_scaling': 0.5, 'reward_coins': 30, 'reward_exp': 60,
        'tier': 'zako', 'unlock_level': 11,
        'physical_resistance': 1.0, 'magical_resistance': 1.0, 'weak_ult_cost': None,
    },
    # Lv 14 ── 巨人系、力自慢 | unlock 撃数 6.0 (Lv14, ATK≈68, hp350)、Player 生存 4.2 turn
    {
        'key': 'ogre', 'name': 'オーガ', 'sprite_key': 'enemy_ogre',
        'base_hp': 350, 'base_atk': 8, 'base_spd': 4,
        'level_scaling': 0.5, 'reward_coins': 35, 'reward_exp': 70,
        'tier': 'mid_boss', 'unlock_level': 14,
        'physical_resistance': 1.0, 'magical_resistance': 1.0, 'weak_ult_cost': None,
    },
    # Lv 17 ── 鱗の戦士、魔法耐性 | unlock 撃数 6.1 (Lv17, ATK≈74, hp390)、Player 生存 4.0 turn
    {
        'key': 'lizard_warrior', 'name': 'リザード戦士', 'sprite_key': 'enemy_lizard_warrior',
        'base_hp': 390, 'base_atk': 8, 'base_spd': 6,
        'level_scaling': 0.5, 'reward_coins': 40, 'reward_exp': 85,
        'tier': 'mid_boss', 'unlock_level': 17,
        'physical_resistance': 1.0,
        'magical_resistance': 0.8,    # 鱗で魔法耐性
        'weak_ult_cost': None,
    },
    # Lv 22 ── armored_knight 上位 | unlock 撃数 6.0 (Lv22, ATK≈84, hp440)、atk 7 (Player 生存 4.2 turn)
    {
        'key': 'dark_knight', 'name': '闇の騎士', 'sprite_key': 'enemy_dark_knight',
        'base_hp': 440, 'base_atk': 7, 'base_spd': 7,
        'level_scaling': 0.5, 'reward_coins': 50, 'reward_exp': 100,
        'tier': 'mid_boss', 'unlock_level': 22,
        'physical_resistance': 0.7,   # 黒鎧で物理耐性
        'magical_resistance': 1.0, 'weak_ult_cost': None,
    },
    # Lv 28 ── ice_witch の対比、魔法耐性 | unlock 撃数 5.9 (Lv28, ATK≈96, hp510)、atk 7 (生存 3.9t)
    {
        'key': 'fire_demon', 'name': '炎の悪魔', 'sprite_key': 'enemy_fire_demon',
        'base_hp': 510, 'base_atk': 7, 'base_spd': 9,
        'level_scaling': 0.5, 'reward_coins': 60, 'reward_exp': 130,
        'tier': 'boss', 'unlock_level': 28,
        'physical_resistance': 1.0,
        'magical_resistance': 0.6,    # 炎で魔法耐性
        'weak_ult_cost': None,
    },
    # Lv 32 ── 不死系上位 | unlock 撃数 6.0 (Lv32, ATK≈104, hp560)、atk 7 (生存 3.75t)
    {
        'key': 'vampire_lord', 'name': '吸血鬼の王', 'sprite_key': 'enemy_vampire_lord',
        'base_hp': 560, 'base_atk': 7, 'base_spd': 11,
        'level_scaling': 0.5, 'reward_coins': 70, 'reward_exp': 145,
        'tier': 'boss', 'unlock_level': 32,
        'physical_resistance': 0.7,   # 不死で物理耐性
        'magical_resistance': 1.0, 'weak_ult_cost': None,
    },
    # Lv 38 ── 合成獣、両耐性 | unlock 撃数 6.0 (Lv38, ATK≈116, hp640)、atk 7 (生存 3.6t)
    {
        'key': 'chimera', 'name': 'キメラ', 'sprite_key': 'enemy_chimera',
        'base_hp': 640, 'base_atk': 7, 'base_spd': 8,
        'level_scaling': 0.5, 'reward_coins': 85, 'reward_exp': 200,
        'tier': 'hidden_boss', 'unlock_level': 38,
        'physical_resistance': 0.85,  # 合成獣で両耐性
        'magical_resistance': 0.85, 'weak_ult_cost': None,
    },
    # Lv 42 ── 死霊術師の王 | unlock 撃数 6.1 (Lv42, ATK≈124, hp700)、atk 6 (生存 4.1t)
    {
        'key': 'lich_king', 'name': 'リッチキング', 'sprite_key': 'enemy_lich_king',
        'base_hp': 700, 'base_atk': 6, 'base_spd': 7,
        'level_scaling': 0.5, 'reward_coins': 90, 'reward_exp': 230,
        'tier': 'hidden_boss', 'unlock_level': 42,
        'physical_resistance': 1.0,
        'magical_resistance': 0.5,    # 死霊術士で魔法耐性
        'weak_ult_cost': 4,           # thief (ultCost=4) で Critical
    },
    # Lv 48 ── 海の大怪物、物理ほぼ無効 | unlock 撃数 6.0 (Lv48, ATK≈136, hp750)、atk 6 (生存 4.0t)
    {
        'key': 'leviathan', 'name': 'リヴァイアサン', 'sprite_key': 'enemy_leviathan',
        'base_hp': 750, 'base_atk': 6, 'base_spd': 5,
        'level_scaling': 0.5, 'reward_coins': 110, 'reward_exp': 280,
        'tier': 'hidden_boss', 'unlock_level': 48,
        'physical_resistance': 0.9,   # 海の怪物、物理ほぼ無効
        'magical_resistance': 1.0, 'weak_ult_cost': None,
    },
]


def _seed_new_enemies(apps, schema_editor):
    Enemy = apps.get_model('api', 'Enemy')
    for spec in _NEW_ENEMIES:
        Enemy.objects.update_or_create(
            key=spec['key'],
            defaults={k: v for k, v in spec.items() if k != 'key'},
        )


def _delete_new_enemies(apps, schema_editor):
    Enemy = apps.get_model('api', 'Enemy')
    keys = [s['key'] for s in _NEW_ENEMIES]
    Enemy.objects.filter(key__in=keys).delete()


class Migration(migrations.Migration):
    dependencies = [('api', '0117_enemy_balance_full_rebalance')]
    operations = [migrations.RunPython(_seed_new_enemies, _delete_new_enemies)]
