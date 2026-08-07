"""【FEAT-479 (2026-07-06)】ジグソーパズル世界システム Ver1 のモデル。

指示書: `doc/instructions/FEAT-479_puzzle_world_ver1.md` §3.1

    PuzzleWorldScene            (master data、3 シーン seed)
    PlayerPuzzleWorld           (プレイヤーのシーン選択状態、OneToOne)
    PlayerPuzzleSceneProgress   (プレイヤー × シーンごとのピース状態、ForeignKey)
    PlayerPuzzleWorldHistory    (完成履歴、1 シーン完成 = 1 レコード)

冪等性の設計:
- 「1 日 1 枚の task piece / 1 日 1 枚の quest piece」の日次フラグは
  `PlayerStreakState.last_task_piece_date` / `last_quest_piece_date` で **プレイヤー単位** 管理。
- シーン切替による日次上限リセットの悪用を構造的に防ぐ (§3.2 参照)。
"""
from django.db import models


class PuzzleWorldScene(models.Model):
    """パズル世界シーンの master data。v1.1 で 3 シーン seed。"""

    key             = models.CharField(max_length=50, unique=True, verbose_name='シーンキー')
    name            = models.CharField(max_length=100, verbose_name='表示名')
    # 【FEAT-516 (2026-08-04)】英語版。空欄なら ja にフォールバックする
    # (`get_i18n_field`)。投入は `translate_master_data` 経由。
    name_en = models.CharField(
        max_length=100,
        blank=True,
        default='',
        verbose_name='シーン名(英語版)',
    )
    display_order   = models.IntegerField(default=0, verbose_name='並び順')
    piece_count     = models.IntegerField(default=30, verbose_name='ピース数')
    background_key  = models.CharField(
        max_length=100, verbose_name='背景 key',
        help_text='Mobile 側の WorldAnimatedLayers 選択 key と一致',
    )
    is_active       = models.BooleanField(default=True, verbose_name='公開中')
    is_tutorial     = models.BooleanField(
        default=False,
        verbose_name='チュートリアル用',
        help_text=(
            '【FEAT-479 (2026-07-07)】新規ユーザーの 3 日以内成功体験用シーン。'
            'True のシーンは SceneSelectionPage の一覧から除外され、'
            'silent auto-activate 経路 (最初のタスク達成) でのみ active 化される。'
            '完成後は next_scene_hint で通常シーンに自然誘導される。'
        ),
    )
    reward_exp      = models.IntegerField(default=1000, verbose_name='完成報酬 EXP')
    reward_diamonds = models.IntegerField(default=500, verbose_name='完成報酬 ダイヤ')
    tagline         = models.CharField(
        max_length=200, blank=True, default='',
        verbose_name='サビ口調 1 行紹介文',
    )
    # 【FEAT-516 (2026-08-04)】英語版。空欄なら ja にフォールバックする
    # (`get_i18n_field`)。投入は `translate_master_data` 経由。
    tagline_en = models.CharField(
        max_length=200,
        blank=True,
        default='',
        verbose_name='キャッチコピー(英語版)',
    )
    created_at      = models.DateTimeField(auto_now_add=True)

    class Meta:
        app_label = 'api'
        verbose_name = 'パズル世界シーン'
        verbose_name_plural = 'パズル世界シーン'
        ordering = ['display_order', 'id']

    def __str__(self):
        return f'{self.name} ({self.key})'


class PlayerPuzzleWorld(models.Model):
    """プレイヤーのシーン選択状態 (アクティブ / ディスプレイド)。ピース状態は分離。"""

    player          = models.OneToOneField(
        'PlayerProfile',
        on_delete=models.CASCADE,
        related_name='puzzle_world',
        primary_key=True,
        verbose_name='プレイヤー',
    )
    active_scene    = models.ForeignKey(
        PuzzleWorldScene,
        on_delete=models.PROTECT,
        null=True, blank=True,
        related_name='active_players',
        verbose_name='アクティブシーン',
        help_text='現在パズルを進めているシーン。null = onboarding 未完了',
    )
    displayed_scene = models.ForeignKey(
        PuzzleWorldScene,
        on_delete=models.PROTECT,
        null=True, blank=True,
        related_name='displayed_players',
        verbose_name='額縁表示シーン',
        help_text='null = 自動 fallback (active → 静止画)',
    )
    updated_at      = models.DateTimeField(auto_now=True)

    class Meta:
        app_label = 'api'
        verbose_name = 'プレイヤーパズル世界'
        verbose_name_plural = 'プレイヤーパズル世界'

    def __str__(self):
        active = self.active_scene.key if self.active_scene_id else 'none'
        return f'{self.player.name} — active={active}'


class PlayerPuzzleSceneProgress(models.Model):
    """プレイヤー × シーンごとのピース状態。

    アクティブでないシーンも一度着手すれば残る (再開可能)。
    完成後は piece_states 全 2 で凍結、完成履歴と対応。
    """

    player        = models.ForeignKey(
        'PlayerProfile',
        on_delete=models.CASCADE,
        related_name='puzzle_scene_progress',
        verbose_name='プレイヤー',
    )
    scene         = models.ForeignKey(
        PuzzleWorldScene,
        on_delete=models.PROTECT,
        verbose_name='シーン',
    )
    piece_states  = models.JSONField(
        default=list,
        verbose_name='ピース状態',
        help_text='[0..2] の整数リスト、長さ = scene.piece_count',
    )
    started_at    = models.DateTimeField(auto_now_add=True, verbose_name='初着手日時')
    completed_at  = models.DateTimeField(
        null=True, blank=True, verbose_name='完成日時',
        help_text='null = 未完成',
    )
    updated_at    = models.DateTimeField(auto_now=True)

    class Meta:
        app_label = 'api'
        verbose_name = 'プレイヤーシーン進捗'
        verbose_name_plural = 'プレイヤーシーン進捗'
        unique_together = [('player', 'scene')]
        indexes = [
            models.Index(
                fields=['player', 'completed_at'],
                name='idx_ppsp_player_completed',
            ),
        ]

    def __str__(self):
        return f'{self.player.name} — {self.scene.key}'


class PlayerPuzzleWorldHistory(models.Model):
    """完成履歴。1 シーン完成ごとに 1 レコード。"""

    player                 = models.ForeignKey(
        'PlayerProfile',
        on_delete=models.CASCADE,
        related_name='puzzle_world_history',
        verbose_name='プレイヤー',
    )
    scene                  = models.ForeignKey(
        PuzzleWorldScene,
        on_delete=models.PROTECT,
        verbose_name='シーン',
    )
    completed_at           = models.DateTimeField(auto_now_add=True, verbose_name='完成日時')
    reward_exp_gained      = models.IntegerField(verbose_name='付与 EXP')
    reward_diamonds_gained = models.IntegerField(verbose_name='付与 ダイヤ')

    class Meta:
        app_label = 'api'
        verbose_name = 'パズル世界完成履歴'
        verbose_name_plural = 'パズル世界完成履歴'
        indexes = [
            models.Index(
                fields=['player', 'completed_at'],
                name='idx_ppwh_player_completed',
            ),
        ]

    def __str__(self):
        return f'{self.player.name} — {self.scene.key} @ {self.completed_at:%Y-%m-%d}'
