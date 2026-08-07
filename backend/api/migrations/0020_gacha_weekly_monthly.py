"""
Migration 0020 — ガチャ週次・月次チケット対応

変更内容:
  GachaReward      : ticket_type フィールドを追加（daily/weekly/monthly）
  PlayerGachaStatus: weekly/monthly チケット・天井・付与追跡フィールドを追加
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0019_gacha_models'),
    ]

    operations = [
        # ── GachaReward: チケット種別フィールド ─────────────────────────────────
        migrations.AddField(
            model_name='gachareward',
            name='ticket_type',
            field=models.CharField(
                max_length=10,
                choices=[('daily', 'デイリー'), ('weekly', 'ウィークリー'), ('monthly', 'マンスリー')],
                default='daily',
                verbose_name='対応チケット種別',
            ),
        ),

        # ── PlayerGachaStatus: ウィークリー ──────────────────────────────────────
        migrations.AddField(
            model_name='playergachastatus',
            name='weekly_tickets',
            field=models.IntegerField(default=0, verbose_name='ウィークリーチケット枚数'),
        ),
        migrations.AddField(
            model_name='playergachastatus',
            name='weekly_pity',
            field=models.IntegerField(default=0, verbose_name='ウィークリー天井カウンター'),
        ),
        migrations.AddField(
            model_name='playergachastatus',
            name='weekly_last_granted_week',
            field=models.DateField(null=True, blank=True, verbose_name='最終ウィークリー付与週（月曜日付）'),
        ),

        # ── PlayerGachaStatus: マンスリー ────────────────────────────────────────
        migrations.AddField(
            model_name='playergachastatus',
            name='monthly_tickets',
            field=models.IntegerField(default=0, verbose_name='マンスリーチケット枚数'),
        ),
        migrations.AddField(
            model_name='playergachastatus',
            name='monthly_pity',
            field=models.IntegerField(default=0, verbose_name='マンスリー天井カウンター'),
        ),
        migrations.AddField(
            model_name='playergachastatus',
            name='monthly_last_granted_month',
            field=models.DateField(null=True, blank=True, verbose_name='最終マンスリー付与月（1日付）'),
        ),
    ]
