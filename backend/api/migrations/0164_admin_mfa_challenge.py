# Generated 2026-06-29 (cleanup: Django 5.2 BigAutoField / RenameIndex / PlayerProfile help_text の
# 自動同期は本 FEAT と直交するため除外。それらは別 PR で扱う前提)。
#
# 【2026-06-29】admin 画面 メール OTP MFA の状態管理モデル。
# models/admin_mfa.py:AdminMFAChallenge の初回 migration。
# RunPython 等の破壊的データ操作なし (CreateModel + AddField user + AddIndex のみ)。

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0163_announcement_image'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name='AdminMFAChallenge',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('code', models.CharField(help_text='secrets.randbelow(1_000_000):06d で生成', max_length=6, verbose_name='OTP コード (6 桁)')),
                ('created_at', models.DateTimeField(auto_now_add=True, verbose_name='発行日時')),
                ('used', models.BooleanField(default=False, help_text='True = 既に検証成功 or 上限到達 or 新規発行で無効化された', verbose_name='使用済 / 無効化')),
                ('attempt_count', models.IntegerField(default=0, help_text='brute-force ガード用、5 回失敗で used=True', verbose_name='試行回数')),
                ('user', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='mfa_challenges',
                    to=settings.AUTH_USER_MODEL,
                    verbose_name='ユーザー',
                )),
            ],
            options={
                'verbose_name': 'admin MFA チャレンジ',
                'verbose_name_plural': 'admin MFA チャレンジ',
                'ordering': ['-created_at'],
            },
        ),
        migrations.AddIndex(
            model_name='adminmfachallenge',
            index=models.Index(fields=['user', 'used', '-created_at'], name='api_adminmf_user_id_35da0c_idx'),
        ),
    ]
