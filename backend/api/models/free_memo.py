"""【FEAT-493 (2026-07-25)】仮メモ機能 (旧: フリーメモ / 思いつきメモ) — Quick Capture → Later Triage。

GTD の Collect フェーズと Process/Organize フェーズを分離するための
「思いついた瞬間の低摩擦キャプチャ」データモデル。

【運用ルール (2026-07-26 codebase-functional-review §4 C-2 対応)】
------------------------------------------------------------------------
本 model の field 意味 (特に archived_at / deleted_at / free_memo_enabled)
を変える FEAT では、着手時に必ずそのフィールド名を repo 全体 grep し、
ヒットした docstring / コメントを **同じコミットで直すこと**。

【FEAT-502 (2026-07-26)】archived_at / deleted_at の意味分離を実施済:
  - archived_at = auto archive (archive_old_memos cron の格納先、現状未稼働で温存)
  - deleted_at  = user 削除 (soft delete、trash 行)
  この 2 field は意味的に独立。混同すると「30 日放置メモが全ユーザーの
  ゴミ箱に一斉出現 → 誤完全削除」の地雷になる (FEAT-502 §1 参照)。

例: `grep -rn "archived_at" backend/ mobile/ doc/`

理由: 個別修正では 3 日後にまた drift が出る (前回 memo_page.dart 冒頭
コメント修正 → 翌日別 4 ファイルで再発の実測。20260726 レビュー §4 C-2)。
------------------------------------------------------------------------
"""
from django.db import models


class FreeMemo(models.Model):
    """未整理メモ (仮メモ、旧「フリーメモ」)。

    kill-switch 付き default-ON 機能 (FEAT-493 Phase 1)。
    migration 0186 (2026-07-25) で `PlayerProfile.free_memo_enabled` default が
    False → True に変更、既存 row も backfill 済。フラグは実質「使わない人向け
    の非表示スイッチ」として機能 (settings 画面から user が OFF に可)。

    ⚠️ archived_at / deleted_at の意味分離 (FEAT-502、2026-07-26 実施済):
      **archived_at (FEAT-493)**: 「30 日超で未処理のメモを management command で
      自動 archive」用の格納先。現状 Render Free tier の Cron Jobs 非対応で
      archive_old_memos.py cron は未稼働。将来復活時の格納先として温存。
      **deleted_at (FEAT-500 → FEAT-502)**: soft delete (user 削除、trash) の格納先。
      user の左スワイプ削除で `deleted_at = now()` (trash 移動)、restore で null、
      purge で hard delete。
      **背景 (FEAT-502 §1)**: FEAT-500 は migration 回避のため archived_at を
      soft delete に流用したが、cron 復活時に「auto archive」と「user 削除」が
      同一 field で混在 → 誤完全削除の地雷になるため、v1.0.4 リリース前
      (移行データほぼ空の window) に deleted_at を新設して構造分離した。
      詳細: doc/instructions/FEAT-502_deleted_at_field_separation.md

    削除フロー (FEAT-500 → FEAT-502、2026-07-26 更新):
      左スワイプ → 確認ダイアログ → soft delete (deleted_at=now)
      → trash 一覧 (?archived=true) に表示 → 復元 or 完全削除 (purge)。
      2 秒 undo は b26d296 (2026-07-25) で撤廃済 (「戻せない状態で誤解を招く」対応)。
      ※ query param 名 `?archived=true` は後方互換で据置 (内部 filter は deleted_at)。

    変換: 右スワイプ → 予定 / ToDo / 習慣 を既存 API で作成 → 本メモを削除 + EXP 付与。

    Phase 3 予約フィールド (ai_suggested_type / ai_suggested_at) は値 null の状態で維持し、
    AI 判定機能実装前は一切参照しない。
    """

    player = models.ForeignKey(
        'PlayerProfile',
        on_delete=models.CASCADE,
        related_name='free_memos',
        verbose_name='プレイヤー',
    )
    text = models.TextField(
        max_length=500,
        verbose_name='メモ本文',
    )
    created_at  = models.DateTimeField(auto_now_add=True, verbose_name='作成日時')
    updated_at  = models.DateTimeField(auto_now=True,     verbose_name='更新日時')
    archived_at = models.DateTimeField(
        null=True, blank=True,
        help_text='【FEAT-502 (2026-07-26)】v1.0.4 で意味分離済。'
                  '本 field は将来の archive_old_memos cron 復活時の格納先として温存。'
                  'user 削除は deleted_at (FEAT-500 → FEAT-502)。',
        verbose_name='アーカイブ日時 (auto archive 用)',
    )
    deleted_at = models.DateTimeField(
        null=True, blank=True,
        help_text='【FEAT-502 (2026-07-26)】user 削除 (soft delete、ゴミ箱行) の格納先。'
                  'restore で null、purge で hard delete + row 消失。'
                  'archive_old_memos cron の archived_at とは意味的に独立。',
        verbose_name='削除日時 (soft delete)',
    )

    # 【FEAT-493 Phase 3 予約】将来 AI 判定 metadata
    ai_suggested_type = models.CharField(
        max_length=16,
        null=True, blank=True,
        choices=[('event', '予定'), ('todo', 'ToDo'), ('habit', '習慣')],
        help_text='Phase 3 AI 判定で設定される推測種別。Phase 1-2 では常に null。',
        verbose_name='AI 推薦種別',
    )
    ai_suggested_at = models.DateTimeField(
        null=True, blank=True,
        help_text='Phase 3 AI 判定の実行日時。Phase 1-2 では常に null。',
        verbose_name='AI 推薦日時',
    )

    class Meta:
        app_label = 'api'
        verbose_name = 'フリーメモ'
        verbose_name_plural = 'フリーメモ'
        ordering = ['-created_at']
        indexes = [
            models.Index(
                fields=['player', '-created_at'],
                name='idx_freememo_player_created',
            ),
            models.Index(
                fields=['archived_at'],
                name='idx_freememo_archived_at',
            ),
            # 【FEAT-502 (2026-07-26)】user 削除 filter (deleted_at__isnull) の
            # hot path。active/trash 一覧・purge の通過条件で使用。
            models.Index(
                fields=['deleted_at'],
                name='idx_freememo_deleted_at',
            ),
        ]

    def __str__(self) -> str:
        preview = self.text[:30] + '...' if len(self.text) > 30 else self.text
        return f'[{self.player_id}] {preview}'

    @property
    def is_archived(self) -> bool:
        """auto archive (archive_old_memos cron) されているか。user 削除とは別。"""
        return self.archived_at is not None

    @property
    def is_deleted(self) -> bool:
        """【FEAT-502】user が削除 (soft delete、trash) しているか。"""
        return self.deleted_at is not None
