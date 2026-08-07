# 【FEAT-489 Phase 4】TaskSuggestion.title_en / hint_en 追加

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0192_announcement_i18n'),
    ]

    operations = [
        migrations.AddField(
            model_name='tasksuggestion',
            name='title_en',
            field=models.CharField(
                blank=True,
                default='',
                max_length=100,
                verbose_name='タイトル(英語版)',
            ),
        ),
        migrations.AddField(
            model_name='tasksuggestion',
            name='hint_en',
            field=models.CharField(
                blank=True,
                default='',
                max_length=100,
                verbose_name='補足テキスト(英語版)',
            ),
        ),
    ]
