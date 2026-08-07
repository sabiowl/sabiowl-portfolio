"""Habit.category と TimelineEvent.category の choices を 4 → 11 値に拡張（FEAT-213）。

FEAT-201（Habit）と FEAT-208（Timeline）で 11 → 4 に縮約した方針を両方とも再転換。
ただし `CATEGORY_STAT_MAP`（`constants.py`）は全 11 カテゴリが 6 ステータスに分散
マッピングされるため、サイレント喪失バグ（FEAT-201 の主因）は再発しない。

Habit / Timeline 両方とも同じ 11 値カテゴリで統一（Flutter 側の共通コンポーネント
`SabiCategoryChips` が完全に一本化される）。

データバックフィル:
- 旧 `'メンタル'` 値は新 `CATEGORY_CHOICES` に存在しないため `'精神'` に変換する。
  Phase 0 の実データ調査で Habit に 1 件、TimelineEvent に 0 件確認済み。
  本マイグレーションでは Django ORM 経由で `Habit` / `TimelineEvent` 両方を更新する
  （TimelineEvent が空でも no-op で安全）。
- それ以外の旧値（運動 / 学習 / 健康）は新 11 値に含まれるため変換不要。
- 新規カテゴリ（仕事 / 体力 / 美容 / 創造 / 社交 / 休息 / その他）は復元不可、
  ユーザー再入力で対応（未公開段階のため告知不要）。
"""

from django.db import migrations, models


_CATEGORY_CHOICES_11 = [
    ('運動',   '運動'),
    ('学習',   '学習'),
    ('仕事',   '仕事'),
    ('体力',   '体力'),
    ('美容',   '美容'),
    ('健康',   '健康'),
    ('精神',   '精神'),
    ('創造',   '創造'),
    ('社交',   '社交'),
    ('休息',   '休息'),
    ('その他', 'その他'),
]


def _backfill_mental_to_seishin(apps, schema_editor):
    """旧 'メンタル' 値（FEAT-201 マイグレーション 0064 の遺産）を新 '精神' に変換。

    Phase 0 で Habit に 1 件、TimelineEvent に 0 件確認済み。本処理は冪等。
    """
    Habit         = apps.get_model('api', 'Habit')
    TimelineEvent = apps.get_model('api', 'TimelineEvent')
    Habit.objects.filter(category='メンタル').update(category='精神')
    TimelineEvent.objects.filter(category='メンタル').update(category='精神')


def _backfill_seishin_to_mental(apps, schema_editor):
    """ロールバック用（情報損失を避けるための逆変換）。

    旧 '精神' のうち 0066 で変換されたものと、ユーザーが新規に '精神' を選んだものを
    区別できないため、厳密復元はできない（noop に近い扱いで OK）。
    """
    # 厳密ロールバックは情報損失を起こすため no-op
    pass


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0065_normalize_timeline_category'),
    ]

    operations = [
        # ① 既存データのバックフィル（'メンタル' → '精神'）
        migrations.RunPython(
            _backfill_mental_to_seishin,
            _backfill_seishin_to_mental,
        ),

        # ② Habit.category の choices を 11 値へ
        migrations.AlterField(
            model_name='habit',
            name='category',
            field=models.CharField(
                max_length=20,
                choices=_CATEGORY_CHOICES_11,
                default='運動',
                verbose_name='カテゴリ',
            ),
        ),

        # ③ TimelineEvent.category の choices も 11 値へ（FEAT-208 の 4 値統一を覆す）
        migrations.AlterField(
            model_name='timelineevent',
            name='category',
            field=models.CharField(
                max_length=20,
                default='その他',
                choices=_CATEGORY_CHOICES_11,
                verbose_name='カテゴリ',
            ),
        ),
    ]
