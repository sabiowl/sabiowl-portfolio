"""FEAT-256: TimelineEvent に pending_google_push フィールド追加。

fire-and-forget Google push が機内モード / ネットワーク失敗で「投げて忘れた」場合の
追跡を可能にするため、Sabiowl 側に未 push フラグを明示的に持たせる。

設計:
- default=True: 新規作成時は push 対象。push 成功時に False へ書き換え。
- 既存データのバックフィル:
  - `google_event_id` を持つ = 既に push 済 → False
  - `source='google'` = Google からの取り込み起源、push 対象外 → False
  - その他（local / apple、google_event_id なし）→ default の True を維持

`?unpushed_to_google=true` クエリ（FEAT-244）を `?pending_google_push=true` に置き換え、
ストレートな bool 比較で意味が読みやすくなる。アプリ起動時の auto-retry も同クエリを
共有する。
"""
from django.db import migrations, models


def _backfill_pending(apps, schema_editor):
    TimelineEvent = apps.get_model('api', 'TimelineEvent')
    # google_event_id を持つ = 既に push 済（FEAT-244 で google-link 経由で保存済）
    (
        TimelineEvent.objects
        .filter(google_event_id__isnull=False)
        .exclude(google_event_id='')
        .update(pending_google_push=False)
    )
    # source='google' は Google→Sabiowl 取り込み起源、push 対象外
    TimelineEvent.objects.filter(source='google').update(pending_google_push=False)


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0074_timeline_event_last_synced_at'),
    ]

    operations = [
        migrations.AddField(
            model_name='timelineevent',
            name='pending_google_push',
            field=models.BooleanField(
                default=True,
                db_index=True,
                help_text='FEAT-256: Google への push が未完了かどうか。'
                          '新規作成時 True、push 成功で False。',
            ),
        ),
        migrations.RunPython(_backfill_pending, migrations.RunPython.noop),
    ]
