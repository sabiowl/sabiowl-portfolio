from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0053_playerprofile_rest_fruits'),
    ]

    operations = [
        migrations.AddField(
            model_name='restday',
            name='used_fruit',
            field=models.BooleanField(default=False, verbose_name='果実を使用して作成'),
        ),
    ]
