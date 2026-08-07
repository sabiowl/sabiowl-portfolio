"""Habit.category を 4 値に正規化する data migration（FEAT-201）。

CLAUDE.md 真実値の 4 カテゴリ（運動 / 学習 / 健康 / メンタル）に統一する。
既存の 11 カテゴリは下記マッピングで自動変換し、その後に AlterField で choices を縮約する。

経緯:
- `Habit.CATEGORY_CHOICES` は 11 個、`constants.CATEGORY_STAT_MAP` は 9 個と不整合だった
- ユーザーが「仕事」「体力」等を選んで習慣を完了しても、CATEGORY_STAT_MAP に
  ヒットせず `_auto_allocate_by_ratio()` でステータス EXP が按分されないバグ
- 結果として「努力 → 成長」のコアプロミスがサイレントに半分破られていた
- ユーザーは「なんか伸びが遅い」と感じてサイレント・チャーンする経路

CLAUDE.md 真実値（4 カテゴリ）への統一でコードレベルで履行を保証する。

未公開段階のため、可視的なカテゴリ表示変更（「仕事」→「学習」等）の告知は不要。
本番運用後に同様変更を行う場合は別 FEAT で告知が必要になる。
"""

from django.db import migrations, models


# 旧カテゴリ → 新カテゴリのマッピング（FEAT-201 指示書の確定版）
_CATEGORY_REMAP = {
    '運動':   '運動',         # そのまま
    '体力':   '運動',         # 身体活動として最も近い
    '美容':   '運動',         # 身体ケアとして「運動」に集約
    '学習':   '学習',         # そのまま
    '仕事':   '学習',         # 知識習得・スキル向上として
    '創造':   '学習',         # 知的生産活動として
    '健康':   '健康',         # そのまま
    '休息':   '健康',         # 身体メンテナンスとして
    '精神':   'メンタル',     # 精神性として
    '社交':   'メンタル',     # 心理的繋がりとして
    'その他': 'メンタル',     # 残余を心の領域へ
}


def forwards(apps, schema_editor):
    """既存 Habit の category を 4 値に正規化する。

    同名キー（運動/学習/健康）はスキップして UPDATE 回数を削減。
    """
    Habit = apps.get_model('api', 'Habit')
    for old_cat, new_cat in _CATEGORY_REMAP.items():
        if old_cat == new_cat:
            continue  # 同名はスキップ
        Habit.objects.filter(category=old_cat).update(category=new_cat)


def backwards(apps, schema_editor):
    """ロールバック用（情報損失のため厳密復元は不可）。

    本マイグレーション後の DB は 4 値しか持たないため、元の 11 カテゴリへの
    逆引きはできない。backwards は no-op（巻き戻し時は手動でデータ整理が必要）。
    """
    pass


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0063_guestsession_guestpromotepending_and_more'),
    ]

    operations = [
        # ① 既存データをバックフィル
        migrations.RunPython(forwards, backwards),

        # ② CharField.choices を 4 値に縮約
        migrations.AlterField(
            model_name='habit',
            name='category',
            field=models.CharField(
                max_length=20,
                default='運動',
                choices=[
                    ('運動',     '運動'),
                    ('学習',     '学習'),
                    ('健康',     '健康'),
                    ('メンタル', 'メンタル'),
                ],
                verbose_name='カテゴリ',
            ),
        ),
    ]
