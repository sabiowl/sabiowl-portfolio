from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0031_alter_achievement_id_alter_notification_notif_type_and_more'),
    ]

    operations = [
        migrations.AlterField(
            model_name='habit',
            name='habit_type',
            field=models.CharField(
                choices=[
                    ('count',     'カウント'),
                    ('checklist', 'チェックリスト'),
                    ('todo',      'ToDo'),
                ],
                default='count',
                max_length=20,
            ),
        ),
    ]
