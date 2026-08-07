from django.db import migrations, models


class Migration(migrations.Migration):
    """
    Habit.due_time（タスク通知時刻）を追加する。

    元々 0023_habit_due_time として作成されていたが、同番号の
    0023_character_description_update と prefix が衝突し、
    multiple leaf nodes エラーで migrate が失敗していたため、
    0044_character_image_path_remap の後ろにリネームして合流する。
    """

    dependencies = [
        ('api', '0044_character_image_path_remap'),
    ]

    operations = [
        migrations.AddField(
            model_name='habit',
            name='due_time',
            field=models.TimeField(null=True, blank=True, verbose_name='通知時刻'),
        ),
    ]
