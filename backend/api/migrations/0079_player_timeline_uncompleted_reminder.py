"""FEAT-273: PlayerProfile に timeline_uncompleted_reminder_enabled フィールドを追加。

タイムライン予定の開始時刻 +15 分後に未完了なら通知するリマインダー機能の
ユーザー設定フラグ。

設計判断:
- default=False (FEAT-263 と同じ「明示同意なしには通知しない」哲学)
- マイページの ReminderSettingsPage SwitchListTile で個別 ON
- Flutter local notifications で実装 (Backend cron 不要)
- 既存「開始時刻通知」(FEAT-226) とは並存 (1 予定で 2 通知)
"""

from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ('api', '0078_fix_imported_google_events'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='timeline_uncompleted_reminder_enabled',
            field=models.BooleanField(
                default=False,
                help_text='FEAT-273: タイムライン予定の開始時刻 +15 分後に未完了'
                          'なら通知でリマインドする。デフォルト False（FEAT-263 '
                          'と同じ明示同意哲学）、マイページのトグルで個別 ON。'
                          '実装は Flutter local notifications で完結し Backend '
                          'スケジューラーは不要。',
            ),
        ),
    ]
