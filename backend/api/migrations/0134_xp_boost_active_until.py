"""【FEAT-318 (2026-06-13 再活性化)】XP ブースト有効期限フィールド追加。

変更内容:
  PlayerProfile.xp_boost_active_until — DateTimeField(null=True, blank=True) を新規追加。
  既存データへの変更なし (AddField only = 破壊的操作なし)。
  全既存 PlayerProfile 行は xp_boost_active_until=NULL (= ブースト無効) で更新される。

CLAUDE.md「破壊的データマイグレーション禁止」原則:
  本 migration は新フィールド AddField のみ。既存データへの破壊はなし。
"""

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0133_weekly_character_restored'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='xp_boost_active_until',
            field=models.DateTimeField(
                null=True, blank=True,
                verbose_name='XPブースト有効期限',
            ),
        ),
    ]
