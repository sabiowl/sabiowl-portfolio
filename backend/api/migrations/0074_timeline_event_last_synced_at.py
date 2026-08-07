"""FEAT-255: TimelineEvent に last_synced_at + updated_at を追加。

双方向同期で「新しい方が勝つ」ルールを構造的に成立させるため、Sabiowl 側の
最終更新時刻 (`updated_at`) と最後に Google と同期した時刻 (`last_synced_at`)
を分離して保持する。

設計:
- `updated_at` (auto_now=True): Sabiowl が書き換えた瞬間に更新（編集 / 完了等）
- `last_synced_at` (nullable): push 成功時 / Google→Sabiowl 取り込み更新時に明示書き込み

取り込みロジック (`ExternalCalendarImportView`):
- Sabiowl 起源 (`google_event_id` 持ち) のイベントが Google から戻ってきたら、
  `google_updated > last_synced_at + 1秒バッファ` なら Sabiowl 側を Google で上書き、
  それ以外は skip（Sabiowl の方が新しい、または同時刻なので双方向ループ防止）。

`+1秒バッファ` は Google updated（秒精度）と Django updated_at（マイクロ秒精度）の
ジッタを吸収する。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0073_cleanup_stale_users_for_dev_reset'),
    ]

    operations = [
        migrations.AddField(
            model_name='timelineevent',
            name='updated_at',
            field=models.DateTimeField(
                auto_now=True,
                help_text='FEAT-255: Sabiowl 側の最終更新時刻。'
                          'Google 取り込み時の timestamp 比較に使う。',
            ),
        ),
        migrations.AddField(
            model_name='timelineevent',
            name='last_synced_at',
            field=models.DateTimeField(
                null=True,
                blank=True,
                db_index=True,
                help_text='FEAT-255: Google との最終同期時刻。'
                          'Google updated > last_synced_at のときに取り込み更新する。',
            ),
        ),
    ]
