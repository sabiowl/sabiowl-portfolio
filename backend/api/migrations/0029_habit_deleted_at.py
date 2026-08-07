from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0028_achievement'),
    ]

    operations = [
        migrations.AddField(
            model_name='habit',
            name='deleted_at',
            field=models.DateTimeField(blank=True, null=True, verbose_name='削除日時'),
        ),
    ]
