from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0023_character_description_update'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='fcm_token',
            field=models.TextField(blank=True, default='', verbose_name='FCMトークン'),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='reminder_enabled',
            field=models.BooleanField(default=False, verbose_name='リマインダー有効'),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='reminder_time',
            field=models.TimeField(blank=True, null=True, verbose_name='通知時刻'),
        ),
    ]
