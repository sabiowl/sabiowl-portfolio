"""【FEAT-467 (2026-07-02)】タスク登録画面タイトル候補 Backend 化。

Mobile 側 kEventPresets / kTodoPresets / kHabitPresets のハードコード配列を
Django admin 編集可能なモデルに移行する。
"""
from django.db import models


class TaskSuggestion(models.Model):
    """タスク登録画面 (予定 / ToDo / 習慣) のタイトル入力 popup で表示される候補。

    削除禁止 (履歴保全のため is_active=False での論理削除を強制)。
    """

    TYPE_CHOICES = [
        ('event', '予定'),
        ('todo',  'ToDo'),
        ('habit', '習慣'),
    ]

    type       = models.CharField(max_length=8, choices=TYPE_CHOICES, verbose_name='種別')
    title      = models.CharField(max_length=100, verbose_name='タイトル')
    # 【FEAT-489 Phase 4】英語版 title / hint。空欄 = ja に silent fallback。
    title_en   = models.CharField(max_length=100, blank=True, default='', verbose_name='タイトル(英語版)')
    # CATEGORY_CHOICES 11 値 (constants.py) と整合。空欄可 (カテゴリ推薦なし = user が別途選択)。
    category   = models.CharField(max_length=16, blank=True, default='', verbose_name='カテゴリ')
    emoji      = models.CharField(max_length=8,  blank=True, default='', verbose_name='絵文字')
    hint       = models.CharField(max_length=100, blank=True, default='', verbose_name='補足テキスト')
    hint_en    = models.CharField(max_length=100, blank=True, default='', verbose_name='補足テキスト(英語版)')
    order      = models.IntegerField(default=0, verbose_name='表示順')
    is_active  = models.BooleanField(default=True, verbose_name='有効')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        app_label        = 'api'
        verbose_name     = 'タスク候補'
        verbose_name_plural = 'タスク候補'
        ordering         = ['type', 'order', 'id']
        indexes = [
            models.Index(fields=['type', 'is_active', 'order'],
                         name='idx_tasksugg_type_active_order'),
        ]

    def __str__(self) -> str:
        return f'[{self.get_type_display()}] {self.title}'
