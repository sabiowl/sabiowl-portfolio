"""【FEAT-332 (2026-05-27)】Enemy 解禁レベル変更 + ギリギリ倒せる強さ調整。

ユーザー報告: 「ギルド画面について、ゴブリンは Lv.5、巨大スライムは Lv.8、若オークは
Lv.10、ゴブリンキングは Lv.12、シャドウメイジ Lv.15、鎧の騎士は Lv.18 で解禁
してください。また、そのレベルでギリギリ倒せる強さに調整してください」

### 設計指針

#### 解禁レベル変更 (要件 1)

| Enemy            | 旧 unlock_level | 新 unlock_level | 経緯                                |
|------------------|----------------:|----------------:|-------------------------------------|
| goblin           | 0               | **5**           | 最弱位置の上方修正、Lv5 解禁体験    |
| giant_slime      | 0               | **8**           | zako 中位、Lv8 解禁                 |
| young_orc        | 10              | 10              | (変更なし、FEAT-320 既設定維持)     |
| goblin_king      | 8 (FEAT-329)    | **12**          | FEAT-329 で 8 設定 → 本要件で 12 に |
| shadow_mage      | 12 (FEAT-329)   | **15**          | FEAT-329 で 12 設定 → 本要件で 15 に |
| armored_knight   | 15 (FEAT-302)   | **18**          | FEAT-302 で 15 設定 → 本要件で 18 に |

採用後の段階階段 (Lv 0-35 で 11 段階):
- Lv 0:  slime
- Lv 5:  weak_goblin / **goblin**
- Lv 8:  **giant_slime**
- Lv 10: young_orc
- Lv 12: **goblin_king**
- Lv 15: **shadow_mage**
- Lv 18: **armored_knight**
- Lv 20: dragon
- Lv 25: ice_witch
- Lv 35: void_dragon

#### 強さ調整 (要件 2「ギリギリ倒せる強さ」)

「ギリギリ倒せる」目安: **5-7 turn 勝利 + player HP 30-50% 残**。

player スペック (Lv X):
- HP = `100 + X × 10` (BattleConstants.playerBaseHp=100 + playerHpPerLevel=10)
- ATK ≈ `20 + X × 2` (base_atk + level×2 + starter_sword +10)

戦闘中 enemy 値の式: `base × scaling × player.level`。

設計判断:
1. **scaling=0.5 全 enemy 統一** (FEAT-320 の goblin 緩和を踏襲、Lv5-18 帯で一貫性)
2. base_hp は「戦闘中 HP @ unlock_lv ≈ player HP @ unlock_lv」を目指す逆算
3. base_atk は 8-10 範囲、Lv 連動で適切な脅威感

| Enemy            | unlock_lv | base_hp | base_atk | scaling | 戦闘中 HP@Lv | 戦闘中 ATK@Lv | 勝利目安   |
|------------------|:---------:|:-------:|:--------:|:-------:|:------------:|:-------------:|:----------:|
| goblin           | 5         | 60      | 8        | 0.5     | 150          | 20            | 6 turn     |
| giant_slime      | 8         | 45      | 9        | 0.5     | 180          | 36            | 5 turn     |
| young_orc        | 10        | 40      | 8        | 0.5     | 200          | 40            | 5 turn     |
| goblin_king      | 12        | 37      | 9        | 0.5     | 222          | 54            | 5 turn     |
| shadow_mage      | 15        | 33      | 10       | 0.5     | 247          | 75            | 5 turn     |
| armored_knight   | 18        | 31      | 9        | 0.5     | 279          | 81            | 5 turn     |

(base_hp 数値上 boss < zako に見えるが、戦闘中 実 HP は unlock_lv に比例で増加。
base 値は「Lv 連動倍率の係数」として機能する設計、戦闘中の体感は OK。)

冪等性: `Enemy.objects.filter(key=...).update(...)` で値だけ更新、繰り返し実行で
同じ値に収束。reverse 関数で旧値に復元 (調査履歴トレース可能)。
"""
from django.db import migrations


_ENEMY_UPDATES = [
    # (key, unlock_level, base_hp, base_atk, level_scaling)
    ('goblin',          5,  60, 8,  0.5),
    ('giant_slime',     8,  45, 9,  0.5),
    ('young_orc',       10, 40, 8,  0.5),
    ('goblin_king',     12, 37, 9,  0.5),
    ('shadow_mage',     15, 33, 10, 0.5),
    ('armored_knight',  18, 31, 9,  0.5),
]


# rollback 用の旧値 (migration apply 前の状態)
_ENEMY_PREVIOUS = [
    # goblin (migration 0082 + 0092 で scaling 1.0 → 0.5、unlock_lv 0)
    ('goblin',          0,  60, 8,  0.5),
    # giant_slime (migration 0083 で 200/8/1.5、unlock_lv 0)
    ('giant_slime',     0,  200, 8,  1.5),
    # young_orc (FEAT-320 migration 0092 で 100/8/0.5、unlock_lv 10)
    ('young_orc',       10, 100, 8,  0.5),
    # goblin_king (FEAT-296 0083 で 350/14/1.8 + FEAT-329 0096 で unlock_lv 8)
    ('goblin_king',     8,  350, 14, 1.8),
    # shadow_mage (FEAT-296 0083 で 500/20/2.0 + FEAT-329 0096 で unlock_lv 12)
    ('shadow_mage',     12, 500, 20, 2.0),
    # armored_knight (FEAT-302 0088 で 400/20/1.3/unlock_lv 15)
    ('armored_knight',  15, 400, 20, 1.3),
]


def _apply_balance_tuning(apps, schema_editor):
    """6 体の unlock_level + base_hp + base_atk + level_scaling 更新。"""
    Enemy = apps.get_model('api', 'Enemy')
    updated = 0
    for key, ulv, hp, atk, scaling in _ENEMY_UPDATES:
        rows = Enemy.objects.filter(key=key).update(
            unlock_level=ulv,
            base_hp=hp,
            base_atk=atk,
            level_scaling=scaling,
        )
        if rows > 0:
            updated += rows
            print(f'[migration 0099] Updated {key}: unlock={ulv} hp={hp} '
                  f'atk={atk} scaling={scaling}')
        else:
            print(f'[migration 0099] WARNING: {key} not found, skipping')
    print(f'[migration 0099] Total {updated} enemies balance-tuned '
          f'(FEAT-332 ギリギリ倒せる強さ調整、5-7 turn 勝利目安)')


def _revert_balance_tuning(apps, schema_editor):
    """rollback: 旧値 (各 migration 当時の値) に復元。"""
    Enemy = apps.get_model('api', 'Enemy')
    reverted = 0
    for key, ulv, hp, atk, scaling in _ENEMY_PREVIOUS:
        rows = Enemy.objects.filter(key=key).update(
            unlock_level=ulv,
            base_hp=hp,
            base_atk=atk,
            level_scaling=scaling,
        )
        if rows > 0:
            reverted += rows
    print(f'[migration 0099 reverse] Restored {reverted} enemies to previous values.')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0098_player_login_streak_diamond'),
    ]

    operations = [
        migrations.RunPython(_apply_balance_tuning, _revert_balance_tuning),
    ]
