"""【FEAT-495 (2026-07-25)】Enemy master data の reward_exp に × 0.3 実効値を bake-in。

## 背景

FEAT-406 (2026-06-01) で「バトル EXP を × 0.3 に削減 (習慣を主 EXP 収入化)」と決めた
際、習慣 EXP 側は `EXP_PER_COUNT: 20 → 30` として DB 定数に直接 bake-in したが、
バトル側は Enemy master data 24 行の migration が必要で当時見送られ、code 内乗算
定数 `BATTLE_EXP_MULTIPLIER = 0.3` として実装された。

2026-07-25、ギルド画面で「表示 EXP > 実獲得 EXP」の bug が発覚:
- list.py が raw `enemy.reward_exp` を返却 → 表示 = 50 EXP
- finish.py が `int(reward_exp * 0.3)` → 実獲得 = 15 EXP
- ユーザー「損した感覚」

hotfix ce8c867 で list.py にも同じ乗算を適用して同期させたが、**乗算構造を code に
残すこと自体が将来の表示 bug 温床** と PM 判断 (2026-07-25 PM 実装セッション)。

## 本 migration の対応

Enemy 全 24 体の `reward_exp` を `int(raw * 0.3)` の実効値に UPDATE。以降、code は
`BATTLE_EXP_MULTIPLIER` を参照せず、`enemy.reward_exp` を直接使う (別 commit で
constants.py / battle/list.py / battle/finish.py を修正)。

**ユーザー影響ゼロ**: 現行 dev の表示値と bit-perfect に一致する値を bake する
(int(raw * 0.3) の Python 挙動で計算)。「今 dev で見えている数値がそのまま DB 値
になる」だけ、ゲームバランスは FEAT-406 の設計 (バトル EXP 控えめ、習慣 EXP 主
収入) を維持。

## 単調増加性 (BUG-81 参考)

BUG-81 で raw 値の単調増加性は保証されているが、× 0.3 の int 切り捨てで一部逆転
が発生する (現行 dev で既発生、bake-in で悪化するわけではない):
  - Lv 15 shadow_mage 36 → Lv 17 lizard_warrior 25 (-11)
  - Lv 20 dragon 45 → Lv 22 dark_knight 30 (-15)
  - Lv 7 skeleton 10 → Lv 8 giant_slime 9 (-1)

本 migration では対応せず、独立した game balance 判断として別 BUG で扱う (FEAT-495
指示書 §4 S1 で明記済)。

## CLAUDE.md master/seed data 例外条項適用

3 条件を全て満たす:
  1. **対象が master/seed data のみ**: Enemy master の reward_exp 更新のみ、
     user-generated content (Battle / BattleLog / PlayerProfile) は無傷。
  2. **FK 網羅**: Enemy への FK は Battle.enemy (PROTECT) / BattleLog.enemy (PROTECT)
     の 2 経路。本 migration は UPDATE のみで DELETE なし → CASCADE / PROTECT 無影響。
  3. **冪等性**: `filter(key=...).update(reward_exp=...)` は再 apply 安全。

## 検証

- BattleLog は完了時 snapshot 保存 (finish.py で計算済 `exp_gained` を保存) のため
  過去履歴は影響なし。今後のバトルからのみ新値が適用される。
- XP ブースト × 1.5 は bake 後の reward_exp に適用、乗算対象が同値なので結果同値。
- 冒険モード bonus +20% も同様。
"""
from django.db import migrations


