# 【FEAT-489 Phase 4】Character.name_en / role_en / tagline_en / description_en 追加

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0194_enemy_name_en'),
    ]

    operations = [
        migrations.AddField(
            model_name='character',
            name='name_en',
            field=models.CharField(
                blank=True,
                default='',
                max_length=50,
                verbose_name='名前(英語版)',
            ),
        ),
        migrations.AddField(
            model_name='character',
            name='role_en',
            field=models.CharField(
                blank=True,
                default='',
                max_length=50,
                verbose_name='役職(英語版)',
            ),
        ),
        migrations.AddField(
            model_name='character',
            name='tagline_en',
            field=models.CharField(
                blank=True,
                default='',
                max_length=80,
                verbose_name='キャッチコピー(英語版)',
            ),
        ),
        migrations.AddField(
            model_name='character',
            name='description_en',
            field=models.TextField(
                blank=True,
                default='',
                verbose_name='説明文(英語版)',
            ),
        ),
    ]
