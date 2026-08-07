"""【FEAT-398 (2026-05-31)】日次スロットル対応の AddField × 6。

スキーマ変更のみ、データ migration 不要:
- PlayerProfile 4 field (daily_exp_count / daily_exp_count_date / daily_battle_count / daily_battle_count_date)
- HabitLog 1 field (battle_charges_awarded) — migration apply 後の既存 HabitLog は全て False (default)
- TimelineEvent 1 field (battle_charges_awarded) — 同上

既存データへの影響 (#11 Pre-mortem):
- 既存 HabitLog / TimelineEvent の battle_charges_awarded は default=False
  → 取り消し操作は「フラグ False のため無処理」= 過去の不整合を持ち込まない
  → migration apply 後の新規達成からフラグ管理開始 (清浄な状態でスタート)
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0115_zenon_description_expansion'),
    ]

    operations = [
        # ── PlayerProfile: 日次 EXP スロットル (経路 1-2) ──────────────────
        migrations.AddField(
            model_name='playerprofile',
            name='daily_exp_count',
            field=models.IntegerField(
                default=0,
                verbose_name='本日の EXP 獲得回数',
                help_text='FEAT-398: 0:00 自動リセット、25 件超過後 EXP/pt 1pt 固定',
            ),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='daily_exp_count_date',
            field=models.DateField(
                null=True, blank=True,
                verbose_name='本日 EXP カウントの起点日',
            ),
        ),
        # ── PlayerProfile: 日次バトル出陣上限 (経路 4) ─────────────────────
        migrations.AddField(
            model_name='playerprofile',
            name='daily_battle_count',
            field=models.IntegerField(
                default=0,
                verbose_name='本日のバトル出陣回数',
                help_text='FEAT-398: 0:00 自動リセット、10 回超過で出陣拒否',
            ),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='daily_battle_count_date',
            field=models.DateField(
                null=True, blank=True,
                verbose_name='本日バトルカウントの起点日',
            ),
        ),
        # ── HabitLog: battle_charges 取り消し対称化 (第 3 段階) ────────────
        migrations.AddField(
            model_name='habitlog',
            name='battle_charges_awarded',
            field=models.BooleanField(
                default=False,
                help_text='FEAT-398: 該当 HabitLog で battle_charges +1 が実加算されたか (取り消し時 -1 判定用)',
            ),
        ),
        # ── TimelineEvent: battle_charges 取り消し対称化 (第 3 段階) ───────
        migrations.AddField(
            model_name='timelineevent',
            name='battle_charges_awarded',
            field=models.BooleanField(
                default=False,
                help_text='FEAT-398: 該当 TimelineEvent 完了で battle_charges +1 が実加算されたか (取り消し時 -1 判定用)',
            ),
        ),
    ]
