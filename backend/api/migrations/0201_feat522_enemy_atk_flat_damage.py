"""【FEAT-522 (2026-08-07)】敵 ATK を「設定値 = 実ダメージ」にする。

【背景】
`scaled_atk = base_atk * level_scaling * player.level` は FEAT-295 (バトル MVP 初版、
`31a088a7`) のままで、設計判断ではなかった。admin に 12 と入れた ice_witch が Lv 25 で
150 を与え、Lv 48 では設定値の 24 倍になる。**admin の数字から実ダメージが読めない**。

FEAT-400 v3 §2.3 が「Lv 連動で緊張感保持」として据え置いた際の worked example
(Player HP 280) は 2026-06-13 の HP 2 倍化前の値で、現在は 560。緊張感の上げ幅は
Lv 18→50 で 4 ポイントしかない。一方 HP を固定した根拠は「Player 成長で撃数自然減」
であり、ATK 側と方向が逆を向いていた。

【本 migration がやること】
1. 全 24 体の `base_atk` を **実機検証済みの実ダメージ**に置き換える
2. 全 24 体の `level_scaling` を **0** にする (= 固定)
3. 3 field の help_text を新しい意味に合わせる

新式 (views/battle/start.py):

    scaled_atk = int(base_atk * (1 + level_scaling * max(0, level - unlock_level)))

`level_scaling` は式から外していない。外すと死にフィールドになり、削除のための
別 FEAT が必要になるため (FEAT-478 → FEAT-488 の前例)。**unlock_level 基点**に
することで意味を持たせ直した:
  0     = 固定 (全 24 体の既定、本 FEAT の要件)
  0 超  = その敵だけ unlock_level 以降に緩やかに追随
どちらでも「解禁時のダメージ = 設定値」は常に成立する。

【🔴 値は理想値ではなく実機検証済みの値】
`_NEW_ATK` はユーザーが 2026-08-07 に現行式で実機確認し「丁度良い」と判断した
**実ダメージ**そのもの。整数丸めの都合で推奨計算の理想値とは最大 3 ずれている
(armored_knight 理想 33 / 検証済 36)。**理想値に寄せ直さないこと。**
ユーザーが確認したのは 36 の手応えである。

slime / bat / rat (1 / 3 / 4) は unlock_level が 0-3 で全レベル帯から挑まれるため
現行式では低く抑えるしかなかった値だが、実機検証がこの値で行われているのでそのまま
移す。上げるかどうかは実機の感触が出てから別途判断する。

【master/seed data 例外条項 (FEAT-391) 3 条件充足】
- ✅ master data のみ: Enemy master 24 体の数値 field のみ。user data (Battle /
     PlayerProfile) は一切触らない
- ✅ FK 網羅: 対象 field は非 FK (IntegerField / FloatField)、参照整合性影響なし
- ✅ 冪等性: key 一致で `_NEW_ATK` の値を代入するだけ。再 run しても結果は同じ

【進行中のバトルへの影響】
`Battle.enemy_atk_init` は出陣時にスナップショットされるため、deploy 時点で進行中の
戦闘は旧値のまま完走する。`BattleFinishView` の damage 検証 (`_MAX_DAMAGE_MULTIPLIER`)
は `enemy_hp_init` 基準なので ATK 変更の影響を受けない。
契約テスト `test_enemy_atk_flat_damage.py` がこの不変条件を固定している。
"""
from django.db import migrations, models


# 【🔴 指示書 §4 のブロックをそのままコピーしている。理想値に寄せ直さないこと。】
_NEW_ATK = {
    'slime': 1,          'bat': 3,           'rat': 4,
    'goblin': 5,         'weak_goblin': 7,   'skeleton': 14,
    'giant_slime': 16,   'young_orc': 20,    'wolf': 11,
    'goblin_king': 18,   'ogre': 35,         'shadow_mage': 22,
    'lizard_warrior': 34,'armored_knight': 36,'dragon': 40,
    'dark_knight': 44,   'ice_witch': 37,    'fire_demon': 56,
    'vampire_lord': 48,  'void_dragon': 87,  'griffin': 52,
    'chimera': 95,       'lich_king': 126,   'leviathan': 240,
}

