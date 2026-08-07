from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0036_alter_gachareward_reward_type_alter_habit_habit_type'),
    ]

    operations = [
        migrations.AddField(
            model_name='habit',
            name='priority',
            field=models.CharField(
                choices=[('high', '高'), ('medium', '中'), ('low', '低')],
                default='medium',
                max_length=10,
                verbose_name='優先度',
            ),
        ),
        migrations.AddField(
            model_name='habit',
            name='due_date',
            field=models.DateField(blank=True, null=True, verbose_name='期限日'),
        ),
    ]
