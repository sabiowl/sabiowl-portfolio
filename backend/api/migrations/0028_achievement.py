from django.db import migrations, models
import django.db.models.deletion


def seed_achievements(apps, schema_editor):
    Achievement = apps.get_model('api', 'Achievement')
    seeds = [
        dict(key='first_log',  name='はじめの一歩',    description='初めて習慣を記録する',       icon='👣', condition_type='total_logs',    condition_value=1,   reward_diamonds=10,  order=10),
        dict(key='log_10',     name='継続の芽',         description='習慣を10回記録する',           icon='🌱', condition_type='total_logs',    condition_value=10,  reward_diamonds=20,  order=11),
        dict(key='log_50',     name='習慣の木',         description='習慣を50回記録する',           icon='🌳', condition_type='total_logs',    condition_value=50,  reward_diamonds=50,  order=12),
        dict(key='log_100',    name='百回の証',         description='習慣を100回記録する',          icon='💯', condition_type='total_logs',    condition_value=100, reward_diamonds=100, order=13),
        dict(key='streak_3',   name='3日坊主を超えた', description='3日連続で習慣を記録する',      icon='🔥', condition_type='best_streak',   condition_value=3,   reward_diamonds=20,  order=20),
        dict(key='streak_7',   name='一週間の戦士',    description='7日連続で習慣を記録する',      icon='⚡', condition_type='best_streak',   condition_value=7,   reward_diamonds=50,  order=21),
        dict(key='streak_30',  name='鉄の意志',        description='30日連続で習慣を記録する',     icon='🏆', condition_type='best_streak',   condition_value=30,  reward_diamonds=200, order=22),
        dict(key='level_5',    name='新米冒険者',      description='レベル5に到達する',             icon='⭐', condition_type='level_reached', condition_value=5,   reward_diamonds=30,  order=30),
        dict(key='level_10',   name='熟練者',          description='レベル10に到達する',            icon='🌟', condition_type='level_reached', condition_value=10,  reward_diamonds=80,  order=31),
        dict(key='level_20',   name='達人',            description='レベル20に到達する',            icon='💫', condition_type='level_reached', condition_value=20,  reward_diamonds=200, order=32),
        dict(key='gacha_1',    name='運試し',          description='初めてガチャを引く',            icon='🎰', condition_type='gacha_pulls',   condition_value=1,   reward_diamonds=10,  order=40),
        dict(key='gacha_10',   name='ガチャ中毒',      description='ガチャを10回引く',              icon='🎲', condition_type='gacha_pulls',   condition_value=10,  reward_diamonds=30,  order=41),
        dict(key='friends_1',  name='友達できたよ',    description='フレンドを1人作る',             icon='🤝', condition_type='friends_count', condition_value=1,   reward_diamonds=20,  order=50),
    ]
    for data in seeds:
        Achievement.objects.get_or_create(key=data['key'], defaults=data)


class Migration(migrations.Migration):
    dependencies = [
        ('api', '0027_quest'),
    ]
    operations = [
        migrations.CreateModel(
            name='Achievement',
            fields=[
                ('id', models.AutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('key', models.CharField(max_length=64, unique=True)),
                ('name', models.CharField(max_length=64)),
                ('description', models.CharField(max_length=256)),
                ('icon', models.CharField(max_length=8)),
                ('condition_type', models.CharField(choices=[('total_logs', '累計ログ回数'), ('best_streak', '最長ストリーク'), ('level_reached', '到達レベル'), ('gacha_pulls', 'ガチャ回数'), ('friends_count', 'フレンド数')], max_length=32)),
                ('condition_value', models.IntegerField()),
                ('reward_diamonds', models.IntegerField(default=0)),
                ('order', models.IntegerField(default=0)),
            ],
            options={'ordering': ['order', 'id']},
        ),
        migrations.CreateModel(
            name='PlayerAchievement',
            fields=[
                ('id', models.AutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('unlocked_at', models.DateTimeField(auto_now_add=True)),
                ('is_claimed', models.BooleanField(default=False)),
                ('achievement', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='player_achievements', to='api.achievement')),
                ('player', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='achievements', to='api.playerprofile')),
            ],
            options={'unique_together': {('player', 'achievement')}},
        ),
        migrations.RunPython(seed_achievements, migrations.RunPython.noop),
    ]
