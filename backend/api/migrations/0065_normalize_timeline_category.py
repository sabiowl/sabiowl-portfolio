"""TimelineEvent.category を 4 値に正規化する data migration（FEAT-208）。

タイムラインカテゴリも習慣カテゴリ（FEAT-201, マイグレーション 0064）と同じ
4 値（運動 / 学習 / 健康 / メンタル）に統一する。
旧 13 コード値（study/business/exercise/fitness/beauty/health/mental/creative/
social/rest/other/habit/work）はマッピングで一括バックフィル。

経緯:
- FEAT-147 で導入された TIMELINE_CATEGORY_CHOICES は英語コード + 日本語ラベルの
  11 値 + 後方互換 2 値（habit / work）の計 13 値で、習慣カテゴリ（FEAT-201 で
  4 値統一）と整合していなかった
- 「習慣 / ToDo / タイムライン」で同じ「運動」「学習」等のラベルなのに、
  保存値が日本語 (Habit) と英語 (TimelineEvent) で混在していた
- FEAT-201 と整合させ、タイムラインも `'運動' / '学習' / '健康' / 'メンタル'`
  の日本語キー 4 値に統一する

未公開段階のため、可視的カテゴリ表示変更の告知は不要。Flutter ローカル
SharedPreferences の旧カテゴリは TimelineTemplatesNotifier._load() 内の
バックフィル処理で自動変換される。
"""

from django.db import migrations, models


# 旧カテゴリコード → 新カテゴリ（CLAUDE.md 4 値）のマッピング
# FEAT-201 の Habit カテゴリマッピングと完全整合させる方針:
#   - study / creative / business / work → 学習
#   - exercise / fitness / beauty        → 運動
#   - health / rest / habit               → 健康
#   - mental / social / other             → メンタル
_CATEGORY_REMAP = {
    'study':    '学習',
    'business': '学習',
    'creative': '学習',
    'work':     '学習',
    'exercise': '運動',
    'fitness':  '運動',
    'beauty':   '運動',
    'health':   '健康',
    'rest':     '健康',
    'habit':    '健康',
    'mental':   'メンタル',
    'social':   'メンタル',
    'other':    'メンタル',
}


def forwards(apps, schema_editor):
    """既存 TimelineEvent の category を 4 値に正規化する。"""
    TimelineEvent = apps.get_model('api', 'TimelineEvent')
    for old_cat, new_cat in _CATEGORY_REMAP.items():
        TimelineEvent.objects.filter(category=old_cat).update(category=new_cat)


def backwards(apps, schema_editor):
    """ロールバック用（情報損失のため厳密復元は不可）。

    本マイグレーション後の DB は 4 値しか持たないため、元の 13 コード値への
    逆引きはできない。backwards は no-op。
    """
    pass


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0064_normalize_habit_category'),
    ]

    operations = [
        # ① 既存データをバックフィル
        migrations.RunPython(forwards, backwards),

        # ② CharField.choices を 4 値に縮約 + default を「健康」に変更
        migrations.AlterField(
            model_name='timelineevent',
            name='category',
            field=models.CharField(
                max_length=20,
                default='健康',
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
