"""【BUG-140 (2026-07-25)】boss + griffin 報酬 EXP の同 tier monotonic 増加回復。

## 背景

FEAT-495 (2026-07-25、migration 0187) で `BATTLE_EXP_MULTIPLIER` を Enemy master
data へ bake-in した結果、以下の逆転がユーザーに可視化された:

  Lv 20 dragon (boss)          45
  Lv 25 ice_witch (boss)       37  ← -8 逆転
  Lv 28 fire_demon (boss)      39
  Lv 32 vampire_lord (boss)    43

「Lv 上げても報酬減る」体験を招くため、boss tier + griffin (hidden_boss 冒頭)
まで cascade で上方修正する。

由来:
- raw 値時代 (FEAT-406 以前) から dragon 150 > ice_witch 125 の逆転が存在
- BUG-81 (2026-06-10) で armored_knight / ice_witch / chimera / lich_king /
  leviathan の逆転を修正済だが、dragon → ice_witch の boss 内逆転は当時 scope 外
- FEAT-495 bake-in で raw 差 -25 が bake 差 -8 に圧縮されつつ表示 = 実獲得で
  ユーザーに直接可視化

## 修正値 (案 Y: 4 敵 cascade)

  Lv 25 ice_witch    37 → 48 (+11)  dragon Lv 20 45 との逆転解消
  Lv 28 fire_demon   39 → 52 (+13)  ice_witch < fire_demon 維持
  Lv 32 vampire_lord 43 → 56 (+13)  fire_demon < vampire_lord 維持
  Lv 35 griffin      45 → 60 (+15)  vampire_lord < griffin 維持 (次 tier 冒頭)

## 据置理由

- dragon (Lv 20 boss) 45: 大人気 boss、報酬減は UX 破壊、据置
- void_dragon (Lv 35 hidden_boss) 90: seed 0088 の「xp 突出設計維持」意図、
  同 Lv 35 で griffin と 2 択の高難易度側特別報酬、据置
- chimera (Lv 38 hidden_boss) 64: griffin 60 < chimera 64 で +4 buffer 確保、据置
- lich_king (Lv 42) 73 / leviathan (Lv 48) 84: chimera 以降 monotonic 維持、据置

## 修正後の progression

  Lv 20 dragon                  45
  Lv 25 ice_witch               48  ← +11
  Lv 28 fire_demon              52  ← +13
  Lv 32 vampire_lord            56  ← +13
  Lv 35 griffin                 60  ← +15
  Lv 35 void_dragon             90     (突出設計、温存)
  Lv 38 chimera                 64
  Lv 42 lich_king               73
  Lv 48 leviathan               84

boss tier 完全 monotonic: 18 → 36 → 45 → 48 → 52 → 56 ✓

## CLAUDE.md master/seed data 例外条項適用

3 条件を全て満たす:
  1. **対象が master/seed data のみ**: Enemy master の reward_exp 更新のみ、
     user-generated content (Battle / BattleLog / PlayerProfile) は無傷。
  2. **FK 網羅**: Enemy への FK は Battle.enemy (PROTECT) / BattleLog.enemy (PROTECT)
     の 2 経路。本 migration は UPDATE のみで DELETE なし → CASCADE / PROTECT 無影響。
  3. **冪等性**: `filter(key=...).update(reward_exp=...)` は再 apply 安全。

## 検証

- BattleLog は完了時 snapshot 保存 (finish.py で計算済 `exp_gained` を保存) のため
  過去履歴は影響なし。今後の勝利からのみ新値が適用される (FEAT-495 と同パターン)。
- 総 EXP 増加 +52 は Sabiowl 主 EXP (習慣、FEAT-406 で ×1.5) 経済への影響ほぼ皆無、
  バトルは補助的報酬設計を維持。
"""
from django.db import migrations


# (key, new_reward_exp)
# 4 敵 cascade 修正 (案 Y、boss + griffin 単調増加回復)
_ENEMY_REWARD_EXP_MONOTONIC = [
    ('ice_witch',    48),   # 37 -> 48 (+11)  dragon Lv 20 45 との逆転解消
    ('fire_demon',   52),   # 39 -> 52 (+13)  ice_witch との monotonic 維持
    ('vampire_lord', 56),   # 43 -> 56 (+13)  fire_demon との monotonic 維持
    ('griffin',      60),   # 45 -> 60 (+15)  vampire_lord < griffin 維持
]

# rollback 用旧値 (FEAT-495 migration 0187 適用直後の値)
_ENEMY_REWARD_EXP_PREVIOUS = [
    ('ice_witch',    37),
    ('fire_demon',   39),
    ('vampire_lord', 43),
    ('griffin',      45),
]


def _apply_monotonic_fix(apps, schema_editor):
    """4 敵の reward_exp を新値に UPDATE (単調増加回復)。"""
    Enemy = apps.get_model('api', 'Enemy')
    for key, new_exp in _ENEMY_REWARD_EXP_MONOTONIC:
        updated = Enemy.objects.filter(key=key).update(reward_exp=new_exp)
        if updated == 0:
            print(f'[migration 0188] WARNING: Enemy key={key!r} not found, skipped')


def _revert_monotonic_fix(apps, schema_editor):
    """rollback: 4 敵を FEAT-495 直後の旧値に戻す。"""
    Enemy = apps.get_model('api', 'Enemy')
    for key, old_exp in _ENEMY_REWARD_EXP_PREVIOUS:
        Enemy.objects.filter(key=key).update(reward_exp=old_exp)


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0187_enemy_reward_exp_bake_multiplier'),
    ]

    operations = [
        migrations.RunPython(_apply_monotonic_fix, _revert_monotonic_fix),
    ]
