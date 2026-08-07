"""【FEAT-408 (2026-06-01)】PostHog イベント capture の契約テスト 5 シナリオ。

テスト方針:
  - `requests.post` を `unittest.mock.patch` で mock し、実際の HTTP 送信は行わない
  - `POSTHOG_API_KEY` 環境変数の有無で no-op / capture を切り替える動作を確認
  - 各イベントの発火タイミング・プロパティ内容を縛る

カバー範囲:
  シナリオ A: POSTHOG_API_KEY 未設定 → no-op (HTTP 送信なし)
  シナリオ B: daily_exp_throttle_reached — 閾値到達初回に capture
  シナリオ C: daily_exp_throttle_reached — 閾値超過 2 回目は capture しない (throttled_now=False)
  シナリオ D: daily_battle_limit_reached — BattleStartView 403 時に capture
  シナリオ E: diamond_earned — award_diamond_for_battle_win が True を返した時に capture
"""
import datetime
import os
from unittest.mock import MagicMock, patch

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.constants import DAILY_BATTLE_LIMIT, DAILY_EXP_THROTTLE_LIMIT
from api.models import Enemy, Habit, PlayerProfile
from api.services.diamond_service import award_diamond_for_battle_win
from api.services.posthog_capture import capture, capture_for_player
from ._error_assert import error_code, error_message  # 【FEAT-515】

User = get_user_model()

