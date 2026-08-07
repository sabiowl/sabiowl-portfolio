"""FEAT-259: Google Calendar 双方向同期 e2e 統合テスト。

FEAT-244 / FEAT-253 / FEAT-255 / FEAT-256 / FEAT-257 の連携挙動を契約として
縛る。Backend は Google API を直接叩かない（Flutter が叩いて Backend に投げる
設計、フロントエンド主導型 FEAT-114 哲学）ため、本テストは:

  - `/api/timeline/?pending_google_push=true` — pending 取得
  - `/api/timeline/<pk>/google-link/`         — push 成功時の pending 解除 + last_synced_at 書込
  - `/api/timeline/` POST                      — pending_google_push 初期値の制御
  - `/api/timeline/<pk>/`          DELETE      — 削除追随経路の Sabiowl 側削除

を直接叩いて契約を検証する（Google API のモックは不要）。

【FEAT-426 (2026-06-11)】設計 Y (ハイブリッド) 採用に伴い `/api/calendar/import/`
(`ExternalCalendarImportView`) は 410 Gone へ廃止。Google→Sabiowl の timestamp
比較取り込み (旧 FEAT-255 シナリオ 3 件) は Mobile ローカル DB
(`LocalGoogleEventStore`) に責務移管されたため削除した
(`backend/api/tests/test_google_event_completion.py` が後継契約)。

同パターン: FEAT-240（LevelUpDialog integration）/ FEAT-241（HabitCountView API）/
FEAT-242（OnboardingPage flow）/ FEAT-245（PostHog 削除契約）/ FEAT-250
（cleanup_stale_users command）。
"""
from datetime import date

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import PlayerProfile, SocialAccount, TimelineEvent

User = get_user_model()


