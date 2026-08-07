from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0045_habit_due_time'),
    ]

    operations = [
        migrations.CreateModel(
            name='HabitRewardLog',
            fields=[
                ('id', models.BigAutoField(
                    auto_created=True, primary_key=True,
                    serialize=False, verbose_name='ID')),
                ('action', models.CharField(
                    choices=[('plus', '達成'), ('minus', '取り消し')],
                    max_length=8, verbose_name='操作種別')),
                ('exp_delta', models.IntegerField(
                    verbose_name='EXP 変動量',
                    help_text='plus 時は正値、minus 時は負値')),
                ('diamond_delta', models.IntegerField(
                    default=0, verbose_name='ダイヤ変動量')),
                ('created_at', models.DateTimeField(
                    auto_now_add=True, verbose_name='記録日時')),
                ('habit', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='reward_logs',
                    to='api.habit', verbose_name='習慣')),
                ('player', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='reward_logs',
                    to='api.playerprofile', verbose_name='プレイヤー')),
            ],
            options={
                'verbose_name': '報酬変動ログ',
                'verbose_name_plural': '報酬変動ログ',
                'ordering': ['-created_at'],
                'indexes': [
                    models.Index(
                        fields=['player', 'created_at'],
                        name='api_habitrew_player_idx'),
                    models.Index(
                        fields=['habit', 'created_at'],
                        name='api_habitrew_habit_idx'),
                ],
            },
        ),
    ]
