from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0029_habit_deleted_at'),
    ]

    operations = [
        migrations.AlterField(
            model_name='habit',
            name='category',
            field=models.CharField(default='運動', max_length=20, verbose_name='カテゴリ'),
        ),
    ]
