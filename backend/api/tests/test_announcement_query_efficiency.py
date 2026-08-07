"""【FEAT-460 (2026-06-22)】Announcement クエリ効率の契約テスト (P2-A 解消)。

AnnouncementUnreadView / AnnouncementListView が少数 SQL クエリで完結することを
assertNumQueries で縛る。長期運用で既読数が増えても N+1 退行しないことを担保。
"""
from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from api.models import Announcement, PlayerAnnouncementRead, PlayerProfile

User = get_user_model()


class AnnouncementQueryEfficiencyTest(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(username='qtest', password='pw')
        self.player = PlayerProfile.objects.create(user=self.user, name='Q-Test')
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # 50 件の announcement を作成、うち 40 件既読
        for i in range(50):
            ann = Announcement.objects.create(
                title=f'お知らせ {i}',
                body=f'本文 {i}',
                is_active=True,
            )
            if i < 40:
                PlayerAnnouncementRead.objects.create(
                    player=self.player,
                    announcement=ann,
                )

        # 【2026-08-02】MaintenanceMiddleware の MaintenanceConfig SELECT は
        # 60s TTL cache 経由 (FEAT-471)。**先に走ったテストが暖めたかどうか**で
        # クエリ数が 1 増減し、テスト順序に依存して落ちる状態だったので、
        # ここで明示的に暖めて決定的にする。
        from api.services.maintenance_cache import get_maintenance_config
        get_maintenance_config()

    # 【Pre-mortem S2】assertNumQueries(1) は token 認証 (1) + get_player の
    # PlayerProfile 解決 (1) を含まない「業務ロジックのみ」の理想値。実際の
    # リクエストにはこの 2 件が必ず乗るため、認証 1 + player 解決 1 +
    # announcement 本体 1 + locale 解決 1 = 4 に固定して
    # 「本体クエリが 1 のまま」を縛る。
    #
    # 【2026-08-02】+1 は I18nMiddleware の PlayerSettings.preferred_language
    # SELECT。Accept-Language を送らないクライアントでのみ発生する
    # (Mobile は毎リクエスト送るので本番では出ない)。テストクライアントは
    # ヘッダを送らないため常に乗る。
    #
    def test_unread_view_is_single_query(self):
        """【FEAT-460】AnnouncementUnreadView は LEFT JOIN で 1 SQL に集約される。"""
        with self.assertNumQueries(4):
            resp = self.client.get('/api/announcements/unread/')
        self.assertEqual(resp.status_code, 200)

    def test_list_view_includes_is_read_in_single_query(self):
        """【FEAT-460】AnnouncementListView の is_read フラグは Exists 経由で 1 SQL に集約される。"""
        with self.assertNumQueries(4):
            resp = self.client.get('/api/announcements/')
        self.assertEqual(resp.status_code, 200)
        data = resp.json()
        # 50 件のうち 40 件が is_read=True、10 件が False
        read_count = sum(1 for a in data['announcements'] if a['is_read'])
        self.assertEqual(read_count, 40)
        self.assertEqual(len(data['announcements']), 50)
