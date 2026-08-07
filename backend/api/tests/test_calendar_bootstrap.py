"""【FEAT-290 hotfix】CalendarBootstrapView の契約テスト。

FEAT-290 で `calendar.py` を 3 モジュールに分割した際、`core.py` 側の
`CalendarBootstrapView` が `aggregations.py` の `CalendarView` / `StreakView`
を内部呼び出ししているのに **import 漏れで NameError → 500** を返していた
（カレンダー画面が「うまくいきませんでした」エラーで表示されない真因、
2026-05-26 ユーザー報告で発覚）。

本テストは:
1. 通常パラメータで 200 を返す（NameError リグレッション防止）
2. レスポンスシェイプが `{calendar, streak, daily}` の 3 キー構成
3. 各サブビューが内部で aggregations.py 由来でも正しく動く

を契約として縛り、今後の分割リファクタで sibling module import 漏れを再発させない。
"""
from datetime import date as date_type

from django.contrib.auth import get_user_model
from django.test import override_settings
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import PlayerProfile

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
class CalendarBootstrapViewTestCase(APITestCase):
    """`GET /api/calendar/bootstrap/` の最小契約テスト。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='tester', password='password')
        self.player = PlayerProfile.objects.create(user=self.user)
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    def test_bootstrap_returns_200_with_three_top_level_keys(self):
        """通常呼び出しで 200 を返し、`calendar` / `streak` / `daily` 3 キーが揃う。

        FEAT-290 の sibling module import 漏れ regression を直接縛る。
        分割前は同一ファイル内で参照できていた CalendarView / StreakView の
        instantiation が、分割後 import 漏れで NameError → 500 になっていた。
        """
        res = self.client.get(
            '/api/calendar/bootstrap/?year=2026&month=5&date=2026-05-26'
        )
        self.assertEqual(res.status_code, http_status.HTTP_200_OK,
                         f'bootstrap が 200 を返していません: status={res.status_code} body={res.data}')
        self.assertIn('calendar', res.data)
        self.assertIn('streak',   res.data)
        self.assertIn('daily',    res.data)

    def test_bootstrap_calendar_section_has_required_keys(self):
        """`calendar` セクションが `year` / `month` / `days` / `summary` を含む。

        Flutter `CalendarData.fromJson` が require している 4 キーの契約。
        """
        res = self.client.get(
            '/api/calendar/bootstrap/?year=2026&month=5&date=2026-05-26'
        )
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)
        cal = res.data['calendar']
        self.assertEqual(cal['year'],  2026)
        self.assertEqual(cal['month'], 5)
        self.assertIn('days',    cal)
        self.assertIn('summary', cal)

    def test_bootstrap_streak_section_has_required_keys(self):
        """`streak` セクションが `seven_days` / `habit_streaks` を含む。

        Flutter `StreakData.fromJson` が require している必須キーの契約。
        """
        res = self.client.get(
            '/api/calendar/bootstrap/?year=2026&month=5&date=2026-05-26'
        )
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)
        streak = res.data['streak']
        self.assertIn('seven_days',    streak)
        self.assertIn('habit_streaks', streak)

    def test_bootstrap_daily_section_has_required_keys(self):
        """`daily` セクションが `date` / `habits` / `todos` を含む。

        Flutter `DailyData.fromJson` が require している必須キーの契約。
        """
        res = self.client.get(
            '/api/calendar/bootstrap/?year=2026&month=5&date=2026-05-26'
        )
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)
        daily = res.data['daily']
        self.assertIn('date',   daily)
        self.assertIn('habits', daily)
        self.assertIn('todos',  daily)

    def test_bootstrap_works_with_default_query_params(self):
        """クエリパラメータ未指定でも 200 を返す（デフォルトで今日 / 今月）。"""
        res = self.client.get('/api/calendar/bootstrap/')
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)
        # year / month は date.today() ベース、データ内容は assertIn キー存在のみで縛る
        self.assertIn('calendar', res.data)
        self.assertIn('streak',   res.data)
        self.assertIn('daily',    res.data)

    def test_bootstrap_unauthenticated_returns_401(self):
        """認証なしでは 401 を返す（リグレッション防止）。"""
        self.client.credentials()  # トークン解除
        res = self.client.get('/api/calendar/bootstrap/')
        self.assertEqual(res.status_code, http_status.HTTP_401_UNAUTHORIZED)
