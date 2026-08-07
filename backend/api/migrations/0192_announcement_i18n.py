# 【FEAT-489 Phase 4】Announcement.title_en / body_en 追加

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0191_sabi_message_content_en'),
    ]

    operations = [
        migrations.AddField(
            model_name='announcement',
            name='title_en',
            field=models.CharField(
                blank=True,
                default='',
                max_length=100,
                verbose_name='タイトル(英語版)',
            ),
        ),
        migrations.AddField(
            model_name='announcement',
            name='body_en',
            field=models.TextField(
                blank=True,
                default='',
                verbose_name='本文(英語版)',
            ),
        ),
    ]
