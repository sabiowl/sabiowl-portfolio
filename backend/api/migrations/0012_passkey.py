"""
Migration 0012: パスキー認証モデルの追加 + 既存ユーザーの全削除

追加モデル:
  - PasskeyCredential  (WebAuthn 認証情報)
  - PendingChallenge   (チャレンジ一時保存)
  - MagicLinkToken     (マジックリンク用ワンタイムトークン)

既存ユーザーをすべて削除します（on_delete=CASCADE により関連データも削除）。
"""

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


def delete_all_users(apps, schema_editor):
    """既存の Django User をすべて削除する。"""
    User = apps.get_model('auth', 'User')
    User.objects.all().delete()


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0011_notification_pushsubscription'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        # ─── 既存ユーザー全削除 ─────────────────────────────────────
        migrations.RunPython(delete_all_users, migrations.RunPython.noop),

        # ─── PasskeyCredential ───────────────────────────────────────
        migrations.CreateModel(
            name='PasskeyCredential',
            fields=[
                ('id',            models.BigAutoField(auto_created=True, primary_key=True, serialize=False)),
                ('credential_id', models.TextField(unique=True, verbose_name='クレデンシャルID (base64url)')),
                ('public_key',    models.TextField(verbose_name='公開鍵 (base64url / CBOR)')),
                ('sign_count',    models.PositiveIntegerField(default=0, verbose_name='署名カウント')),
                ('device_name',   models.CharField(blank=True, max_length=100, verbose_name='デバイス名')),
                ('created_at',    models.DateTimeField(auto_now_add=True, verbose_name='登録日時')),
                ('user',          models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='passkey_credentials',
                    to=settings.AUTH_USER_MODEL,
                    verbose_name='ユーザー',
                )),
            ],
            options={
                'verbose_name':        'パスキー認証情報',
                'verbose_name_plural': 'パスキー認証情報',
            },
        ),

        # ─── PendingChallenge ────────────────────────────────────────
        migrations.CreateModel(
            name='PendingChallenge',
            fields=[
                ('id',            models.BigAutoField(auto_created=True, primary_key=True, serialize=False)),
                ('key',           models.CharField(max_length=64, unique=True, verbose_name='検索キー')),
                ('challenge_b64', models.CharField(max_length=300, verbose_name='チャレンジ (base64url)')),
                ('data',          models.JSONField(default=dict, verbose_name='付属データ')),
                ('expires_at',    models.DateTimeField(verbose_name='有効期限')),
                ('created_at',    models.DateTimeField(auto_now_add=True)),
            ],
            options={
                'verbose_name':        'ペンディングチャレンジ',
                'verbose_name_plural': 'ペンディングチャレンジ',
            },
        ),
        migrations.AddIndex(
            model_name='pendingchallenge',
            index=models.Index(fields=['key'], name='api_pending_key_idx'),
        ),

        # ─── MagicLinkToken ──────────────────────────────────────────
        migrations.CreateModel(
            name='MagicLinkToken',
            fields=[
                ('id',         models.BigAutoField(auto_created=True, primary_key=True, serialize=False)),
                ('token',      models.CharField(max_length=64, unique=True, verbose_name='トークン')),
                ('email',      models.EmailField(verbose_name='メールアドレス')),
                ('name',       models.CharField(blank=True, max_length=50, verbose_name='名前（新規登録用）')),
                ('is_used',    models.BooleanField(default=False, verbose_name='使用済み')),
                ('expires_at', models.DateTimeField(verbose_name='有効期限')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
            ],
            options={
                'verbose_name':        'マジックリンクトークン',
                'verbose_name_plural': 'マジックリンクトークン',
            },
        ),
    ]
