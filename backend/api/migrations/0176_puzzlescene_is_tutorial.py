"""【FEAT-479 v1 hotfix (2026-07-07)】PuzzleWorldScene.is_tutorial 追加。

新規ユーザーの 3 日以内成功体験用の tutorial-shaped シーンを master data 側で
識別可能にする。既存 3 シーン (morning_grassland / noon_castle_town /
night_forest_camp) は default False のまま影響なし。

通常 AddField のみ、破壊的変更なし。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0175_puzzle_world_scene_seed'),
    ]

    operations = [
        migrations.AddField(
            model_name='puzzleworldscene',
            name='is_tutorial',
            field=models.BooleanField(
                default=False,
                help_text=(
                    '【FEAT-479 (2026-07-07)】新規ユーザーの 3 日以内成功体験用シーン。'
                    'True のシーンは SceneSelectionPage の一覧から除外され、'
                    'silent auto-activate 経路 (最初のタスク達成) でのみ active 化される。'
                    '完成後は next_scene_hint で通常シーンに自然誘導される。'
                ),
                verbose_name='チュートリアル用',
            ),
        ),
    ]
