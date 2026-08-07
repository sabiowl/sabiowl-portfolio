"""【FEAT-458 (2026-06-21)】お知らせ機能のモデル定義。

ホーム画面に「お知らせ概要」popup を表示し、ユーザーが「確認した」を押すと
非表示化、通知画面で再確認可能にする機能。

【設計判断】
- Notification (個人通知) とは別軸: Announcement は全ユーザー共通の 1 レコード
- PlayerAnnouncementRead で per-user の既読管理 (M2M relation)
- 既存 Notification.player FK 配布方式 (N×M 行) より DB 効率良 + 新規ユーザー
  自動対応

【運用】
- Django admin から運営が GUI でお知らせ追加可能 (admin.py 自動登録)
- title (短文 100 字) + body (本文 500 字) + 公開期間 (published_at / expires_at)
- is_active=False で論理削除 (履歴保全)

【2026-06-27】公開予約機能を追加。
- `published_at` を auto_now_add → default=timezone.now に変更し editable 化
- 未来日時に設定すれば「公開予約」(その時刻まで View 層で非表示、到達後自動公開)
- View 層で `.filter(published_at__lte=now)` を追加して未来日のお知らせを除外
"""
from django.db import models
from django.utils import timezone

from .player import PlayerProfile


class Announcement(models.Model):
    """全ユーザー共通のお知らせ (運営 → 全ユーザー)。

    例:
      - 新機能リリース告知
      - メンテナンス予定通知
      - 季節イベント告知
      - 利用規約改定の周知

    1 行で全ユーザーに配信される設計 (Notification の N×M 行配布と対比)。
    """

    title = models.CharField(
        max_length=100,
        verbose_name='タイトル',
        help_text='popup ヘッダーに表示 (短文、サビ口調推奨)',
    )
    # 【FEAT-489 Phase 4】英語版 title / body。空欄 = ja に silent fallback。
    title_en = models.CharField(
        max_length=100,
        blank=True,
        default='',
        verbose_name='タイトル(英語版)',
    )
    body = models.TextField(
        max_length=500,
        verbose_name='本文',
        help_text='popup 本体 + 通知画面詳細に表示 (500 字以内、サビ口調推奨)',
    )
    body_en = models.TextField(
        blank=True,
        default='',
        verbose_name='本文(英語版)',
    )
    # 【2026-06-27】お知らせ画像 (任意)。Mobile popup / 履歴の本文上に表示。
    # upload_to で MEDIA_ROOT/announcements/ 配下に保存される (PNG / JPG / WebP 等)。
    # 本番 Render は ephemeral filesystem のため再 deploy で消失する点に注意、
    # 頻繁な画像更新があれば v1.1+ で S3 等 external storage に移行する想定。
    image = models.ImageField(
        upload_to='announcements/',
        null=True,
        blank=True,
        verbose_name='お知らせ画像',
        help_text='任意。本文の上に大きく表示されます (PNG / JPG / WebP 推奨)。'
                  '横長 16:9 推奨、最大 2MB 目安。',
    )
    # 【2026-06-27】auto_now_add=True → default=timezone.now に変更 (editable 化)。
    # 未来日時に設定すれば「公開予約」: その時刻まで View 層で非表示、到達後自動公開。
    # 既存お知らせの published_at 値は migration AlterField で保持される (後方互換)。
    published_at = models.DateTimeField(
        default=timezone.now,
        verbose_name='公開日時',
        db_index=True,
        help_text='未来日時に設定すると、その時刻になるまで非公開 (公開予約)。'
                  'default は現在時刻 = 「保存と同時に公開」',
    )
    expires_at = models.DateTimeField(
        null=True, blank=True,
        verbose_name='公開終了日時',
        help_text='null = 無期限。設定時はその時刻以降 popup / 一覧から非表示',
    )
    is_active = models.BooleanField(
        default=True,
        verbose_name='有効フラグ',
        help_text='False で論理削除 (履歴保全、CLAUDE.md FEAT-250 反省遵守)',
    )
    # 【2026-06-27】新キャラ追加機能 (Gemini 要件) のキャラ紹介への動線。
    # null = 通常のお知らせ (本文のみ表示)。Character 設定時は popup / 一覧 tap で
    # 「詳細を見る」ボタンが表示され、tap で `_CharacterDetailSheet` を開く。
    # on_delete=SET_NULL: キャラ削除 (論理的には起こらないが) 時もお知らせ履歴は保持。
    link_character = models.ForeignKey(
        'api.Character',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='announcements',
        verbose_name='紐付けキャラクター',
        help_text='設定すると popup に「詳細を見る」ボタンが表示され、tap で詳細シート展開',
    )

    class Meta:
        app_label    = 'api'
        verbose_name = 'お知らせ'
        verbose_name_plural = 'お知らせ'
        ordering     = ['-published_at']

    def __str__(self):
        return f'[{self.published_at:%Y-%m-%d}] {self.title}'


class PlayerAnnouncementRead(models.Model):
    """プレイヤーごとの Announcement 既読管理。

    User が「確認した」を押した瞬間に 1 行作成、UniqueConstraint で重複なし。
    既読 = 行が存在する、未読 = 行が存在しない (シンプルな存在チェック設計)。
    """

    player = models.ForeignKey(
        PlayerProfile,
        on_delete=models.CASCADE,
        related_name='announcement_reads',
        verbose_name='プレイヤー',
    )
    announcement = models.ForeignKey(
        Announcement,
        on_delete=models.CASCADE,
        related_name='reads',
        verbose_name='お知らせ',
    )
    read_at = models.DateTimeField(
        auto_now_add=True,
        verbose_name='既読日時',
    )

    class Meta:
        app_label    = 'api'
        verbose_name = 'お知らせ既読'
        verbose_name_plural = 'お知らせ既読'
        constraints = [
            models.UniqueConstraint(
                fields=['player', 'announcement'],
                name='unique_player_announcement_read',
            ),
        ]
        # 「特定 player の既読 announcement 一覧」を取るクエリ用
        indexes = [
            models.Index(fields=['player', 'announcement']),
        ]

    def __str__(self):
        return f'{self.player.name} 既読: {self.announcement.title[:20]}'
