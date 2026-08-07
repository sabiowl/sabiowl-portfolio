from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0006_quests'),
    ]

    operations = [
        migrations.AddField(
            model_name='habit',
            name='memo',
            field=models.TextField(blank=True, default='', verbose_name='メモ'),
        ),
    ]
