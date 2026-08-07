# 【FEAT-489 Phase 4】PlayerSettings.preferred_language 追加 (ja/en 優先言語設定)

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0195_character_i18n'),
    ]

    operations = [
        migrations.AddField(
            model_name='playersettings',
            name='preferred_language',
            field=models.CharField(
                choices=[('ja', '日本語'), ('en', 'English')],
                default='ja',
                max_length=8,
                verbose_name='優先言語',
                help_text='FEAT-489 Phase 4 (v1.1)。null 相当時は Accept-Language header → ja default の順で解決。',
            ),
        ),
    ]
