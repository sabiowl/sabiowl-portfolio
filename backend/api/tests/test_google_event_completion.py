"""【FEAT-426 (2026-06-11)】Google カレンダー予定の完了状態 (GoogleEventCompletion) 契約テスト。

設計 Y (ハイブリッド): Backend は Google 予定本文を保持せず、
`event_id + 完了フラグ + on_time_bonus_awarded` のみを保持する。
本テストは `GoogleEventCompletionView` / `GoogleEventCompletionListView` の
8 シナリオを縛る (FEAT-419 流用のオンタイムボーナス含む)。
"""
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.db import IntegrityError, transaction
from django.test import override_settings
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import GoogleEventCompletion, PlayerProfile

User = get_user_model()


_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'api.authentication.ExpiringTokenAuthentication',
        'api.authentication.GuestTokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
}


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class GoogleEventCompletionTest(APITestCase):
    """GoogleEventCompletion view の 8 シナリオ契約テスト。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='tester', password='password')
        self.player = PlayerProfile.objects.create(user=self.user)
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        self.now    = timezone.localtime()

    def _complete_url(self, google_event_id: str) -> str:
        return f'/api/google-events/{google_event_id}/complete/'

    def _list_url(self) -> str:
        return '/api/google-events/completions/'

    # 1. 未完了状態で POST .../complete/ → is_completed=True, completed_at 設定
    def test_post_complete_marks_completed(self):
        response = self.client.post(self._complete_url('evt-1'), {
            'event_date': self.now.date().isoformat(),
        })

        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data['completion']['is_completed'])
        self.assertIsNotNone(response.data['completion']['completed_at'])

        completion = GoogleEventCompletion.objects.get(player=self.player, google_event_id='evt-1')
        self.assertTrue(completion.is_completed)
        self.assertIsNotNone(completion.completed_at)

    # 2. 既完了状態で再 POST .../complete/ → 200 冪等
    def test_post_complete_idempotent_when_already_completed(self):
        self.client.post(self._complete_url('evt-2'), {
            'event_date': self.now.date().isoformat(),
        })
        completion = GoogleEventCompletion.objects.get(player=self.player, google_event_id='evt-2')
        first_completed_at = completion.completed_at

        response = self.client.post(self._complete_url('evt-2'), {
            'event_date': self.now.date().isoformat(),
        })

        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data['completion']['is_completed'])
        self.assertEqual(response.data['on_time_bonus_coin'], 0)

        completion.refresh_from_db()
        self.assertEqual(completion.completed_at, first_completed_at)
        self.assertEqual(
            GoogleEventCompletion.objects.filter(
                player=self.player, google_event_id='evt-2',
            ).count(),
            1,
        )

    # 3. DELETE .../complete/ → is_completed=False, コイン -5
    def test_delete_complete_unmarks_and_reverts_bonus(self):
        # オンタイムボーナス込みで完了させる
        self.client.post(self._complete_url('evt-3'), {
            'event_date': self.now.date().isoformat(),
            'start_time': self.now.strftime('%H:%M'),
        })
        self.player.refresh_from_db()
        coins_after_complete = self.player.economy.bonus_coins
        self.assertEqual(coins_after_complete, 5)

        response = self.client.delete(self._complete_url('evt-3'))

        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.data['completion']['is_completed'])

        completion = GoogleEventCompletion.objects.get(player=self.player, google_event_id='evt-3')
        self.assertFalse(completion.is_completed)
        self.assertFalse(completion.on_time_bonus_awarded)
        self.assertIsNone(completion.completed_at)

        self.player.refresh_from_db()
        self.assertEqual(self.player.economy.bonus_coins, coins_after_complete - 5)

    # 4. FEAT-419 ボーナス: start_time = now ± 15 分以内 → コイン +5, on_time_bonus_awarded=True
    def test_on_time_completion_awards_bonus(self):
        initial_coins = self.player.economy.bonus_coins

        response = self.client.post(self._complete_url('evt-4'), {
            'event_date':  self.now.date().isoformat(),
            'start_time':  self.now.strftime('%H:%M'),
        })

        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data['on_time_bonus_awarded'])
        self.assertEqual(response.data['on_time_bonus_coin'], 5)

        self.player.refresh_from_db()
        self.assertEqual(self.player.economy.bonus_coins, initial_coins + 5)

        completion = GoogleEventCompletion.objects.get(player=self.player, google_event_id='evt-4')
        self.assertTrue(completion.on_time_bonus_awarded)

    # 5. FEAT-419 ボーナス: ±20 分超 → コインなし
    def test_completion_after_20_minutes_no_bonus(self):
        initial_coins = self.player.economy.bonus_coins
        scheduled = (self.now - timedelta(minutes=20)).strftime('%H:%M')

        response = self.client.post(self._complete_url('evt-5'), {
            'event_date': self.now.date().isoformat(),
            'start_time': scheduled,
        })

        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.data['on_time_bonus_awarded'])
        self.assertEqual(response.data['on_time_bonus_coin'], 0)

        self.player.refresh_from_db()
        self.assertEqual(self.player.economy.bonus_coins, initial_coins)

    # 6. FEAT-419 ボーナス: 過去 24h 超の start_time → 改ざん検証で reject
    def test_stale_start_time_beyond_24h_no_bonus(self):
        initial_coins = self.player.economy.bonus_coins
        # event_date は今日のままだが、start_time は到底あり得ない値を送る想定。
        # 24h 判定は「scheduled (event_date + start_time) と現在時刻の差」で行われるため、
        # event_date を 2 日前に設定して 24h を超えさせる。
        stale_date = (self.now - timedelta(days=2)).date()

        response = self.client.post(self._complete_url('evt-6'), {
            'event_date': stale_date.isoformat(),
            'start_time': self.now.strftime('%H:%M'),
        })

        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.data['on_time_bonus_awarded'])
        self.assertEqual(response.data['on_time_bonus_coin'], 0)

        self.player.refresh_from_db()
        self.assertEqual(self.player.economy.bonus_coins, initial_coins)

    # 7. GET .../completions/?date_from=...&date_to=... → 範囲内の completion のみ返す
    def test_list_filters_by_date_range(self):
        today = self.now.date()
        GoogleEventCompletion.objects.create(
            player=self.player, google_event_id='evt-in-range', event_date=today,
        )
        GoogleEventCompletion.objects.create(
            player=self.player, google_event_id='evt-out-of-range',
            event_date=today - timedelta(days=10),
        )

        response = self.client.get(self._list_url(), {
            'date_from': (today - timedelta(days=1)).isoformat(),
            'date_to':   (today + timedelta(days=1)).isoformat(),
        })

        self.assertEqual(response.status_code, 200)
        ids = [c['google_event_id'] for c in response.data['completions']]
        self.assertIn('evt-in-range', ids)
        self.assertNotIn('evt-out-of-range', ids)

    # 8. unique_together: 同一 player + 同一 google_event_id で重複作成 → IntegrityError
    def test_unique_together_player_and_google_event_id(self):
        GoogleEventCompletion.objects.create(
            player=self.player, google_event_id='evt-dup', event_date=self.now.date(),
        )

        with self.assertRaises(IntegrityError):
            with transaction.atomic():
                GoogleEventCompletion.objects.create(
                    player=self.player, google_event_id='evt-dup', event_date=self.now.date(),
                )
