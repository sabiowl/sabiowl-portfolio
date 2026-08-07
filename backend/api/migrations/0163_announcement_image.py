"""【2026-06-27】Announcement.image (ImageField) 追加 + 投稿プレビュー機能。

【背景】
ユーザー判断 (2026-06-27): Django admin からお知らせ投稿時に画像もアップロードできる
ようにしたい。投稿プレビューボタン → プレビュー画面 → 投稿ボタン のフローも追加。

【変更内容】
  AddField のみ:
    image: ImageField(upload_to='announcements/', null=True, blank=True)

【スキーマ変更のみ、データ操作なし】(RunPython 不使用、FEAT-250 反省遵守)

【既存お知らせへの影響】
  image=null fallback で既存挙動維持。新規お知らせのみ admin で画像アップロード可能。

【依存】
  - Pillow パッケージ (requirements.txt で追加)
  - MEDIA_URL / MEDIA_ROOT 設定 (config/settings.py で追加)
  - DEBUG=True 時の media serving (config/urls.py で追加)
  - 本番 Render は ephemeral filesystem、v1.1+ で S3 等 external storage 移行検討

【プレビュー機能 (本 migration では DB スキーマには影響なし)】
  AnnouncementAdmin.change_view にプレビューボタン追加、別画面 (Mobile popup UI 風 HTML)
  で確認 → 「投稿する」ボタンで is_active=True + published_at=now に更新する経路。
  公開予約 (0162) との組合せで「下書き保存 → プレビュー確認 → 投稿」フローを実現。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0162_announcement_publish_schedule'),
    ]

    operations = [
        migrations.AddField(
            model_name='announcement',
            name='image',
            field=models.ImageField(
                blank=True,
                help_text='任意。本文の上に大きく表示されます (PNG / JPG / WebP 推奨)。'
                          '横長 16:9 推奨、最大 2MB 目安。',
                null=True,
                upload_to='announcements/',
                verbose_name='お知らせ画像',
            ),
        ),
    ]
