"""【FEAT-436 Phase 2 (2026-06-17)】IAPReceipt モデル新規作成。

RevenueCat webhook で受信した購入イベントを記録するテーブル。
event_id (RevenueCat の event UUID) で冪等性確保、player FK で player 削除時に
CASCADE、raw_payload に webhook ボディ全体を保存 (デバッグ + ベンダーロックイン
時の自前検証フォールバック用)。

本 migration は破壊的データ操作なし (CLAUDE.md「破壊的データマイグレーション
禁止」原則に整合)、AddField のみ。
"""
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0145_weekly_ssr_character_0_5pct'),
    ]

    operations = [
        migrations.CreateModel(
            name='IAPReceipt',
            fields=[
                ('id', models.AutoField(
                    auto_created=True,
                    primary_key=True,
                    serialize=False,
                    verbose_name='ID',
                )),
                ('event_id', models.CharField(
                    max_length=64,
                    unique=True,
                    verbose_name='RevenueCat event UUID',
                    help_text='冪等性キー、同一 event は 1 度しか付与しない',
                )),
                ('event_type', models.CharField(
                    max_length=32,
                    choices=[
                        ('INITIAL_PURCHASE',      '初回購入'),
                        ('NON_RENEWING_PURCHASE', '買い切り'),
                        ('CANCELLATION',          '返金/取消'),
                        ('UNCATEGORIZED_PURCHASE','その他'),
                    ],
                    verbose_name='イベント種別',
                )),
                ('product_id', models.CharField(
                    max_length=100,
                    verbose_name='商品 ID',
                    help_text='例: diamond_pack_120',
                )),
                ('transaction_id', models.CharField(
                    max_length=100,
                    blank=True,
                    default='',
                    verbose_name='トランザクション ID',
                    help_text='Apple/Google 由来の transaction_id',
                )),
                ('store', models.CharField(
                    max_length=20,
                    choices=[
                        ('app_store',  'Apple App Store'),
                        ('play_store', 'Google Play'),
                        ('sandbox',    'Sandbox/Test'),
                    ],
                    verbose_name='ストア',
                )),
                ('app_user_id', models.CharField(
                    max_length=64,
                    verbose_name='App User ID',
                    help_text='Purchases.configure(appUserID) で渡した PlayerProfile.id 文字列',
                )),
                ('status', models.CharField(
                    max_length=10,
                    choices=[
                        ('pending',  '受信済 (処理中)'),
                        ('granted',  'ダイヤ付与済'),
                        ('skipped',  '対象外 (entitlement のみ等)'),
                        ('failed',   'エラー (ログ記録)'),
                        ('refunded', '返金処理済'),
                    ],
                    default='pending',
                    verbose_name='処理状態',
                )),
                ('granted_diamonds', models.IntegerField(
                    default=0,
                    verbose_name='付与ダイヤ数',
                )),
                ('raw_payload', models.JSONField(
                    verbose_name='webhook 生ペイロード',
                    help_text='デバッグ + ベンダーロックイン時の自前検証フォールバック用',
                )),
                ('error_message', models.TextField(
                    blank=True,
                    default='',
                    verbose_name='エラー詳細',
                )),
                ('created_at', models.DateTimeField(
                    auto_now_add=True,
                    verbose_name='受信時刻',
                )),
                ('processed_at', models.DateTimeField(
                    null=True,
                    blank=True,
                    verbose_name='処理完了時刻',
                )),
                ('player', models.ForeignKey(
                    blank=True,
                    null=True,
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='iap_receipts',
                    to='api.playerprofile',
                    verbose_name='プレイヤー',
                    help_text='webhook 受信時に PlayerProfile が見つからない場合 null 許容',
                )),
            ],
            options={
                'verbose_name': 'IAP 領収書',
                'verbose_name_plural': 'IAP 領収書',
                'ordering': ['-created_at'],
            },
        ),
        migrations.AddIndex(
            model_name='iapreceipt',
            index=models.Index(fields=['player', '-created_at'], name='api_iaprece_player__93f0e7_idx'),
        ),
        migrations.AddIndex(
            model_name='iapreceipt',
            index=models.Index(fields=['event_id'], name='api_iaprece_event_i_94d09c_idx'),
        ),
        migrations.AddIndex(
            model_name='iapreceipt',
            index=models.Index(fields=['status'], name='api_iaprece_status_4d0fb1_idx'),
        ),
    ]
