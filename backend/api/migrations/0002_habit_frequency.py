from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0001_initial'),
    ]

    operations = [
        migrations.AddField(
            model_name='habit',
            name='frequency',
            field=models.CharField(
                choices=[('daily', '毎日'), ('weekly', '毎週'), ('monthly', '毎月')],
                default='daily',
                max_length=10,
                verbose_name='頻度',
            ),
        ),
    ]
