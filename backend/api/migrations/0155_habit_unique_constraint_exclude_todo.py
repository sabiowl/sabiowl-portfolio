"""【ユーザー要望 2026-06-22】Habit の UniqueConstraint から ToDo を除外。

旧: condition=Q(is_active=True)
    → 同名のアクティブ習慣・ToDo すべて禁止 (1 つのプレイヤーに同名 ToDo を
       2 つ作ると IntegrityError → API は 400/500、Mobile は「追加がうまく
       いきませんでした 🪶」を表示する)。

新: condition=Q(is_active=True) & ~Q(habit_type='todo')
    → ToDo (habit_type='todo') は同名 OK。
    → 習慣 (count / checklist) は同名禁止のまま (Sabiowl 既存方針維持)。

【既存データへの影響】
新 constraint は旧 constraint より「緩い」(ToDo を除外する分だけ条件が弱まる)
ため、旧 constraint を満たしている既存データはすべて新 constraint も満たす。
すなわち、本 migration apply で IntegrityError は発生しない。

【破壊的データ操作の有無】
RemoveConstraint + AddConstraint のみ。データの delete / update なし。
CLAUDE.md「破壊的データマイグレーション禁止」原則の対象外。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0154_maintenance_config'),
    ]

    operations = [
        migrations.RemoveConstraint(
            model_name='habit',
            name='unique_active_habit_name_per_player',
        ),
        migrations.AddConstraint(
            model_name='habit',
            constraint=models.UniqueConstraint(
                condition=models.Q(('is_active', True)) & ~models.Q(('habit_type', 'todo')),
                fields=('player', 'name'),
                name='unique_active_habit_name_per_player',
            ),
        ),
    ]
