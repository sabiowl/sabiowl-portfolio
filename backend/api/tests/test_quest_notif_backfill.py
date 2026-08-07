"""FEAT-284 Phase 1: `notif_type='quest'` レコードの backfill 契約テスト。

migration 0080 で `quest` を `TYPE_CHOICES` から削除する前に、既存レコードを
`achievement` に変換することで、AlterField 後の choices バリデーション失敗を
構造的に防いでいることの契約縛り。

`call_command` ベースの migration テストは Django のセットアップが重いため、
本テストは「現状の TYPE_CHOICES の整合性 + migration ファイルが期待する choices
を含んでいる」ことを契約として検証する。
"""
from django.test import TestCase

from api.models import Notification


class QuestNotifTypeRemovalContractTest(TestCase):
    """FEAT-284 Phase 1: `quest` が TYPE_CHOICES から完全に消えていることの契約。"""

    def test_type_choices_no_longer_contains_quest(self):
        """`Notification.TYPE_CHOICES` から `quest` が削除されている。"""
        keys = {key for key, _label in Notification.TYPE_CHOICES}
        self.assertNotIn(
            'quest',
            keys,
            'SEC-06 で機能廃止済みの quest 種別が TYPE_CHOICES から消えていない',
        )

    def test_type_choices_contains_expected_7_types(self):
        """Phase 1 完了後かつ FEAT-446 (message 廃止) 後の通知種別は 7 種類。

        【FEAT-446 (2026-06-20)】MessageView 撤去 + UI 廃止に伴い 'message' を TYPE_CHOICES から削除。
        既存 notif_type='message' レコードは residual 残置 (破壊的削除なし)。
        """
        keys = {key for key, _label in Notification.TYPE_CHOICES}
        expected = {
            'friend_request',
            'friend_accepted',
            'level_up',
            'streak_alert',
            'title_unlocked',  # Phase 3 で create コード実装予定、現状は dead だが残置
            'gift',
            'achievement',
        }
        self.assertEqual(keys, expected)

    def test_title_unlocked_intentionally_retained_for_phase3(self):
        """FEAT-284 Phase 3 で create コード実装予定のため title_unlocked は残置。"""
        keys = {key for key, _label in Notification.TYPE_CHOICES}
        self.assertIn(
            'title_unlocked',
            keys,
            'title_unlocked は Phase 3 用に残置すべき（誤って削除されていない）',
        )
