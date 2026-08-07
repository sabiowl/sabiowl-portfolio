"""【FEAT-465 (2026-06-24)】月次カテゴリチャレンジ (Challenge / ChallengeParticipation)。

CreateModel + AddIndex + AddConstraint のみ。既存データへの影響ゼロ
(新規テーブル 2 個 + index 5 本)。破壊的データ操作なし
(CLAUDE.md「破壊的データマイグレーション禁止」原則の対象外)。

Note: `makemigrations --dry-run` は本変更と無関係な既存ドリフト (IAPReceipt /
PlayerAnnouncementRead の RenameIndex、Announcement 等 id フィールドの
BigAutoField 化、PlayerProfile 既存フィールドの help_text/verbose_name 差分)
も検出したが、これらは FEAT-465 のスコープ外 (既存の技術的負債) のため、
本 migration には Challenge / ChallengeParticipation 関連の操作のみを含める。
"""
import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0155_habit_unique_constraint_exclude_todo'),
    ]

    operations = [
        migrations.CreateModel(
            name='Challenge',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('title', models.CharField(max_length=80, verbose_name='タイトル')),
                ('description', models.TextField(verbose_name='説明文')),
                ('category', models.CharField(choices=[('運動', '運動'), ('学習', '学習'), ('仕事', '仕事'), ('体力', '体力'), ('美容', '美容'), ('健康', '健康'), ('精神', '精神'), ('創造', '創造'), ('社交', '社交'), ('休息', '休息'), ('その他', 'その他')], max_length=20, verbose_name='対象カテゴリ')),
                ('target_count', models.IntegerField(default=100, help_text='リリース月は MAU 未確定のため 100 回暫定。毎月の参加状況を見て手動調整すること。', verbose_name='目標回数')),
                ('reward_exp', models.IntegerField(default=500, verbose_name='達成時の報酬 EXP')),
                ('current_count', models.IntegerField(default=0, help_text='denormalized counter。F() 式で atomic increment するため直接編集は推奨しない。', verbose_name='全ユーザー貢献累計')),
                ('start_date', models.DateField(verbose_name='開始日')),
                ('end_date', models.DateField(verbose_name='終了日')),
                ('is_active', models.BooleanField(default=True, verbose_name='有効')),
                ('created_at', models.DateTimeField(auto_now_add=True, verbose_name='作成日時')),
            ],
        ),
        migrations.CreateModel(
            name='ChallengeParticipation',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('contribution_count', models.IntegerField(default=0, verbose_name='貢献回数')),
                ('last_contribution_date', models.DateField(blank=True, help_text='1 ユーザー 1 日 1 回ガード用 (この日付と同じ日は加算しない)', null=True, verbose_name='最終貢献日')),
                ('reward_granted', models.BooleanField(default=False, verbose_name='報酬配布済')),
                ('reward_granted_at', models.DateTimeField(blank=True, null=True, verbose_name='報酬配布日時')),
                ('created_at', models.DateTimeField(auto_now_add=True, verbose_name='初回貢献日時')),
            ],
        ),
        migrations.AddIndex(
            model_name='challenge',
            index=models.Index(fields=['is_active', 'start_date', 'end_date'], name='idx_challenge_active_period'),
        ),
        migrations.AddIndex(
            model_name='challenge',
            index=models.Index(fields=['category', 'start_date', 'end_date'], name='idx_challenge_category_period'),
        ),
        migrations.AddField(
            model_name='challengeparticipation',
            name='challenge',
            field=models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='participations', to='api.challenge', verbose_name='チャレンジ'),
        ),
        migrations.AddField(
            model_name='challengeparticipation',
            name='player',
            field=models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='challenge_participations', to='api.playerprofile', verbose_name='プレイヤー'),
        ),
        migrations.AddIndex(
            model_name='challengeparticipation',
            index=models.Index(fields=['player', 'reward_granted', 'challenge'], name='idx_chpart_pending_reward'),
        ),
        migrations.AddConstraint(
            model_name='challengeparticipation',
            constraint=models.UniqueConstraint(fields=('player', 'challenge'), name='unique_player_challenge_participation'),
        ),
    ]
