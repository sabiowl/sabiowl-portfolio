from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0025_gift'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='mode',
            field=models.CharField(
                default='training',
                help_text='training=鍛錬, adventure=冒険',
                max_length=10,
                verbose_name='プレイモード',
            ),
        ),
    ]
