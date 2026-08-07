from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0005_diamonds'),
    ]

    operations = [
        # PlayerProfile に bonus_coins を追加
        migrations.AddField(
            model_name='playerprofile',
            name='bonus_coins',
            field=models.IntegerField(default=0, verbose_name='クエスト報酬コイン'),
        ),

        # QuestCompletion モデルを追加
        migrations.CreateModel(
            name='QuestCompletion',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('quest_id',   models.CharField(max_length=50, verbose_name='クエストID')),
                ('period_key', models.CharField(max_length=20, verbose_name='期間キー')),
                ('claimed_at', models.DateTimeField(auto_now_add=True, verbose_name='受け取り日時')),
                ('player', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='quest_completions',
                    to='api.playerprofile',
                    verbose_name='プレイヤー',
                )),
            ],
            options={
                'verbose_name':        'クエスト受け取り履歴',
                'verbose_name_plural': 'クエスト受け取り履歴',
                'unique_together': {('player', 'quest_id', 'period_key')},
            },
        ),
    ]
