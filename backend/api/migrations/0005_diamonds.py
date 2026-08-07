from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0004_checklist'),
    ]

    operations = [
        # ── PlayerProfile にダイヤ関連フィールドを追加 ────────────────────────
        migrations.AddField(
            model_name='playerprofile',
            name='diamonds',
            field=models.IntegerField(default=0, verbose_name='ダイヤモンド残高'),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='diamonds_total',
            field=models.IntegerField(default=0, verbose_name='累計獲得ダイヤ'),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='diamond_bonus_date',
            field=models.DateField(blank=True, null=True, verbose_name='最終ダイヤボーナス日'),
        ),
        # ── Habit にストリーク保護日を追加 ────────────────────────────────────
        migrations.AddField(
            model_name='habit',
            name='shield_date',
            field=models.DateField(blank=True, null=True, verbose_name='ストリーク保護日'),
        ),
    ]
