"""【FEAT-379 (2026-05-29)】PlayerProfile に 6 結晶カウンターフィールドを追加。

命名: CATEGORY_STAT_MAP 英語キーと完全整合 (Gemini 3 軸案不採用)。
v1.0 では累積表示のみ、装着効果発動は v1.1+ 解禁予定。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0105_streak_protection_fields'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='exercise_crystal_count',
            field=models.IntegerField(default=0, verbose_name='運動の結晶'),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='learning_crystal_count',
            field=models.IntegerField(default=0, verbose_name='学習の結晶'),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='health_crystal_count',
            field=models.IntegerField(default=0, verbose_name='健康の結晶'),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='mental_crystal_count',
            field=models.IntegerField(default=0, verbose_name='精神の結晶'),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='creation_crystal_count',
            field=models.IntegerField(default=0, verbose_name='創造の結晶'),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='contribution_crystal_count',
            field=models.IntegerField(default=0, verbose_name='貢献の結晶'),
        ),
    ]
