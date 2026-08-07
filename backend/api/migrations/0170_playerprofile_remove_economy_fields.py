"""【FEAT-478 Phase 2d (2026-07-06)】PlayerProfile から Economy 系 11 field を削除。

前提条件 (必須):
  1. Migration 0169 適用済 (PlayerEconomyState CreateModel 完了)
  2. `python manage.py migrate_player_profile_v2 --confirm` 実行済
     → 全 PlayerProfile に PlayerEconomyState row が存在 (Phase 2c)
     【2026-08-07】本コマンドは削除済 (実行完了 + proxy が自動作成するため)。
  3. models/player.py の @property economy を `get_or_create(player=self)` (defaults なし)
     に書換済 (defaults に旧 field 参照が残っていない状態)
  4. Phase 2b 書換完了 (views/services が player.economy.diamonds 経由アクセス)

このマイグレーションは RemoveField のみで RunPython 不使用のため、
CLAUDE.md「破壊的データマイグレーション禁止」の対象外 (schema 変更のみ)。
"""
from django.db import migrations


class Migration(migrations.Migration):
    dependencies = [
        ('api', '0169_playerprofile_split_state_models'),
    ]
    operations = [
        migrations.RemoveField(model_name='playerprofile', name='diamonds'),
        migrations.RemoveField(model_name='playerprofile', name='diamonds_total'),
        migrations.RemoveField(model_name='playerprofile', name='bonus_coins'),
        migrations.RemoveField(model_name='playerprofile', name='coins_spent'),
        migrations.RemoveField(model_name='playerprofile', name='diamond_bonus_date'),
        migrations.RemoveField(model_name='playerprofile', name='character_exchange_tickets'),
        migrations.RemoveField(model_name='playerprofile', name='streak_protection_count'),
        migrations.RemoveField(model_name='playerprofile', name='streak_protection_auto_enabled'),
        migrations.RemoveField(model_name='playerprofile', name='streak_protection_pending'),
        migrations.RemoveField(model_name='playerprofile', name='last_streak_protection_used_at'),
        migrations.RemoveField(model_name='playerprofile', name='xp_boost_active_until'),
    ]
