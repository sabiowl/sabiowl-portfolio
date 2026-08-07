from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0010_playerprofile_user'),
    ]

    operations = [
        # Notification
        migrations.CreateModel(
            name='Notification',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('notif_type', models.CharField(
                    choices=[
                        ('friend_request', 'フレンド申請'),
                        ('message',        'メッセージ'),
                        ('level_up',       'レベルアップ'),
                        ('streak_alert',   'ストリーク危機'),
                        ('title_unlocked', '称号解除'),
                    ],
                    max_length=20,
                    verbose_name='通知種別',
                )),
                ('title',      models.CharField(max_length=100, verbose_name='タイトル')),
                ('body',       models.CharField(max_length=200, verbose_name='本文')),
                ('related_id', models.IntegerField(blank=True, null=True, verbose_name='関連ID')),
                ('is_read',    models.BooleanField(default=False, verbose_name='既読')),
                ('created_at', models.DateTimeField(auto_now_add=True, verbose_name='作成日時')),
                ('player', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='notifications',
                    to='api.playerprofile',
                    verbose_name='受信プレイヤー',
                )),
            ],
            options={
                'verbose_name':        '通知',
                'verbose_name_plural': '通知',
                'ordering':            ['-created_at'],
            },
        ),
        # PushSubscription
        migrations.CreateModel(
            name='PushSubscription',
            fields=[
                ('id',         models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('endpoint',   models.TextField(verbose_name='エンドポイント')),
                ('p256dh',     models.TextField(verbose_name='p256dh 鍵')),
                ('auth',       models.TextField(verbose_name='auth 鍵')),
                ('user_agent', models.CharField(blank=True, max_length=300, verbose_name='User-Agent')),
                ('created_at', models.DateTimeField(auto_now_add=True, verbose_name='登録日時')),
                ('player', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='push_subscriptions',
                    to='api.playerprofile',
                    verbose_name='プレイヤー',
                )),
            ],
            options={
                'verbose_name':        'Push購読',
                'verbose_name_plural': 'Push購読',
                'unique_together':     {('player', 'endpoint')},
            },
        ),
    ]