# (key, new_reward_exp = int(old * 0.3))
# 現行値の source: seed migrations 0082 (goblin) / 0083 (giant_slime, goblin_king,
# dragon, shadow_mage) / 0088 (armored_knight, ice_witch, void_dragon) / 0092
# (slime, weak_goblin, young_orc) / 0109 (griffin) / 0118 (bat, rat, skeleton,
# wolf, ogre, lizard_warrior, dark_knight, fire_demon, vampire_lord, chimera,
# lich_king, leviathan) + 0122 balance update (armored_knight, ice_witch, chimera,
# lich_king, leviathan)
_ENEMY_REWARD_EXP_BAKED = [
    # (key,              new_exp = int(old_exp * 0.3))
    ('slime',              3),   # 10 -> 3
    ('goblin',             6),   # 20 -> 6
    ('bat',                5),   # 18 -> 5
    ('rat',                6),   # 22 -> 6 (int(6.6)=6)
    ('weak_goblin',        7),   # 25 -> 7 (int(7.5)=7 in Python fp)
    ('giant_slime',        9),   # 30 -> 9
    ('skeleton',          10),   # 35 -> 10 (int(10.5)=10)
    ('young_orc',         15),   # 50 -> 15
    ('wolf',              18),   # 60 -> 18
    ('goblin_king',       18),   # 60 -> 18
    ('ogre',              21),   # 70 -> 21
    ('lizard_warrior',    25),   # 85 -> 25 (int(25.5)=25)
    ('armored_knight',    28),   # 95 -> 28 (int(28.5)=28)
    ('shadow_mage',       36),   # 120 -> 36
    ('ice_witch',         37),   # 125 -> 37 (int(37.5)=37)
    ('dark_knight',       30),   # 100 -> 30
    ('fire_demon',        39),   # 130 -> 39
    ('vampire_lord',      43),   # 145 -> 43 (int(43.5)=43)
    ('dragon',            45),   # 150 -> 45
    ('griffin',           45),   # 150 -> 45
    ('chimera',           64),   # 215 -> 64 (int(64.5)=64)
    ('lich_king',         73),   # 245 -> 73 (int(73.5)=73)
    ('leviathan',         84),   # 280 -> 84
    ('void_dragon',       90),   # 300 -> 90
]

# rollback 用旧値 (× 10/3 は不可逆なため明示的にハードコード)。
_ENEMY_REWARD_EXP_PREVIOUS = [
    ('slime',             10),
    ('goblin',            20),
    ('bat',               18),
    ('rat',               22),
    ('weak_goblin',       25),
    ('giant_slime',       30),
    ('skeleton',          35),
    ('young_orc',         50),
    ('wolf',              60),
    ('goblin_king',       60),
    ('ogre',              70),
    ('lizard_warrior',    85),
    ('armored_knight',    95),
    ('shadow_mage',      120),
    ('ice_witch',        125),
    ('dark_knight',      100),
    ('fire_demon',       130),
    ('vampire_lord',     145),
    ('dragon',           150),
    ('griffin',          150),
    ('chimera',          215),
    ('lich_king',        245),
    ('leviathan',        280),
    ('void_dragon',      300),
]


def _bake_reward_exp(apps, schema_editor):
    """Enemy 全 24 体を bake 済 reward_exp に UPDATE。"""
    Enemy = apps.get_model('api', 'Enemy')

    # 把握外の Enemy が prod DB に存在した場合の警告 (silent 失敗防止)
    known_keys = {key for key, _ in _ENEMY_REWARD_EXP_BAKED}
    unknown = Enemy.objects.exclude(key__in=known_keys).values_list('key', flat=True)
    if unknown:
        print(f'[migration 0187] WARNING: unknown Enemy keys not touched by bake: {list(unknown)}')

    for key, new_exp in _ENEMY_REWARD_EXP_BAKED:
        updated = Enemy.objects.filter(key=key).update(reward_exp=new_exp)
        if updated == 0:
            print(f'[migration 0187] WARNING: Enemy key={key!r} not found, skipped')


def _revert_reward_exp(apps, schema_editor):
    """rollback: Enemy 全 24 体を旧 raw 値に UPDATE。"""
    Enemy = apps.get_model('api', 'Enemy')
    for key, old_exp in _ENEMY_REWARD_EXP_PREVIOUS:
        Enemy.objects.filter(key=key).update(reward_exp=old_exp)


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0186_free_memo_enabled_default_true'),
    ]

    operations = [
        migrations.RunPython(_bake_reward_exp, _revert_reward_exp),
    ]
