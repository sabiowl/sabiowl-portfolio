from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0013_rename_api_pending_key_idx_api_pending_key_dd2386_idx_and_more'),
    ]

    operations = [
        migrations.AddField(
            model_name='habit',
            name='difficulty',
            field=models.CharField(
                choices=[
                    ('easy',      'Easy'),
                    ('normal',    'Normal'),
                    ('hard',      'Hard'),
                    ('legendary', 'Legendary'),
                ],
                default='normal',
                max_length=10,
                verbose_name='難易度',
            ),
        ),
    ]
