"""【FEAT-478 Phase 2d (2026-07-06)】PlayerProfile から Streak 8 + Settings 9 = 17 field を削除。

前提条件は 0170 と同じ (Phase 2b 書換完了 + Phase 2c data 移行完了 + @property 書換済)。
"""
from django.db import migrations


class Migration(migrations.Migration):
    dependencies = [
        ('api', '0171_playerprofile_remove_battle_fields'),
    ]
    operations = [
        # Streak 系 8 field → PlayerStreakState 移行済
        migrations.RemoveField(model_name='playerprofile', name='last_battle_diamond_at'),
        migrations.RemoveField(model_name='playerprofile', name='last_streak_diamond_day'),
        migrations.RemoveField(model_name='playerprofile', name='last_login_diamond_at'),
        migrations.RemoveField(model_name='playerprofile', name='login_streak_days'),
        migrations.RemoveField(model_name='playerprofile', name='daily_task_count'),
        migrations.RemoveField(model_name='playerprofile', name='daily_task_count_date'),
        migrations.RemoveField(model_name='playerprofile', name='last_friend_gift_popup_date'),
        migrations.RemoveField(model_name='playerprofile', name='last_achievement_check_at'),
        # Settings 系 9 field → PlayerSettings 移行済
        migrations.RemoveField(model_name='playerprofile', name='all_private'),
        migrations.RemoveField(model_name='playerprofile', name='week_start_day'),
        migrations.RemoveField(model_name='playerprofile', name='month_reset_day'),
        migrations.RemoveField(model_name='playerprofile', name='fcm_token'),
        migrations.RemoveField(model_name='playerprofile', name='reminder_enabled'),
        migrations.RemoveField(model_name='playerprofile', name='reminder_time'),
        migrations.RemoveField(model_name='playerprofile', name='mode'),
        migrations.RemoveField(model_name='playerprofile', name='gcal_push_enabled'),
        migrations.RemoveField(model_name='playerprofile', name='timeline_uncompleted_reminder_enabled'),
    ]
