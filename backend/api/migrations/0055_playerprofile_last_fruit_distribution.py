from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0054_restday_used_fruit'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='last_fruit_distribution',
            field=models.DateField(
                blank=True, null=True, verbose_name='最終果実配布日'
            ),
        ),
    ]