_TEST_RF_OVERRIDE = {
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


# ─────────────────────────────────────────────────────────────────────────────
# シナリオ A: POSTHOG_API_KEY 未設定 → no-op (HTTP 送信なし)
# ─────────────────────────────────────────────────────────────────────────────

class PostHogCaptureNoopTest(TestCase):
    """capture() の no-op 保証テスト。"""

    @patch('api.services.posthog_capture.requests.post')
    def test_A_no_api_key_is_noop(self, mock_post):
        """POSTHOG_API_KEY 未設定 → requests.post が呼ばれない。"""
        # 環境変数を確実に空にする
        with patch.dict(os.environ, {'POSTHOG_API_KEY': ''}, clear=False):
            capture('test_event', 'player_1', {'key': 'value'})

        mock_post.assert_not_called()

    @patch('api.services.posthog_capture.requests.post')
    def test_A2_api_key_set_sends_request(self, mock_post):
        """POSTHOG_API_KEY 設定済み → requests.post が呼ばれる。"""
        mock_post.return_value = MagicMock(status_code=200)
        with patch.dict(os.environ, {'POSTHOG_API_KEY': 'phc_test_key'}, clear=False):
            capture('test_event', 'player_42', {'foo': 'bar'})

        mock_post.assert_called_once()
        call_kwargs = mock_post.call_args
        json_body = call_kwargs.kwargs.get('json', call_kwargs.args[0] if call_kwargs.args else {})
        # json が positional 引数の場合も考慮
        if isinstance(json_body, str):
            json_body = {}
        self.assertEqual(json_body.get('event'), 'test_event')
        self.assertEqual(json_body.get('distinct_id'), 'player_42')


# ─────────────────────────────────────────────────────────────────────────────
# シナリオ B/C: daily_exp_throttle_reached
# ─────────────────────────────────────────────────────────────────────────────

@override_settings(REST_FRAMEWORK=_TEST_RF_OVERRIDE)
class DailyExpThrottlePostHogTest(APITestCase):
    """EXP スロットル発動時の PostHog capture 契約テスト。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('throttle_ph_user', email='tph@t.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='ThrottleTest',
            # 閾値 DAILY_EXP_THROTTLE_LIMIT (25) ちょうどに設定 → 次の count で発火
            daily_exp_count=DAILY_EXP_THROTTLE_LIMIT,
            daily_exp_count_date=timezone.localdate(),
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        self.habit = Habit.objects.create(
            player=self.player, name='スロットルテスト習慣',
            category='運動', difficulty='easy', frequency='daily', habit_type='count',
        )

    @patch('api.services.posthog_capture.requests.post')
    def test_B_throttle_reached_first_time_captures(self, mock_post):
        """daily_exp_count=25 → 習慣 +1 で throttled_now=True → capture 呼び出し。

        POSTHOG_API_KEY が設定されていない場合は no-op のため、API キーをモック設定。
        """
        with patch.dict(os.environ, {'POSTHOG_API_KEY': 'phc_test_key'}, clear=False):
            res = self.client.post(
                reverse('habit-count', args=[self.habit.pk]),
                data={'action': 'plus'}, format='json',
            )
        self.assertEqual(res.status_code, 200, res.content)
        # throttle_reached 時に capture が呼ばれたことを確認
        # (diamond_service の capture も呼ばれる可能性があるため、最低 1 回は呼ばれる)
        self.assertTrue(mock_post.called, 'throttled_now=True → capture が呼ばれるべき')

        # 少なくとも 1 つの呼び出しが daily_exp_throttle_reached イベントであることを確認
        throttle_calls = [
            call for call in mock_post.call_args_list
            if call.kwargs.get('json', {}).get('event') == 'daily_exp_throttle_reached'
            or (call.args and isinstance(call.args[0], str) and 'throttle' in str(call.args))
        ]
        # 引数チェック (json kwarg の場合)
        any_throttle = any(
            'daily_exp_throttle_reached' in str(c)
            for c in mock_post.call_args_list
        )
        self.assertTrue(any_throttle, '`daily_exp_throttle_reached` イベントが capture されるべき')

    @patch('api.services.posthog_capture.requests.post')
    def test_C_throttle_already_active_does_not_capture(self, mock_post):
        """daily_exp_count=26 (既にスロットル超過) → throttled_now=False → throttle_reached は capture しない。"""
        # 26 件目以降は throttled_now=False
        self.player.daily_exp_count = DAILY_EXP_THROTTLE_LIMIT + 1
        self.player.save()

        with patch.dict(os.environ, {'POSTHOG_API_KEY': 'phc_test_key'}, clear=False):
            self.client.post(
                reverse('habit-count', args=[self.habit.pk]),
                data={'action': 'plus'}, format='json',
            )

        # daily_exp_throttle_reached が capture されていないことを確認
        any_throttle = any(
            'daily_exp_throttle_reached' in str(c)
            for c in mock_post.call_args_list
        )
        self.assertFalse(any_throttle,
                         '26 件目以降は throttled_now=False → throttle_reached capture なし')


# ─────────────────────────────────────────────────────────────────────────────
# シナリオ D: daily_battle_limit_reached
# ─────────────────────────────────────────────────────────────────────────────

@override_settings(REST_FRAMEWORK=_TEST_RF_OVERRIDE)
class DailyBattleLimitPostHogTest(APITestCase):
    """バトル日次上限到達時の PostHog capture 契約テスト。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('battle_ph_user', email='bph@t.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='BattleLimitTest',
            battle_charges=3,           # 出陣可能チャージあり
            daily_battle_count=DAILY_BATTLE_LIMIT,   # 既に上限
            daily_battle_count_date=timezone.localdate(),
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        Enemy.objects.update_or_create(
            key='goblin',
            defaults={
                'name': 'ゴブリン', 'sprite_key': 'enemy_goblin',
                'base_hp': 60, 'base_atk': 8, 'base_spd': 10,
                'level_scaling': 1.0, 'reward_coins': 10, 'reward_exp': 20,
                'tier': 'zako',
            },
        )

    @patch('api.services.posthog_capture.requests.post')
    def test_D_battle_limit_reached_captures(self, mock_post):
        """daily_battle_count=10 → 出陣試行 → 403 + daily_battle_limit_reached capture。"""
        with patch.dict(os.environ, {'POSTHOG_API_KEY': 'phc_test_key'}, clear=False):
            res = self.client.post(reverse('battle-start'))

        self.assertEqual(res.status_code, 403, res.content)
        self.assertEqual(error_code(res), 'daily_battle_limit_reached')

        # daily_battle_limit_reached が capture されることを確認
        any_limit = any(
            'daily_battle_limit_reached' in str(c)
            for c in mock_post.call_args_list
        )
        self.assertTrue(any_limit, '`daily_battle_limit_reached` イベントが capture されるべき')


# ─────────────────────────────────────────────────────────────────────────────
# シナリオ E: diamond_earned (award_diamond_for_battle_win)
# ─────────────────────────────────────────────────────────────────────────────

class DiamondEarnedPostHogTest(TestCase):
    """diamond_earned イベント capture の契約テスト。"""

    def setUp(self):
        self.user = User.objects.create_user('diamond_ph_user', email='dph@t.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='DiamondTest', diamonds=0,
        )

    @patch('api.services.posthog_capture.requests.post')
    def test_E_diamond_earned_captures_on_battle_win(self, mock_post):
        """award_diamond_for_battle_win が True を返す → diamond_earned イベントが capture される。"""
        today = timezone.localdate()
        with patch.dict(os.environ, {'POSTHOG_API_KEY': 'phc_test_key'}, clear=False):
            result = award_diamond_for_battle_win(self.player, today)

        self.assertTrue(result, '初回バトル勝利でダイヤ付与されるべき')

        # diamond_earned が capture されることを確認
        any_earned = any(
            'diamond_earned' in str(c)
            for c in mock_post.call_args_list
        )
        self.assertTrue(any_earned, '`diamond_earned` イベントが capture されるべき')

        # プロパティを確認
        for call in mock_post.call_args_list:
            json_body = call.kwargs.get('json', {})
            if json_body.get('event') == 'diamond_earned':
                props = json_body.get('properties', {})
                self.assertEqual(props.get('source'), 'battle_first_win')
                self.assertGreater(props.get('amount', 0), 0)
                break

    @patch('api.services.posthog_capture.requests.post')
    def test_E2_no_capture_on_skip(self, mock_post):
        """award_diamond_for_battle_win が False を返す (既付与) → capture なし。"""
        today = timezone.localdate()
        # 当日付与済みとして設定
        self.player.last_battle_diamond_at = today
        self.player.save()

        with patch.dict(os.environ, {'POSTHOG_API_KEY': 'phc_test_key'}, clear=False):
            result = award_diamond_for_battle_win(self.player, today)

        self.assertFalse(result, '既付与 → False を返すべき')
        # 既付与の場合は capture が呼ばれない
        any_earned = any(
            'diamond_earned' in str(c)
            for c in mock_post.call_args_list
        )
        self.assertFalse(any_earned, '既付与 → `diamond_earned` capture は不要')
