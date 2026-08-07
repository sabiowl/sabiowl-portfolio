"""【FEAT-493 (2026-07-25)】FreeMemo モデル新規作成。

フリーメモ機能 (Quick Capture → Later Triage) の Backend 基盤。
PlayerProfile.free_memo_enabled=True の opt-in ユーザーのみ利用可能。
"""
import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0183_gift_v2_rewards'),
    ]

    operations = [
        migrations.CreateModel(
            name='FreeMemo',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('text', models.TextField(max_length=500, verbose_name='メモ本文')),
                ('created_at', models.DateTimeField(auto_now_add=True, verbose_name='作成日時')),
                ('updated_at', models.DateTimeField(auto_now=True, verbose_name='更新日時')),
                ('archived_at', models.DateTimeField(
                    blank=True, null=True,
                    help_text='30 日超で自動 archive (archive_old_memos コマンド)',
                    verbose_name='アーカイブ日時',
                )),
                ('ai_suggested_type', models.CharField(
                    blank=True, max_length=16, null=True,
                    choices=[('event', '予定'), ('todo', 'ToDo'), ('habit', '習慣')],
                    help_text='Phase 3 AI 判定で設定される推測種別。Phase 1-2 では常に null。',
                    verbose_name='AI 推薦種別',
                )),
                ('ai_suggested_at', models.DateTimeField(
                    blank=True, null=True,
                    help_text='Phase 3 AI 判定の実行日時。Phase 1-2 では常に null。',
                    verbose_name='AI 推薦日時',
                )),
                ('player', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='free_memos',
                    to='api.playerprofile',
                    verbose_name='プレイヤー',
                )),
            ],
            options={
                'verbose_name': 'フリーメモ',
                'verbose_name_plural': 'フリーメモ',
                'ordering': ['-created_at'],
                'app_label': 'api',
            },
        ),
        migrations.AddIndex(
            model_name='freememo',
            index=models.Index(
                fields=['player', '-created_at'],
                name='idx_freememo_player_created',
            ),
        ),
        migrations.AddIndex(
            model_name='freememo',
            index=models.Index(
                fields=['archived_at'],
                name='idx_freememo_archived_at',
            ),
        ),
    ]
