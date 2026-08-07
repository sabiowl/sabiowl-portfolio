"""【FEAT-479 (2026-07-06)】ジグソーパズル世界システム Ver1 — Phase 1 Step 1。

指示書: `doc/instructions/FEAT-479_puzzle_world_ver1.md` §3.5

- CreateModel × 4 (PuzzleWorldScene / PlayerPuzzleWorld /
                  PlayerPuzzleSceneProgress / PlayerPuzzleWorldHistory)
- AddField × 2 (PlayerStreakState.last_task_piece_date /
                PlayerStreakState.last_quest_piece_date)

schema only migration。RunPython は不使用。3 シーン seed は次の 0175 で担当。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0173_playerprofile_remove_dead_fields'),
    ]

    operations = [
        migrations.CreateModel(
            name='PuzzleWorldScene',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name='ID')),
                ('key', models.CharField(max_length=50, unique=True,
                                        verbose_name='シーンキー')),
                ('name', models.CharField(max_length=100, verbose_name='表示名')),
                ('display_order', models.IntegerField(default=0, verbose_name='並び順')),
                ('piece_count', models.IntegerField(default=30, verbose_name='ピース数')),
                ('background_key', models.CharField(
                    max_length=100,
                    help_text='Mobile 側の WorldAnimatedLayers 選択 key と一致',
                    verbose_name='背景 key',
                )),
                ('is_active', models.BooleanField(default=True, verbose_name='公開中')),
                ('reward_exp', models.IntegerField(default=1000, verbose_name='完成報酬 EXP')),
                ('reward_diamonds', models.IntegerField(default=500,
                                                        verbose_name='完成報酬 ダイヤ')),
                ('tagline', models.CharField(blank=True, default='', max_length=200,
                                             verbose_name='サビ口調 1 行紹介文')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
            ],
            options={
                'verbose_name': 'パズル世界シーン',
                'verbose_name_plural': 'パズル世界シーン',
                'ordering': ['display_order', 'id'],
            },
        ),
        migrations.CreateModel(
            name='PlayerPuzzleWorld',
            fields=[
                ('player', models.OneToOneField(
                    to='api.playerprofile',
                    on_delete=models.deletion.CASCADE,
                    primary_key=True,
                    serialize=False,
                    related_name='puzzle_world',
                    verbose_name='プレイヤー',
                )),
                ('active_scene', models.ForeignKey(
                    to='api.puzzleworldscene',
                    on_delete=models.deletion.PROTECT,
                    null=True, blank=True,
                    related_name='active_players',
                    verbose_name='アクティブシーン',
                    help_text='現在パズルを進めているシーン。null = onboarding 未完了',
                )),
                ('displayed_scene', models.ForeignKey(
                    to='api.puzzleworldscene',
                    on_delete=models.deletion.PROTECT,
                    null=True, blank=True,
                    related_name='displayed_players',
                    verbose_name='額縁表示シーン',
                    help_text='null = 自動 fallback (active → 静止画)',
                )),
                ('updated_at', models.DateTimeField(auto_now=True)),
            ],
            options={
                'verbose_name': 'プレイヤーパズル世界',
                'verbose_name_plural': 'プレイヤーパズル世界',
            },
        ),
        migrations.CreateModel(
            name='PlayerPuzzleSceneProgress',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name='ID')),
                ('piece_states', models.JSONField(
                    default=list,
                    help_text='[0..2] の整数リスト、長さ = scene.piece_count',
                    verbose_name='ピース状態',
                )),
                ('started_at', models.DateTimeField(auto_now_add=True,
                                                    verbose_name='初着手日時')),
                ('completed_at', models.DateTimeField(
                    null=True, blank=True,
                    help_text='null = 未完成',
                    verbose_name='完成日時',
                )),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('player', models.ForeignKey(
                    to='api.playerprofile',
                    on_delete=models.deletion.CASCADE,
                    related_name='puzzle_scene_progress',
                    verbose_name='プレイヤー',
                )),
                ('scene', models.ForeignKey(
                    to='api.puzzleworldscene',
                    on_delete=models.deletion.PROTECT,
                    verbose_name='シーン',
                )),
            ],
            options={
                'verbose_name': 'プレイヤーシーン進捗',
                'verbose_name_plural': 'プレイヤーシーン進捗',
                'unique_together': {('player', 'scene')},
            },
        ),
        migrations.AddIndex(
            model_name='playerpuzzlesceneprogress',
            index=models.Index(
                fields=['player', 'completed_at'],
                name='idx_ppsp_player_completed',
            ),
        ),
        migrations.CreateModel(
            name='PlayerPuzzleWorldHistory',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name='ID')),
                ('completed_at', models.DateTimeField(auto_now_add=True,
                                                      verbose_name='完成日時')),
                ('reward_exp_gained', models.IntegerField(verbose_name='付与 EXP')),
                ('reward_diamonds_gained', models.IntegerField(verbose_name='付与 ダイヤ')),
                ('player', models.ForeignKey(
                    to='api.playerprofile',
                    on_delete=models.deletion.CASCADE,
                    related_name='puzzle_world_history',
                    verbose_name='プレイヤー',
                )),
                ('scene', models.ForeignKey(
                    to='api.puzzleworldscene',
                    on_delete=models.deletion.PROTECT,
                    verbose_name='シーン',
                )),
            ],
            options={
                'verbose_name': 'パズル世界完成履歴',
                'verbose_name_plural': 'パズル世界完成履歴',
            },
        ),
        migrations.AddIndex(
            model_name='playerpuzzleworldhistory',
            index=models.Index(
                fields=['player', 'completed_at'],
                name='idx_ppwh_player_completed',
            ),
        ),
        migrations.AddField(
            model_name='playerstreakstate',
            name='last_task_piece_date',
            field=models.DateField(
                null=True, blank=True, verbose_name='最終 task piece 付与日',
            ),
        ),
        migrations.AddField(
            model_name='playerstreakstate',
            name='last_quest_piece_date',
            field=models.DateField(
                null=True, blank=True, verbose_name='最終 quest piece 付与日',
            ),
        ),
    ]
