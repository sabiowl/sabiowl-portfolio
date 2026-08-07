from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0016_character_starter_update'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='week_start_day',
            field=models.IntegerField(
                default=0,
                verbose_name='週起点曜日',
                help_text='0=月, 1=火, 2=水, 3=木, 4=金, 5=土, 6=日',
            ),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='month_reset_day',
            field=models.IntegerField(
                default=1,
                verbose_name='月次リセット日',
                help_text='1〜28',
            ),
        ),
    ]
