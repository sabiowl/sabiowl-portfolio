"""【FEAT-426 (2026-06-11)】Google カレンダー予定を Mobile ローカル DB に移行 (設計 Y)。

GoogleEventCompletion model 新規追加。Google 予定の本文 (title/start_time/memo)
は Mobile ローカル DB のみに保存し、Backend は完了状態 + Multi-device 同期に
必要な最小限のメタデータ (event_id + 完了フラグ + on_time_bonus_awarded) のみ
保持する。

通常の AddModel + AddIndex のみ、破壊的変更なし。
"""
from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0125_friend_id_8digit'),
    ]

    operations = [
        migrations.CreateModel(
            name='GoogleEventCompletion',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('google_event_id', models.CharField(max_length=255)),
                ('event_date', models.DateField(help_text='cleanup 判定用 (本 model も 30 日経過で削除可能)')),
                ('is_completed', models.BooleanField(default=False)),
                ('on_time_bonus_awarded', models.BooleanField(default=False)),
                ('completed_at', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('player', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='google_event_completions', to='api.playerprofile')),
            ],
            options={
                'unique_together': {('player', 'google_event_id')},
            },
        ),
        migrations.AddIndex(
            model_name='googleeventcompletion',
            index=models.Index(fields=['player', 'event_date'], name='api_googlee_player__6f0b89_idx'),
        ),
    ]
