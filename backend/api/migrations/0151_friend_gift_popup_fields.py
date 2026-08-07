"""【FEAT-452 (2026-06-20)】フレンドプレゼント popup 機構の PlayerProfile field 追加。

当日 3 回目のタスク達成で popup を表示し、直近 1 週間以内ログインのフレンドから
ランダム 1 人を選んで XP ブースト贈与を促す機構。1 回目だとユーザーが煩わしく
感じる + サビ哲学「静かな聖域」整合のため 3 回目に発火。

【追加 field (3 件、AddField のみ)】
- daily_task_count (IntegerField, default=0):
    当日タスク完了数 (3 回目検出用)
- daily_task_count_date (DateField, nullable):
    上記カウンタの基準日 (日跨ぎで自動 0 リセット)
- last_friend_gift_popup_date (DateField, nullable):
    popup 最終表示日 (== today なら同日重複防止)

【スキーマ影響】
AddField のみ、既存 row には default 値が backfill される (count=0, date=null)。
破壊的データ操作なし、FEAT-250 反省遵守 (RunPython なし)。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0150_notification_choices_drop_message'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='daily_task_count',
            field=models.IntegerField(default=0, verbose_name='当日タスク完了数'),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='daily_task_count_date',
            field=models.DateField(blank=True, null=True, verbose_name='当日タスク完了数 基準日'),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='last_friend_gift_popup_date',
            field=models.DateField(blank=True, null=True, verbose_name='フレンドプレゼント popup 最終表示日'),
        ),
    ]
