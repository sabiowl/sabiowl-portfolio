# 【FEAT-489 Phase 4】Enemy.name_en 追加

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0193_task_suggestion_i18n'),
    ]

    operations = [
        migrations.AddField(
            model_name='enemy',
            name='name_en',
            field=models.CharField(
                blank=True,
                default='',
                max_length=64,
                verbose_name='表示名(英語版)',
            ),
        ),
    ]