# rollback 用。FEAT-522 適用前の値 (migration 0117 / 0118 seed + FEAT-401 v2 調整後)。
_OLD_ATK = {
    'slime': 3,          'bat': 3,           'rat': 3,
    'goblin': 8,         'weak_goblin': 5,   'skeleton': 4,
    'giant_slime': 9,    'young_orc': 8,     'wolf': 5,
    'goblin_king': 9,    'ogre': 8,          'shadow_mage': 10,
    'lizard_warrior': 8, 'armored_knight': 9, 'dragon': 10,
    'dark_knight': 7,    'ice_witch': 12,    'fire_demon': 7,
    'vampire_lord': 7,   'void_dragon': 11,  'griffin': 11,
    'chimera': 7,        'lich_king': 6,     'leviathan': 6,
}
_OLD_SCALING = 0.5


def _apply_flat_damage(apps, schema_editor):
    """base_atk を実ダメージに、level_scaling を 0 (固定) にする。"""
    Enemy = apps.get_model('api', 'Enemy')
    updated = 0
    missing = []
    for key, atk in _NEW_ATK.items():
        enemy = Enemy.objects.filter(key=key).first()
        if enemy is None:
            missing.append(key)
            continue
        enemy.base_atk = atk
        enemy.level_scaling = 0.0
        enemy.save(update_fields=['base_atk', 'level_scaling'])
        updated += 1

    # 【Pre-mortem #2】`level_scaling` が 1 体でも 0.5 のまま残ると、新式は
    # `1 + 0.5 * (Lv - unlock)` なので解禁 +10 Lv で 6 倍のダメージになる。
    # `_NEW_ATK` に載っていない enemy (将来追加分) も取りこぼさないよう掃く。
    stragglers = Enemy.objects.exclude(level_scaling=0.0).count()
    if stragglers:
        Enemy.objects.exclude(level_scaling=0.0).update(level_scaling=0.0)

    print(f'[migration 0201 FEAT-522] base_atk 更新 {updated} 体 / '
          f'level_scaling=0 への掃き出し {stragglers} 体')
    if missing:
        print(f'[migration 0201 FEAT-522] DB に存在しなかった key: {missing}')


def _rollback_level_scaled_damage(apps, schema_editor):
    """rollback: FEAT-522 適用前の base_atk と level_scaling=0.5 に戻す。"""
    Enemy = apps.get_model('api', 'Enemy')
    updated = 0
    for key, atk in _OLD_ATK.items():
        enemy = Enemy.objects.filter(key=key).first()
        if enemy is None:
            continue
        enemy.base_atk = atk
        enemy.level_scaling = _OLD_SCALING
        enemy.save(update_fields=['base_atk', 'level_scaling'])
        updated += 1
    print(f'[migration 0201 rollback] {updated} 体を FEAT-522 適用前の値に戻した')


class Migration(migrations.Migration):
    dependencies = [
        ('api', '0200_feat516_master_data_en'),
    ]
    operations = [
        migrations.AlterField(
            model_name='enemy',
            name='base_atk',
            field=models.IntegerField(
                default=10,
                help_text='1 発のダメージそのもの (設定値 = 実ダメージ、FEAT-522)',
            ),
        ),
        migrations.AlterField(
            model_name='enemy',
            name='base_hp',
            field=models.IntegerField(
                default=100,
                help_text='戦闘中 HP。Lv 連動しない (FEAT-400 v3)',
            ),
        ),
        migrations.AlterField(
            model_name='enemy',
            name='level_scaling',
            field=models.FloatField(
                default=0.0,
                help_text=(
                    '0 = 固定 (推奨・全 24 体の既定) / '
                    '0 より大きい値は unlock_level 以降だけ緩やかに追随 (FEAT-522)'
                ),
            ),
        ),
        migrations.RunPython(_apply_flat_damage, _rollback_level_scaled_damage),
    ]
