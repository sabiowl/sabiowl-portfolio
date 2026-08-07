import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0032_habit_type_todo'),
    ]

    operations = [
        migrations.CreateModel(
            name='RestDay',
            fields=[
                ('id',         models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('date',       models.DateField()),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('player',     models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='rest_days',
                    to='api.playerprofile',
                )),
            ],
            options={
                'ordering': ['-date'],
                'unique_together': {('player', 'date')},
            },
        ),
    ]
