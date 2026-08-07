"""【2026-06-27】新キャラ追加機能 (Gemini 要件 character_add_announce.md) のスキーマ拡張。

Phase 1 minimal: 既存 Announcement / AnnouncementPopupListener / _CharacterDetailSheet を
最大活用する PM 推奨案。3 fields 追加のみ:

- Character.tagline: キャッチコピー (詳細シート / popup で表示)
- Character.release_date: 公開日 (Mobile で is_new バッジ算出)
- Announcement.link_character: お知らせ → キャラ詳細への動線 FK

スキーマ変更のみ (AddField × 3)、RunPython 不使用、データ破壊なし。
既存キャラ (全 24 体) は tagline='' (空文字)、release_date=null で migration 後も
NEW バッジ非表示・通常動作のまま維持。運営は admin で必要なキャラから順次設定。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0159_achievements_30'),
    ]

    operations = [
        migrations.AddField(
            model_name='character',
            name='tagline',
            field=models.CharField(
                blank=True,
                default='',
                help_text='例: 「静かな航路を共に行く者」 — 詳細シート / 紹介 popup で表示',
                max_length=80,
                verbose_name='キャッチコピー',
            ),
        ),
        migrations.AddField(
            model_name='character',
            name='release_date',
            field=models.DateField(
                blank=True,
                help_text='null = 既存キャラ。設定日 (≤ 今日) から 30 日間は NEW バッジ表示',
                null=True,
                verbose_name='公開日',
            ),
        ),
        migrations.AddField(
            model_name='announcement',
            name='link_character',
            field=models.ForeignKey(
                blank=True,
                help_text='設定すると popup に「詳細を見る」ボタンが表示され、tap で詳細シート展開',
                null=True,
                on_delete=models.deletion.SET_NULL,
                related_name='announcements',
                to='api.character',
                verbose_name='紐付けキャラクター',
            ),
        ),
    ]
