"""【BUG-146 Phase 0 (2026-08-19)】`noon_castle_town.tagline` を仕様値に揃える。

指示書: `doc/instructions/BUG-146_master_data_en_not_read_by_gacha_shop_weapon.md` §3.4 / §5

## 何が食い違っていたか

同じ 1 行に 3 つの値が存在していた。

| 場所 | 値 |
|---|---|
| FEAT-479 指示書:363 (仕様) | 賑わい**がそっと**目を覚ましてゆく街ですね 🪶 |
| migration 0175:44 (seed)   | 賑わいが目を覚ましてゆく街ですね 🪶 |
| prod DB (2026-08-19 実測)  | 賑わい**がそっと**目を覚ましてゆく街ですね 🪶 |
| dev DB / doc/i18n/*.json   | 賑わいが目を覚ましてゆく街ですね 🪶 |

**仕様が正で、`0175` の seed が指示書から 3 文字落としている。** prod は誰かが
admin で仕様どおりに直した状態、dev と seed は落ちたまま。

2026-08-19 のマスターデータ英訳 prod 投入で、この 1 行だけ `WHERE` の原文照合が
外れて 0 行更新になった (安全装置が正しく機能した = 誤った行には書いていない)。

## なぜ `0175` を書き換えないのか

適用済み migration の改変は CLAUDE.md「マイグレーション規則」違反であり、
**既に `0175` を通過した DB には何も起きない** (= dev が直らない)。
新しい migration で「現在の値を仕様値へ更新する」のが正しい直し方。

## なぜ JSON だけを直す案を採らなかったのか

`doc/i18n/*.json` の `tagline` は**原文照合用**なので、テスト DB (`0175` から
作られる) と prod のどちらか一方にしか合わせられない。2026-08-19 に JSON だけを
prod に合わせたところ **58 tests OK → FAILED (failures=1, errors=4)** になった。
**DB 側を仕様値に揃えてから JSON を直す**のが順序。

## CLAUDE.md master/seed data 例外条項 (FEAT-391) の 3 条件

1. **master data のみ**: `PuzzleWorldScene` 1 行の `CharField` 1 個。user data 無影響
2. **FK 網羅**: 対象は非 FK。`key` は変更しないので `active_scene` /
   `displayed_scene` / `PlayerPuzzleSceneProgress.scene` /
   `PlayerPuzzleWorldHistory.scene` の FK 4 本に影響なし
3. **冪等性**: `key` 一致の行に値を代入するだけ。再 run しても結果は同じ

prod は既にこの値なので **prod では実質 no-op** (同値の代入)。
`reverse` は `0175` の値へ戻す (可逆)。
"""
from django.db import migrations

SCENE_KEY = 'noon_castle_town'

# FEAT-479 指示書 §3.5 の値 (「がそっと」が入る)
SPEC_TAGLINE = '賑わいがそっと目を覚ましてゆく街ですね 🪶'

# migration 0175 が seed した値 (指示書から 3 文字落ちている)
SEED_TAGLINE = '賑わいが目を覚ましてゆく街ですね 🪶'


def _set_tagline(apps, value):
    Scene = apps.get_model('api', 'PuzzleWorldScene')
    Scene.objects.filter(key=SCENE_KEY).update(tagline=value)


def apply_spec_tagline(apps, schema_editor):
    _set_tagline(apps, SPEC_TAGLINE)


def revert_to_seed_tagline(apps, schema_editor):
    _set_tagline(apps, SEED_TAGLINE)


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0201_feat522_enemy_atk_flat_damage'),
    ]

    operations = [
        migrations.RunPython(apply_spec_tagline, revert_to_seed_tagline),
    ]
