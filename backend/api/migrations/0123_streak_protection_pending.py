"""【FEAT-420 (2026-06-10)】ストリーク保護「予約 → 翌日判定」モード追加。

変更内容:
  PlayerProfile.streak_protection_pending — BooleanField(default=False) を新規追加。
  既存データへの変更なし (AddField only = 破壊的操作なし)。
  全既存 PlayerProfile 行は自動的に streak_protection_pending=False で更新される
  (= 「予約なし」状態として正常)。

CLAUDE.md「破壊的データマイグレーション禁止」原則:
  本 migration は新フィールド AddField のみ。既存データへの破壊はなし。
"""

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0122_enemy_reward_balance'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='streak_protection_pending',
            field=models.BooleanField(
                default=False,
                verbose_name='ストリーク保護 予約中',
            ),
        ),
    ]
