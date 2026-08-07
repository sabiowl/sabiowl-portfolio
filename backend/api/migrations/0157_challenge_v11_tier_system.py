"""【FEAT-466 (2026-06-24)】チャレンジ Ver1.1 schema 置換 (3 段階 Bronze/Silver/Gold)。

FEAT-465 (Ver1.0) の単一目標方式 (`Challenge.target_count` / `reward_exp`、
`ChallengeParticipation.reward_granted` / `reward_granted_at`) を、3 段階累積
開放方式 (`is_tiered` + bronze/silver/gold 別 target/reward + 別配布フラグ)
に置換する。

【安全性】FEAT-465 commit (51e134e/319b2e2/6dbcea5) から本 migration の deploy
までの期間中、admin から Challenge レコードが一切 seed されていないことが前提
(リリース直前 6/30 に Ver1.1 schema で初めて seed する計画のため)。Render
PostgreSQL の Challenge / ChallengeParticipation テーブルは empty の想定であり、
RemoveField で対象列を drop してもデータ消失は発生しない (Pre-mortem S3、
deploy 前に PM が Render Shell から `Challenge.objects.count() == 0` を確認する
運用とする)。

RemoveField + AddField + RemoveIndex/AddIndex のみで RunPython は使用しない
(CLAUDE.md「破壊的データマイグレーション禁止」原則の対象外、空テーブルへの
schema 操作のみ)。

Note: `makemigrations --dry-run` は本変更と無関係な既存ドリフト (IAPReceipt/
PlayerAnnouncementRead の RenameIndex、id フィールドの BigAutoField 化、
PlayerProfile 既存フィールドの help_text/verbose_name 差分) も検出したが、
FEAT-465 の migration 0156 と同じ理由でスコープ外のため本 migration には
含めない。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0156_challenge_system_v1'),
    ]

    operations = [
        migrations.RemoveIndex(
            model_name='challengeparticipation',
            name='idx_chpart_pending_reward',
        ),
        migrations.RemoveField(
            model_name='challenge',
            name='reward_exp',
        ),
        migrations.RemoveField(
            model_name='challenge',
            name='target_count',
        ),
        migrations.RemoveField(
            model_name='challengeparticipation',
            name='reward_granted',
        ),
        migrations.RemoveField(
            model_name='challengeparticipation',
            name='reward_granted_at',
        ),
        migrations.AddField(
            model_name='challenge',
            name='is_tiered',
            field=models.BooleanField(
                default=True,
                verbose_name='累積開放方式',
                help_text='True: Bronze/Silver/Gold の 3 段階目標 (ゴールド達成で全段階'
                           '報酬を獲得)。False: ゴールド目標のみの単一目標 (Ver1.0 相当)。',
            ),
        ),
        migrations.AddField(
            model_name='challenge',
            name='target_count_bronze',
            field=models.IntegerField(
                null=True, blank=True, verbose_name='ブロンズ目標',
                help_text='is_tiered=True のときのみ必須 (bronze < silver < gold)。',
            ),
        ),
        migrations.AddField(
            model_name='challenge',
            name='target_count_silver',
            field=models.IntegerField(
                null=True, blank=True, verbose_name='シルバー目標',
                help_text='is_tiered=True のときのみ必須 (bronze < silver < gold)。',
            ),
        ),
        migrations.AddField(
            model_name='challenge',
            name='target_count_gold',
            field=models.IntegerField(
                verbose_name='ゴールド目標',
                help_text='累積開放方式の最終目標、または単一目標方式の主目標 (必須)。',
                default=0,
            ),
            preserve_default=False,
        ),
        migrations.AddField(
            model_name='challenge',
            name='reward_exp_bronze',
            field=models.IntegerField(null=True, blank=True, default=100, verbose_name='ブロンズ報酬 EXP'),
        ),
        migrations.AddField(
            model_name='challenge',
            name='reward_exp_silver',
            field=models.IntegerField(null=True, blank=True, default=300, verbose_name='シルバー報酬 EXP'),
        ),
        migrations.AddField(
            model_name='challenge',
            name='reward_exp_gold',
            field=models.IntegerField(default=1000, verbose_name='ゴールド報酬 EXP'),
        ),
        migrations.AddField(
            model_name='challengeparticipation',
            name='bronze_granted',
            field=models.BooleanField(default=False, verbose_name='ブロンズ配布済'),
        ),
        migrations.AddField(
            model_name='challengeparticipation',
            name='silver_granted',
            field=models.BooleanField(default=False, verbose_name='シルバー配布済'),
        ),
        migrations.AddField(
            model_name='challengeparticipation',
            name='gold_granted',
            field=models.BooleanField(default=False, verbose_name='ゴールド配布済'),
        ),
        migrations.AddField(
            model_name='challengeparticipation',
            name='bronze_granted_at',
            field=models.DateTimeField(
                null=True, blank=True, verbose_name='ブロンズ配布日時',
                help_text='実際に EXP が配布された tier のみ記録 (未達 tier は null 維持)。',
            ),
        ),
        migrations.AddField(
            model_name='challengeparticipation',
            name='silver_granted_at',
            field=models.DateTimeField(null=True, blank=True, verbose_name='シルバー配布日時'),
        ),
        migrations.AddField(
            model_name='challengeparticipation',
            name='gold_granted_at',
            field=models.DateTimeField(null=True, blank=True, verbose_name='ゴールド配布日時'),
        ),
        migrations.AddIndex(
            model_name='challengeparticipation',
            index=models.Index(fields=['player', 'gold_granted', 'challenge'], name='idx_chpart_gold_pending'),
        ),
    ]
