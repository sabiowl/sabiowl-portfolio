"""【FEAT-463 (2026-06-22)】緊急メンテナンスモードの新規モデル追加。

MaintenanceConfig (Singleton: pk=1 固定) を新規作成。AddField のみ、
破壊的データ操作なし (CLAUDE.md「破壊的データマイグレーション禁止」原則の対象外)。

【スキーマ影響】
- 完全新規テーブル 1 件、既存テーブルへの影響ゼロ
- User への FK (SET_NULL) のみ、既存 user 削除時の挙動は変わらず安全
"""
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0153_weapon_tier'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name='MaintenanceConfig',
            fields=[
                ('id', models.AutoField(
                    auto_created=True, primary_key=True, serialize=False, verbose_name='ID',
                )),
                ('is_enabled', models.BooleanField(
                    default=False, verbose_name='メンテナンスモード有効',
                    help_text='ON にすると全クライアントに maintenance overlay を表示します。',
                )),
                ('title', models.CharField(
                    blank=True, default='現在、システムに手当てをしております',
                    max_length=60, verbose_name='タイトル',
                )),
                ('body', models.TextField(
                    blank=True, default='少し時間をおいて、もう一度お試しください 🪶',
                    max_length=400, verbose_name='本文 (サビ口調推奨)',
                )),
                ('expires_at', models.DateTimeField(
                    blank=True, null=True, verbose_name='自動失効時刻',
                    help_text=(
                        'この時刻を過ぎたら maintenance は自動的に解除されます '
                        '(DB の is_enabled は admin が手動 OFF してください。未入力時は無期限です)。'
                    ),
                )),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('created_by', models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name='maintenance_changes',
                    to=settings.AUTH_USER_MODEL,
                    verbose_name='最終更新者',
                )),
            ],
            options={
                'verbose_name': '緊急メンテナンス設定',
                'verbose_name_plural': '緊急メンテナンス設定',
            },
        ),
    ]
