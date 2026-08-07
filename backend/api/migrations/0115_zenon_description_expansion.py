"""【2026-05-30】ゼノン (zenon) の description 拡張: 他キャラと同等の本格ストーリー化。

【背景】
migration 0062 で zenon を新規追加した際、description が
'疾風のごとく駆け抜け、目標を打ち砕く' (18 文字) の短文で seed されていた。
一方、他 7 キャラ (sol/aria/rune/lucia/beatrix/faye/noir) は migration 0023
で 87-100 文字の 2-3 文構造の本格ストーリーに更新済 = ゼノンのみ取り残し。

ユーザー要望「他キャラと同じ文章量で考えて追記してください」を踏まえ、
migration 0023 と同じ「過去の出来事 + 哲学 + 流儀 (3 文構造)」で拡張する。

【master/seed data 例外条項適用 (codebase_review 20260530 P1-3)】
対象: Character master data の description TextField 更新 (user-generated 非対象)
条件 1: master/seed data のみ ✅
条件 2: description は FK なし、CASCADE/PROTECT 影響なし ✅
条件 3: filter().update() で冪等性確保 ✅

【サビ哲学整合】
- 「山籠もりの十年」「一拳ごとに呼吸を整える」= 積み重ね哲学
- 「動と静の間に答えがある」= 静かな修練 + 内省 (サビミッション「静かな聖域」と整合)
- 「——それがモンクの流儀だ」= sol (剣士) と統一構文
"""
from django.db import migrations


_ZENON_NEW_DESCRIPTION = (
    '山籠もりの十年で見えたのは、強さは爆発ではなく息遣いだということ。'
    '一撃で天を割ることを夢見た少年は、今では一拳ごとに呼吸を整える求道者になった。'
    '動と静の間に答えがある——それがモンクの流儀だ。'
)


def _expand_zenon_description(apps, schema_editor):
    Character = apps.get_model('api', 'Character')
    updated = Character.objects.filter(key='zenon').update(
        description=_ZENON_NEW_DESCRIPTION,
    )
    if updated:
        print(f'[migration 0115] Expanded zenon description ({len(_ZENON_NEW_DESCRIPTION)} chars)')
    else:
        print('[migration 0115] zenon character not found, skipping (test DB?)')


def _revert_zenon_description(apps, schema_editor):
    """ロールバック: migration 0062 の短文に戻す。"""
    Character = apps.get_model('api', 'Character')
    Character.objects.filter(key='zenon').update(
        description='疾風のごとく駆け抜け、目標を打ち砕く',
    )


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0114_character_role_update'),
    ]

    operations = [
        migrations.RunPython(
            _expand_zenon_description,
            reverse_code=_revert_zenon_description,
        ),
    ]
