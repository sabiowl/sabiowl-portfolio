"""【新規 (2026-06-26)】サビセリフを Django admin から CRUD 可能にするモデル。

`sabi_dialogue.yaml` の主要プール (home / context / time_segment) を DB 化し、
管理画面から運営がメッセージの追加・編集・削除・有効/無効切替を行えるよう
にする。greetings (単一文字列) / streak.milestones (構造化) / knowledge
(category 別 fact+connection) の複雑プールは現状 YAML 維持。

## レイヤー設計

- 真実値: 本テーブル (DB) を優先、空のプールのみ YAML フォールバック
- 編集経路: Django admin (`/admin/api/sabimessage/`)
- 初期 seed: migration 0158 で YAML から自動投入 (master/seed data 例外条項)
- キャッシュ: sabi_loader.py で Django cache + post_save/post_delete signal で
  即時 invalidate
"""
from django.db import models


class SabiMessage(models.Model):
    """サビが発するセリフ 1 件 (プール所属、有効/無効切替可、並び順管理)。"""

    # ── プール choices (18 プール、UX のコア) ───────────────────────────────
    # YAML キーに `home_` / `context_` / `time_` のプレフィックスを付けて
    # フラット化。admin 画面で sort して確認しやすい設計。
    POOL_CHOICES = [
        # ─── ホーム画面の通常 message プール (default context) ──────────
        ('home_no_habits',         'ホーム: 習慣ゼロ'),
        ('home_all_done',          'ホーム: 全達成'),
        ('home_partial',           'ホーム: 一部達成'),
        ('home_none_done',         'ホーム: 達成ゼロ'),
        ('home_high_level',        'ホーム: 高レベル (Lv30+)'),
        ('home_early_level',       'ホーム: 初期レベル (Lv<5)'),
        ('home_pun',               'ホーム: コツコツ系 (10 回に 1 回)'),
        ('home_knowledge_general', 'ホーム: 習慣化知識 (7 回に 1 回)'),
        # ─── context API 経路のプール ────────────────────────────────────
        ('context_rest_day',  'context: 休息日'),
        ('context_comeback',  'context: コンバック'),
        ('context_default',   'context: デフォルト'),
        ('context_undo',      'context: Undo 操作後'),
        # ─── 時間帯別補強プール (greeting 後の文体) ──────────────────────
        ('time_early_morning', '時間帯: 早朝 (5-8 時)'),
        ('time_morning',       '時間帯: 朝 (8-12 時)'),
        ('time_noon',          '時間帯: 昼 (12-17 時)'),
        ('time_evening',       '時間帯: 夕 (17-21 時)'),
        ('time_night',         '時間帯: 夜 (21-24 時)'),
        ('time_late_night',    '時間帯: 深夜 (0-5 時)'),
    ]

    pool = models.CharField(
        max_length=32,
        choices=POOL_CHOICES,
        db_index=True,
        verbose_name='プール',
        help_text='どの場面で表示されるかのカテゴリ',
    )
    content = models.TextField(
        verbose_name='セリフ',
        help_text='サビ口調統一: 「〜ですね」「〜ますよ」、感嘆符 / じゃ / だね 禁止',
    )
    # 【FEAT-489 Phase 4】英語版セリフ。空欄 = ja に silent fallback。
    content_en = models.TextField(
        blank=True,
        default='',
        verbose_name='セリフ(英語版)',
        help_text='English version. Leave blank to fall back to Japanese content.',
    )
    is_active = models.BooleanField(
        default=True,
        db_index=True,
        verbose_name='有効',
        # 【BUG-145】本 help_text は「プール内の最後の 1 行を OFF にした場合」
        # には成り立たない (active 0 件のプールは YAML の初期値に戻る)。
        # 注意書きは `SabiMessageAdmin` の fieldset description に置いた
        # —— help_text を変えると AlterField migration が発生するため。
        help_text='OFF にすると本セリフは出現しなくなる (削除せず一時無効化したい時)',
    )
    sort_order = models.IntegerField(
        default=0,
        verbose_name='並び順',
        help_text='admin 画面の表示順 (実際の選択は seed % 件数 でランダム)',
    )
    note = models.TextField(
        blank=True,
        default='',
        verbose_name='管理メモ',
        help_text='運営用メモ。「2026-06 追加」「ABテスト対象」等 (ユーザーには非表示)',
    )
    created_at = models.DateTimeField(auto_now_add=True, verbose_name='作成日時')
    updated_at = models.DateTimeField(auto_now=True, verbose_name='更新日時')

    class Meta:
        verbose_name = 'サビセリフ'
        verbose_name_plural = 'サビセリフ'
        ordering = ['pool', 'sort_order', 'id']
        indexes = [
            # admin 画面のプール別フィルタ + 有効分のみ抽出を高速化
            models.Index(
                fields=['pool', 'is_active'],
                name='idx_sabimsg_pool_active',
            ),
        ]

    def __str__(self):
        preview = self.content if len(self.content) <= 30 else f'{self.content[:30]}…'
        return f'[{self.get_pool_display()}] {preview}'
