"""【FEAT-446 (2026-06-20)】Notification.notif_type の choices から 'message' を削除。

メッセージ機能廃止 (MessageView / messages_page / Message API ルート撤去) に伴い、
新規発火経路がゼロになるため choices から 'message' を撤去する。

【データ保全】
既存 `notif_type='message'` レコードは削除しない (FEAT-250 反省: 破壊的データ
削除は migration ではなく management command で実施する原則)。
- 既存レコードは DB に残るが、新規作成経路ゼロ
- Mobile 通知画面で「メッセージ通知」は filter 漏れも tap 経路もなく実質非表示
- choices に無い値でも Django ORM は read 可能 (choices は forms/admin の validate
  にのみ使われる)

【スキーマ影響】
- AlterField で choices メタデータのみ変更 (DB スキーマ変更なし)
- データ整合性影響ゼロ
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0149_iron_weapons_seed'),
    ]

    operations = [
        migrations.AlterField(
            model_name='notification',
            name='notif_type',
            field=models.CharField(
                choices=[
                    ('friend_request',  'フレンド申請'),
                    ('friend_accepted', 'フレンド成立'),
                    ('level_up',        'レベルアップ'),
                    ('streak_alert',    'ストリーク危機'),
                    ('title_unlocked',  '称号解除'),
                    ('gift',            'ギフト'),
                    ('achievement',     '実績解除'),
                ],
                max_length=20,
                verbose_name='通知種別',
            ),
        ),
    ]
