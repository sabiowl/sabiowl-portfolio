from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0026_player_mode'),
    ]

    operations = [
        migrations.CreateModel(
            name='Quest',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('quest_type', models.CharField(
                    choices=[('daily_count','今日N個達成'),('category_count','カテゴリN回達成'),
                             ('exp_gain','EXP獲得'),('weekly_count','今週N回達成'),('weekly_exp','今週EXP獲得')],
                    max_length=20, verbose_name='クエスト種別')),
                ('cycle', models.CharField(
                    choices=[('daily','デイリー'),('weekly','ウィークリー')],
                    max_length=10, verbose_name='サイクル')),
                ('target_value', models.IntegerField(verbose_name='目標値')),
                ('current_value', models.IntegerField(default=0, verbose_name='現在値')),
                ('category', models.CharField(blank=True, max_length=20, verbose_name='カテゴリ')),
                ('reward_diamonds', models.IntegerField(verbose_name='報酬ダイヤ数')),
                ('is_completed', models.BooleanField(default=False, verbose_name='達成済み')),
                ('is_claimed', models.BooleanField(default=False, verbose_name='報酬受取済み')),
                ('date', models.DateField(verbose_name='対象日または週開始日')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('player', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='quests', to='api.playerprofile', verbose_name='プレイヤー')),
            ],
            options={'ordering': ['cycle', 'id'], 'verbose_name': 'クエスト', 'verbose_name_plural': 'クエスト'},
        ),
    ]
