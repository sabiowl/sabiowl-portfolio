"""
Migration 0021 — 習慣リセットサイクル追加

変更内容:
  Habit: reset_cycle フィールドを追加（daily/weekly/monthly/yearly）
         既存レコードは frequency と同じ値に初期化（RunPython）
"""
from django.db import migrations, models


def set_default_reset_cycle(apps, schema_editor):
    """既存習慣の reset_cycle を frequency と同じ値に設定する"""
    Habit = apps.get_model('api', 'Habit')
    Habit.objects.filter(frequency='weekly').update(reset_cycle='weekly')
    Habit.objects.filter(frequency='monthly').update(reset_cycle='monthly')
    # daily は既にデフォルト値 'daily' なので不要


def revert_reset_cycle(apps, schema_editor):
    pass  # ロールバック時は何もしない（フィールド削除で対応）


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0020_gacha_weekly_monthly'),
    ]

    operations = [
        migrations.AddField(
            model_name='habit',
            name='reset_cycle',
            field=models.CharField(
                max_length=10,
                choices=[
                    ('daily',   '毎日'),
                    ('weekly',  '毎週'),
                    ('monthly', '毎月'),
                    ('yearly',  '毎年'),
                ],
                default='daily',
                verbose_name='リセットサイクル',
            ),
        ),
        migrations.RunPython(set_default_reset_cycle, revert_reset_cycle),
    ]
