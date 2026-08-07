from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0052_magiclinktoken_otp_code'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='rest_fruits',
            field=models.IntegerField(
                default=0,
                help_text='ショップで購入した休息の果実の在庫数',
                verbose_name='休息の果実ストック数',
            ),
        ),
    ]
