"""FEAT-257: PlayerProfile に gcal_push_enabled フィールド追加。

ユーザーが「Google には書き出さず読み取りのみ」と選べる明示トグル。
カレンダー連携自体（連携する／しない）と「予定を書き出す（push）」は別軸であるべき。

default=True で既存ユーザーの体験を維持（連携済の人は今までどおり push される）。
Settings 画面で OFF にすると `TimelineListView.post` 側で `pending_google_push=False` を
セットして以後の push 経路から外す（FEAT-256 のヘルパー経由）。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0075_timeline_event_pending_google_push'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='gcal_push_enabled',
            field=models.BooleanField(
                default=True,
                help_text='FEAT-257: Sabiowl の予定を Google カレンダーに書き出すかどうか。'
                          'デフォルト True で既存ユーザー体験を維持。',
            ),
        ),
    ]
