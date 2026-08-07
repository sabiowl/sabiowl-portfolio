"""FEAT-284 Phase 1: `Notification.notif_type` の choices から `quest` を削除する。

経緯:
- `quest` 通知種別は SEC-06 で機能廃止済みの残骸（`Quest` モデル自体は
  migration 0067 で物理削除済み）
- 残置していた `('quest', 'クエスト')` choices エントリは死コード
- 万一既存 DB に `notif_type='quest'` レコードが残っていた場合に AlterField で
  バリデーション失敗（DataError）を起こさないよう、先に **RunPython で
  `achievement` に backfill** してから AlterField を実行する 2 段階構成

Pre-mortem #3（カテゴリ 4: エッジケース）対応:
- 旧 quest レコードを `achievement` に変換することで「実績相当の達成系通知」
  として通知一覧に残せる（履歴の継続性確保）
- `title` / `body` は維持し、`notif_type` のみ変換するため UX への影響は最小

`title_unlocked` 通知種別は Phase 3 で実装予定のため、本 migration では touch しない。
"""
from django.db import migrations, models


def _backfill_quest_to_achievement(apps, schema_editor):
    """既存の `notif_type='quest'` レコードを `achievement` に変換する。

    quest 機能は SEC-06 で廃止済みのため、現存するレコードは「過去にユーザーが
    クエスト達成通知を受け取って削除していない履歴」のみ。実績解除通知の
    カテゴリと意味が近いため `achievement` に統合する。

    対象 0 件でも no-op で安全。リリース前段階のため大規模 backfill は想定なし。
    """
    Notification = apps.get_model('api', 'Notification')
    qs = Notification.objects.filter(notif_type='quest')
    count = qs.count()
    if count == 0:
        print('[migration 0080] No quest notifications to backfill. Skipping.')
        return
    qs.update(notif_type='achievement')
    print(f'[migration 0080] Backfilled {count} quest notifications to achievement.')


def _reverse_noop(apps, schema_editor):
    """ロールバック不可（quest → achievement に変換した履歴は復元不能）。

    本 migration を revert する場合は AlterField の choices 復元のみ行われ、
    既に変換済みのレコードは achievement のまま残る。リリース前段階の cleanup
    のため、実用上問題なし。
    """
    pass


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0079_player_timeline_uncompleted_reminder'),
    ]

    operations = [
        # 1) 既存 quest レコードを achievement に backfill（AlterField 前に実行）
        migrations.RunPython(_backfill_quest_to_achievement, _reverse_noop),
        # 2) choices から quest を削除
        migrations.AlterField(
            model_name='notification',
            name='notif_type',
            field=models.CharField(
                max_length=20,
                verbose_name='通知種別',
                choices=[
                    ('friend_request',  'フレンド申請'),
                    ('friend_accepted', 'フレンド成立'),
                    ('message',         'メッセージ'),
                    ('level_up',        'レベルアップ'),
                    ('streak_alert',    'ストリーク危機'),
                    ('title_unlocked',  '称号解除'),
                    ('gift',            'ギフト'),
                    ('achievement',     '実績解除'),
                ],
            ),
        ),
    ]
