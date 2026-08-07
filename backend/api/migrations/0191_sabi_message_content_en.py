# 【FEAT-489 Phase 4】SabiMessage.content_en 追加 (英語版セリフ)

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0190_add_player_job_mastery'),
    ]

    operations = [
        migrations.AddField(
            model_name='sabimessage',
            name='content_en',
            field=models.TextField(
                blank=True,
                default='',
                verbose_name='セリフ(英語版)',
                help_text='English version. Leave blank to fall back to Japanese content.',
            ),
        ),
    ]
