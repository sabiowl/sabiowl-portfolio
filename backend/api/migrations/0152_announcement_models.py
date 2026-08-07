"""【FEAT-458 (2026-06-21)】お知らせ機能の新規モデル追加。

Announcement (全ユーザー共通お知らせ) + PlayerAnnouncementRead (per-user 既読管理)
の 2 テーブルを新規作成。AddField のみ、破壊的データ操作なし (FEAT-250 反省遵守)。

【スキーマ影響】
- 完全新規テーブル 2 件、既存テーブルへの影響ゼロ
- PlayerProfile への FK (CASCADE) のみ、既存 player 削除時の挙動は変わらず安全
"""
import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0151_friend_gift_popup_fields'),
    ]

    operations = [
        migrations.CreateModel(
            name='Announcement',
            fields=[
                ('id', models.AutoField(
                    auto_created=True, primary_key=True, serialize=False, verbose_name='ID',
                )),
                ('title', models.CharField(
                    help_text='popup ヘッダーに表示 (短文、サビ口調推奨)',
                    max_length=100, verbose_name='タイトル',
                )),
                ('body', models.TextField(
                    help_text='popup 本体 + 通知画面詳細に表示 (500 字以内、サビ口調推奨)',
                    max_length=500, verbose_name='本文',
                )),
                ('published_at', models.DateTimeField(
                    auto_now_add=True, db_index=True, verbose_name='公開日時',
                )),
                ('expires_at', models.DateTimeField(
                    blank=True, null=True,
                    help_text='null = 無期限。設定時はその時刻以降 popup / 一覧から非表示',
                    verbose_name='公開終了日時',
                )),
                ('is_active', models.BooleanField(
                    default=True,
                    help_text='False で論理削除 (履歴保全、CLAUDE.md FEAT-250 反省遵守)',
                    verbose_name='有効フラグ',
                )),
            ],
            options={
                'verbose_name':        'お知らせ',
                'verbose_name_plural': 'お知らせ',
                'ordering':            ['-published_at'],
            },
        ),
        migrations.CreateModel(
            name='PlayerAnnouncementRead',
            fields=[
                ('id', models.AutoField(
                    auto_created=True, primary_key=True, serialize=False, verbose_name='ID',
                )),
                ('read_at', models.DateTimeField(auto_now_add=True, verbose_name='既読日時')),
                ('announcement', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='reads',
                    to='api.announcement',
                    verbose_name='お知らせ',
                )),
                ('player', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='announcement_reads',
                    to='api.playerprofile',
                    verbose_name='プレイヤー',
                )),
            ],
            options={
                'verbose_name':        'お知らせ既読',
                'verbose_name_plural': 'お知らせ既読',
            },
        ),
        migrations.AddIndex(
            model_name='playerannouncementread',
            index=models.Index(
                fields=['player', 'announcement'],
                name='api_playera_player__d3ec23_idx',
            ),
        ),
        migrations.AddConstraint(
            model_name='playerannouncementread',
            constraint=models.UniqueConstraint(
                fields=['player', 'announcement'],
                name='unique_player_announcement_read',
            ),
        ),
    ]