_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework.authtoken.authentication.TokenAuthentication',
        'api.authentication.GuestTokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
}


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class GoogleCalendarSyncContractTest(APITestCase):
    """FEAT-244/253/255/256/257 の連携契約 e2e。"""

    def setUp(self):
        cache.clear()
        self.user   = User.objects.create_user('player1', email='p1@example.com')
        # 【FEAT-263】migration 0077 で default が False になったため、本テストでは
        # 「FEAT-254 シート同意済ユーザー」のシナリオを模して gcal_push_enabled=True を
        # 明示指定する。OFF 状態の挙動は別ファイル `test_gcal_push_enabled_default.py`
        # で縛っている。
        self.player = PlayerProfile.objects.create(
            user=self.user,
            name='Player1',
            gcal_push_enabled=True,
        )
        # Google 連携あり（FEAT-256 の pending_google_push=True 経路を発火させる）
        SocialAccount.objects.create(
            user=self.user, provider='google', provider_uid='g_uid_001',
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    # ─────────────────────────────────────────────────────────────
    # シナリオ 1: 新規作成 → push 成功（google-link）→ pending=False
    # ─────────────────────────────────────────────────────────────
    def test_local_create_then_push_success_clears_pending(self):
        """【FEAT-373 hotfix】Sabiowl で予定作成 → google-link の経路確認。

        旧挙動 (FEAT-244): 連携済ユーザーの新規予定は pending=True → google-link で False
        新挙動 (FEAT-373): _initial_pending_google_push が常時 False を返すため
                           新規予定は最初から pending=False。
                           google-link 経路自体は引き続き動作することを確認する。
        """
        # POST /api/timeline/ で新規作成
        res = self.client.post(reverse('timeline-list'), data={
            'title':      '会議A',
            'date':       '2026-06-01',
            'start_time': '10:00:00',
            'end_time':   '11:00:00',
        }, format='json')
        self.assertEqual(res.status_code, 201, res.content)
        event_id = res.data['id']

        event = TimelineEvent.objects.get(pk=event_id)
        # 【FEAT-373】v1.0 で push 廃止のため新規予定は pending=False (旧: True)
        self.assertFalse(event.pending_google_push, 'FEAT-373: 新規予定は常に pending=False')
        self.assertIsNone(event.google_event_id)

        # google-link 経路は引き続き動作する（Google → Sabiowl sync で使われる）
        link_res = self.client.post(
            reverse('timeline-google-link', kwargs={'pk': event_id}),
            data={'google_event_id': 'g_event_001'},
            format='json',
        )
        self.assertEqual(link_res.status_code, 200, link_res.content)

        event.refresh_from_db()
        self.assertEqual(event.google_event_id, 'g_event_001')
        self.assertFalse(event.pending_google_push, 'google-link 後も pending=False を維持')
        self.assertIsNotNone(event.last_synced_at, 'push 時に last_synced_at が書かれる')

    # ─────────────────────────────────────────────────────────────
    # シナリオ 2: push 失敗 → pending=True 維持、起動 retry の対象
    # ─────────────────────────────────────────────────────────────
    def test_push_failure_keeps_pending_in_retry_query(self):
        """google-link を叩かない = push 失敗想定。pending=True で retry 対象に残る。"""
        TimelineEvent.objects.create(
            player=self.player,
            title='失敗予定',
            date=date(2026, 6, 2),
            pending_google_push=True,
        )

        res = self.client.get(reverse('timeline-list'), {'pending_google_push': 'true'})
        self.assertEqual(res.status_code, 200)
        titles = [e['title'] for e in res.data]
        self.assertIn('失敗予定', titles, 'pending=True の予定は ?pending_google_push=true で返る')

    # ─────────────────────────────────────────────────────────────
    # シナリオ 4: 連携解除後の create → pending=False（push 対象外）
    # ─────────────────────────────────────────────────────────────
    def test_create_after_google_unsync_sets_pending_false(self):
        """Google 連携解除後の予定作成は pending_google_push=False"""
        SocialAccount.objects.filter(user=self.user, provider='google').delete()

        res = self.client.post(reverse('timeline-list'), data={
            'title':      '解除後予定',
            'date':       '2026-06-06',
            'start_time': '12:00:00',
            'end_time':   '13:00:00',
        }, format='json')
        self.assertEqual(res.status_code, 201, res.content)

        event = TimelineEvent.objects.get(pk=res.data['id'])
        self.assertFalse(event.pending_google_push)

    # ─────────────────────────────────────────────────────────────
    # シナリオ 5: 削除追随 — Flutter 側で 404/410 検知 → DELETE 経路
    # ─────────────────────────────────────────────────────────────
    def test_delete_timeline_removes_event_for_followup(self):
        """FEAT-253 の削除追随では Flutter が Google 404/410 検知 → /timeline/<id>/ DELETE。
        Backend は DELETE をふつうに処理して 204 を返せばよい。"""
        event = TimelineEvent.objects.create(
            player=self.player,
            title='削除予定',
            date=date(2026, 6, 7),
            source='local',
            google_event_id='g_event_020',
            pending_google_push=False,
        )

        res = self.client.delete(reverse('timeline-detail', kwargs={'pk': event.pk}))
        self.assertIn(res.status_code, (200, 204))
        self.assertFalse(TimelineEvent.objects.filter(pk=event.pk).exists())

    # ─────────────────────────────────────────────────────────────
    # シナリオ 6: FEAT-257 gcal_push_enabled=False で pending_google_push=False
    # ─────────────────────────────────────────────────────────────
    def test_gcal_push_disabled_creates_with_pending_false(self):
        """gcal_push_enabled=False のユーザーは連携あっても pending=False で作成される。"""
        self.player.gcal_push_enabled = False
        self.player.save(update_fields=['gcal_push_enabled'])

        res = self.client.post(reverse('timeline-list'), data={
            'title': 'push OFF 予定',
            'date':  '2026-06-08',
        }, format='json')
        self.assertEqual(res.status_code, 201, res.content)

        event = TimelineEvent.objects.get(pk=res.data['id'])
        self.assertFalse(event.pending_google_push, 'push OFF なら pending=False で作成')

    # ─────────────────────────────────────────────────────────────
    # 追加: has_google_event_id クエリの整合性（FEAT-253 reconcile 用）
    # ─────────────────────────────────────────────────────────────
    def test_has_google_event_id_query_filters_correctly(self):
        """?has_google_event_id=true は google_event_id 持ちのみ返す。"""
        TimelineEvent.objects.create(
            player=self.player, title='push 済', date=date(2026, 6, 9),
            google_event_id='g_event_030', pending_google_push=False,
        )
        TimelineEvent.objects.create(
            player=self.player, title='未 push', date=date(2026, 6, 9),
            pending_google_push=True,
        )

        res = self.client.get(reverse('timeline-list'), {'has_google_event_id': 'true'})
        self.assertEqual(res.status_code, 200)
        titles = [e['title'] for e in res.data]
        self.assertIn('push 済', titles)
        self.assertNotIn('未 push', titles)
