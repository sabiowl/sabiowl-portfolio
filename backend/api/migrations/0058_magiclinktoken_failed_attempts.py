from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0057_playerprofile_last_achievement_check_at'),
    ]

    operations = [
        migrations.AddField(
            model_name='magiclinktoken',
            name='failed_attempts',
            field=models.IntegerField(default=0, verbose_name='OTP試行失敗回数'),
        ),
    ]
