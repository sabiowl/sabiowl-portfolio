"""
ガチャ関連モデルを追加:
  - GachaReward   : 報酬マスターデータ
  - PlayerGachaStatus : チケット・天井カウンター
  - GachaHistory  : 引き履歴
"""
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0018_character_description'),
    ]

    operations = [
        # ── GachaReward ───────────────────────────────────────────────
        migrations.CreateModel(
            name='GachaReward',
            fields=[
                ('id',          models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('rarity',      models.CharField(choices=[('N', 'Normal'), ('R', 'Rare'), ('SR', 'Super Rare'), ('SSR', 'Special Super Rare')], max_length=3, verbose_name='レアリティ')),
                ('reward_type', models.CharField(choices=[('exp', '経験値'), ('diamond', 'ダイヤ'), ('xp_boost', 'XPブースト'), ('title', '称号')], max_length=20, verbose_name='報酬種別')),
                ('container',   models.CharField(choices=[('chest', '宝箱'), ('stone', '召喚石')], default='chest', max_length=10, verbose_name='コンテナ')),
                ('name',        models.CharField(max_length=100, verbose_name='報酬名')),
                ('detail',      models.CharField(max_length=200, verbose_name='詳細テキスト')),
                ('icon',        models.CharField(default='⭐', max_length=10, verbose_name='アイコン絵文字')),
                ('weight',      models.IntegerField(default=10, verbose_name='排出ウェイト')),
                ('value',       models.IntegerField(default=0, verbose_name='数値（EXP量・ダイヤ数など）')),
                ('is_active',   models.BooleanField(default=True, verbose_name='有効')),
            ],
            options={
                'verbose_name':        'ガチャ報酬',
                'verbose_name_plural': 'ガチャ報酬',
                'ordering':            ['rarity', 'id'],
            },
        ),
        # ── PlayerGachaStatus ─────────────────────────────────────────
        migrations.CreateModel(
            name='PlayerGachaStatus',
            fields=[
                ('id',                 models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('daily_tickets',      models.IntegerField(default=0, verbose_name='デイリーチケット枚数')),
                ('daily_last_granted', models.DateField(blank=True, null=True, verbose_name='最終チケット付与日')),
                ('daily_pity',         models.IntegerField(default=0, verbose_name='デイリー天井カウンター')),
                ('player',             models.OneToOneField(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='gacha_status',
                    to='api.playerprofile',
                    verbose_name='プレイヤー',
                )),
            ],
            options={
                'verbose_name':        'プレイヤーガチャ状態',
                'verbose_name_plural': 'プレイヤーガチャ状態',
            },
        ),
        # ── GachaHistory ──────────────────────────────────────────────
        migrations.CreateModel(
            name='GachaHistory',
            fields=[
                ('id',          models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('ticket_type', models.CharField(choices=[('daily', 'デイリー'), ('weekly', 'ウィークリー'), ('monthly', 'マンスリー')], default='daily', max_length=10, verbose_name='チケット種別')),
                ('pulled_at',   models.DateTimeField(auto_now_add=True, verbose_name='引いた日時')),
                ('player',      models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='gacha_histories',
                    to='api.playerprofile',
                    verbose_name='プレイヤー',
                )),
                ('reward',      models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    to='api.gachareward',
                    verbose_name='獲得報酬',
                )),
            ],
            options={
                'verbose_name':        'ガチャ履歴',
                'verbose_name_plural': 'ガチャ履歴',
                'ordering':            ['-pulled_at'],
            },
        ),
    ]
