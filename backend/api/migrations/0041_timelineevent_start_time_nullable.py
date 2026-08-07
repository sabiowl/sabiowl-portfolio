from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0040_timelineevent'),
    ]

    operations = [
        migrations.AlterField(
            model_name='timelineevent',
            name='start_time',
            field=models.TimeField(blank=True, null=True, verbose_name='開始時刻'),
        ),
    ]
