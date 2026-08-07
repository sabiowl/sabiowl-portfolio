"""【FEAT-406 (2026-06-01)】battle_charges 日次リセット追跡フィールド追加。

変更内容:
  PlayerProfile.battle_charges_date — DateField(null=True, blank=True) を新規追加。
  既存 battle_charges のデータは一切変更しない (AddField only = 破壊的操作なし)。

CLAUDE.md「破壊的データマイグレーション禁止」原則:
  本 migration は新フィールド AddField のみ。既存データへの破壊はなし。
  null=True のため全既存 PlayerProfile 行は自動的に battle_charges_date=null で更新される。
  null は「日次リセット未記録 = 次回操作時に 0 リセット」として扱われる (初期体験として正常)。
"""

import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0119_enemy_roster_background_hotfix'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='battle_charges_date',
            field=models.DateField(
                blank=True,
                null=True,
                verbose_name='バトルチャージ最終リセット日',
                help_text='FEAT-406: battle_charges の日次リセット基準日。null or 昨日以前なら次回操作でリセット',
            ),
        ),
    ]
