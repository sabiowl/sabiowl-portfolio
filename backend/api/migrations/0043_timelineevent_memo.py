from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0042_character_image_path_sync_to_key'),
    ]

    operations = [
        migrations.AddField(
            model_name='timelineevent',
            name='memo',
            field=models.TextField(blank=True, default='', verbose_name='メモ'),
        ),
    ]
