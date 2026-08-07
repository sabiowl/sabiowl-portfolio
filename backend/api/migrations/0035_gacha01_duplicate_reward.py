from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0034_account_deletion_feedback'),
    ]

    operations = [
        # ── PlayerProfile に交換ピースを追加 ──────────────────────────
        migrations.AddField(
            model_name='playerprofile',
            name='exchange_pieces',
            field=models.IntegerField(default=0, verbose_name='交換ピース'),
        ),

        # ── PendingDuplicateReward テーブルを新規作成 ─────────────────
        migrations.CreateModel(
            name='PendingDuplicateReward',
            fields=[
                ('id',            models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('player',        models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='pending_duplicate_rewards', to='api.playerprofile', verbose_name='プレイヤー')),
                ('reward',        models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, to='api.gachareward', verbose_name='重複した報酬')),
                ('status',        models.CharField(choices=[('pending', '未交換'), ('exchanged', '交換済み'), ('expired', '期限切れ')], default='pending', max_length=10, verbose_name='状態')),
                ('exchange_type', models.CharField(blank=True, choices=[('pieces', '交換ピース × 100'), ('stat_points', 'ステータスポイント × 5')], max_length=15, verbose_name='交換種別')),
                ('expires_at',    models.DateTimeField(verbose_name='有効期限')),
                ('created_at',    models.DateTimeField(auto_now_add=True, verbose_name='作成日時')),
            ],
            options={
                'verbose_name':        '重複報酬待ち',
                'verbose_name_plural': '重複報酬待ち',
                'ordering': ['-created_at'],
            },
        ),
    ]
