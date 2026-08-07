"""【2026-06-27】Announcement.published_at を editable 化 (公開予約機能)。

【背景】
ユーザー判断 (2026-06-27): お知らせ機能で公開開始日を設定したい。お知らせを予め
登録しておき、指定時刻で自動公開する運用が必要 (新キャラ追加時のフロー整備)。

【変更内容】
  AlterField only:
    auto_now_add=True (内部で editable=False) → default=timezone.now (editable)
  - 既存データの値はそのまま保持される (Django の AlterField 通常挙動)
  - help_text を追加して admin で「公開予約」運用を明示

【スキーマ変更のみ、データ操作なし】(RunPython 不使用、FEAT-250 反省遵守)

【既存挙動への影響】
  - 既存 published_at = 過去時刻 → そのまま (View の `published_at__lte=now` 通過、表示)
  - 新規 admin で default = 「今」 → 即時公開 (旧挙動と同等)
  - 新規 admin で未来日設定 → その時刻まで View 層で非表示、到達後自動公開 (新機能)

【View 層の整合性】
  本 migration と同時に AnnouncementUnreadView / AnnouncementListView の queryset
  に `.filter(published_at__lte=now)` を追加 (未来日のお知らせは非表示)。両者は
  対セットなので、片方だけ deploy するとずれる (本 commit で一括変更)。
"""
import django.utils.timezone
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0161_character_is_published'),
    ]

    operations = [
        migrations.AlterField(
            model_name='announcement',
            name='published_at',
            field=models.DateTimeField(
                db_index=True,
                default=django.utils.timezone.now,
                help_text='未来日時に設定すると、その時刻になるまで非公開 (公開予約)。'
                          'default は現在時刻 = 「保存と同時に公開」',
                verbose_name='公開日時',
            ),
        ),
    ]
