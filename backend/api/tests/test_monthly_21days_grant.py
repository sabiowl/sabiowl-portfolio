"""【FEAT-433 (2026-06-13)】当月 21 日達成で SSR 確定チケット即時配布の契約テスト。

旧 (FEAT-312 以前) の「前月 20 日達成 → 今月初に付与」方式を廃止し、
`habit_count_service.grant_monthly_ticket_if_21_days_done` による
「当月 21 日目の達成で即時付与」方式へ移行したことを縛る。

検証シナリオ:
    S1: 当月 21 日目の達成で SSR 確定チケット +1 が即時付与される
    S2: 同月内で 2 回目以降の達成では再配布されない (冪等性)
    S3: 当月 20 日では配布されない
    S4: MONTHLY_TICKET_MAX 到達後も配布フラグは True だがチケット数は上限でキャップされる
    S5: HabitCountView / ChecklistItemToggleView の plus 経路レスポンスに
        `monthly_ticket_awarded` フィールドが含まれる (BUG-96 parity)
"""
from datetime import date, timedelta

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase, override_settings
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.constants import GachaBalance
from api.models import ChecklistItem, Habit, HabitLog, PlayerGachaStatus, PlayerProfile
from api.services.exp_service import create_default_stats
from api.services.habit_count_service import grant_monthly_ticket_if_21_days_done

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


class GrantMonthlyTicketHelperTest(TestCase):
    """`grant_monthly_ticket_if_21_days_done` の単体契約テスト (S1-S4)。"""

    def setUp(self):
        self.user = User.objects.create_user(username='t', password='p')
        self.player = PlayerProfile.objects.create(user=self.user, name='T')
        self.habit = Habit.objects.create(
            player=self.player,
            name='習慣',
            category='その他',
            difficulty='normal',
            habit_type='count',
            frequency='daily',
            reset_cycle='daily',
        )

    def _create_logs(self, first_of_month: date, num_days: int):
        for d in range(num_days):
            HabitLog.objects.create(
                habit=self.habit,
                date=first_of_month + timedelta(days=d),
                count=1,
            )

    # S1: 当月 21 日目の達成で SSR 確定チケット +1 が即時付与される
    def test_S1_21_days_grants_ticket(self):
        first_of_month = date(2026, 6, 1)
        today = date(2026, 6, 21)
        self._create_logs(first_of_month, 21)

        awarded = grant_monthly_ticket_if_21_days_done(self.player, today)

        self.assertTrue(awarded)
        gacha_status = PlayerGachaStatus.objects.get(player=self.player)
        self.assertEqual(gacha_status.monthly_tickets, 1)
        self.assertEqual(gacha_status.monthly_last_granted_month, first_of_month)

    # S2: 同月内で 2 回目以降の達成では再配布されない (冪等性)
    def test_S2_no_double_grant_in_same_month(self):
        first_of_month = date(2026, 6, 1)
        self._create_logs(first_of_month, 22)

        first = grant_monthly_ticket_if_21_days_done(self.player, date(2026, 6, 21))
        second = grant_monthly_ticket_if_21_days_done(self.player, date(2026, 6, 22))

        self.assertTrue(first)
        self.assertFalse(second)
        gacha_status = PlayerGachaStatus.objects.get(player=self.player)
        self.assertEqual(gacha_status.monthly_tickets, 1)

    # S3: 当月 20 日では配布されない
    def test_S3_20_days_does_not_grant(self):
        first_of_month = date(2026, 6, 1)
        today = date(2026, 6, 20)
        self._create_logs(first_of_month, 20)

        awarded = grant_monthly_ticket_if_21_days_done(self.player, today)

        self.assertFalse(awarded)
        gacha_status = PlayerGachaStatus.objects.get(player=self.player)
        self.assertEqual(gacha_status.monthly_tickets, 0)
        self.assertIsNone(gacha_status.monthly_last_granted_month)

    # S4: MONTHLY_TICKET_MAX 到達後も配布フラグは True だがチケット数は上限でキャップされる
    def test_S4_caps_at_monthly_ticket_max(self):
        first_of_month = date(2026, 6, 1)
        today = date(2026, 6, 21)
        self._create_logs(first_of_month, 21)

        gacha_status, _ = PlayerGachaStatus.objects.get_or_create(player=self.player)
        gacha_status.monthly_tickets = GachaBalance.MONTHLY_TICKET_MAX
        gacha_status.save()

        awarded = grant_monthly_ticket_if_21_days_done(self.player, today)

        self.assertTrue(awarded)
        gacha_status.refresh_from_db()
        self.assertEqual(gacha_status.monthly_tickets, GachaBalance.MONTHLY_TICKET_MAX)
        self.assertEqual(gacha_status.monthly_last_granted_month, first_of_month)


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class MonthlyTicketResponseContractTest(APITestCase):
    """HabitCountView / ChecklistItemToggleView の plus 経路レスポンス契約 (S5)。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(username='tester', password='password')
        self.player = PlayerProfile.objects.create(
            user=self.user, level=20, max_exp=10000, mode='training',
        )
        create_default_stats(self.player)
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    # S5a: HabitCountView の plus 経路レスポンスに monthly_ticket_awarded が含まれる
    def test_S5a_habit_count_view_includes_monthly_ticket_awarded(self):
        habit = Habit.objects.create(
            player=self.player, name='count habit', category='その他',
            difficulty='normal', habit_type='count',
            frequency='daily', reset_cycle='daily',
        )
        res = self.client.post(f'/api/habits/{habit.pk}/count/', {'action': 'plus'}, format='json')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertIn('monthly_ticket_awarded', res.data)
        # 当月 1 日目の達成のみ → 21 日に未達のため False
        self.assertFalse(res.data['monthly_ticket_awarded'])

    # S5b: ChecklistItemToggleView の plus 経路レスポンスに monthly_ticket_awarded が含まれる (BUG-96 parity)
    def test_S5b_checklist_toggle_view_includes_monthly_ticket_awarded(self):
        habit = Habit.objects.create(
            player=self.player, name='checklist habit', category='その他',
            difficulty='normal', habit_type='checklist',
            frequency='daily', reset_cycle='daily',
        )
        item = ChecklistItem.objects.create(habit=habit, text='item1')
        res = self.client.post(f'/api/habits/{habit.pk}/checklist/{item.pk}/toggle/', format='json')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertIn('monthly_ticket_awarded', res.data)
        self.assertFalse(res.data['monthly_ticket_awarded'])


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class GachaStatusMonthlyGrantedFlagTest(APITestCase):
    """【新規 (2026-06-25)】GachaStatusView レスポンスの monthly_ticket_granted_this_month 契約。

    Mobile (ガチャ画面 SSR 確定チケットカード) が「今月配布済 ✓ / あと N 日」表示の
    切替に使う真実値。`monthly_last_granted_month == first_of_this_month` で判定する
    Backend 側ロジックを契約として縛る。

    Pre-mortem:
        - S6 未配布初期状態 → false
        - S7 grant_monthly_ticket_if_21_days_done 通過後 → true
        - S8 別月の last_granted (例: 前月) を擬似的に書き込み → false (当月の判定なので)
    """

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(username='gacha_status_tester', password='password')
        self.player = PlayerProfile.objects.create(
            user=self.user, level=20, max_exp=10000, mode='training',
        )
        create_default_stats(self.player)
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    # S6: 初期状態 (PlayerGachaStatus 未作成 or monthly_last_granted_month=None) → false
    def test_S6_initial_state_returns_false(self):
        res = self.client.get('/api/gacha/status/')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertIn('monthly_ticket_granted_this_month', res.data)
        self.assertFalse(res.data['monthly_ticket_granted_this_month'])

    # S7: grant_monthly_ticket_if_21_days_done 通過後 → true
    def test_S7_after_grant_returns_true(self):
        from datetime import date as date_t
        from django.utils import timezone
        # 当月 21 日達成済を擬似的に作成 (HabitLog 21 件)
        habit = Habit.objects.create(
            player=self.player, name='monthly habit', category='その他',
            difficulty='normal', habit_type='count',
            frequency='daily', reset_cycle='daily',
        )
        today = timezone.localdate()
        first_of_month = today.replace(day=1)
        # 当月の day 1〜21 までに log を作成 (today >= day 21 なら 21 日達成済)
        days_in_month = (today - first_of_month).days + 1
        for d in range(min(21, days_in_month)):
            HabitLog.objects.create(
                habit=habit, date=first_of_month + timedelta(days=d), count=1,
            )

        # 直接 helper を呼んで配布確定 (本テストは GachaStatusView 経由ではなく
        # service 層を経由して flag が立つことを確認する設計)。
        if days_in_month >= 21:
            awarded = grant_monthly_ticket_if_21_days_done(self.player, today)
            self.assertTrue(awarded)

        # 月初〜20 日のテスト実行日にも対応するため、強制的に flag を書き込む。
        gacha_status, _ = PlayerGachaStatus.objects.get_or_create(player=self.player)
        gacha_status.monthly_last_granted_month = first_of_month
        gacha_status.save(update_fields=['monthly_last_granted_month'])

        res = self.client.get('/api/gacha/status/')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertTrue(res.data['monthly_ticket_granted_this_month'])

    # S8: 別月 (前月) を last_granted に書き込み → false (当月判定のため)
    def test_S8_previous_month_returns_false(self):
        from django.utils import timezone
        today = timezone.localdate()
        first_of_this_month = today.replace(day=1)
        # 前月 1 日を擬似的に書き込み
        if first_of_this_month.month == 1:
            prev_first = first_of_this_month.replace(year=first_of_this_month.year - 1, month=12)
        else:
            prev_first = first_of_this_month.replace(month=first_of_this_month.month - 1)

        gacha_status, _ = PlayerGachaStatus.objects.get_or_create(player=self.player)
        gacha_status.monthly_last_granted_month = prev_first
        gacha_status.save(update_fields=['monthly_last_granted_month'])

        res = self.client.get('/api/gacha/status/')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertFalse(res.data['monthly_ticket_granted_this_month'])


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class GachaStatusWeeklyGrantedFlagTest(APITestCase):
    """【新規 (2026-06-25)】GachaStatusView レスポンスの weekly_ticket_granted_this_week
    契約。Mobile (ガチャ画面 ウィークリーチケットカード) が「✓ 取得済み」表示と
    「N/5 進捗」表示の切替に使う真実値を縛る。

    判定式: status_obj.weekly_last_granted_week == this_monday (= 当週月曜)。
    weekly_last_granted_week は GachaStatusView 内 transaction.atomic ブロックで
    「前週 5 日達成」条件 + 「当週月曜以降の初回 GET」で書き込まれる。

    検証シナリオ:
        S9: 初期状態 (weekly_last_granted_week=None) → false
        S10: weekly_last_granted_week=this_monday を擬似書き込み → true
        S11: weekly_last_granted_week=前週月曜 → false (当週分は未配布)
    """

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(username='weekly_status_tester', password='password')
        self.player = PlayerProfile.objects.create(
            user=self.user, level=20, max_exp=10000, mode='training',
        )
        create_default_stats(self.player)
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    # S9: 初期状態 → false
    def test_S9_initial_state_returns_false(self):
        res = self.client.get('/api/gacha/status/')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertIn('weekly_ticket_granted_this_week', res.data)
        self.assertFalse(res.data['weekly_ticket_granted_this_week'])

    # S10: weekly_last_granted_week = this_monday → true
    def test_S10_after_grant_returns_true(self):
        from django.utils import timezone
        today = timezone.localdate()
        this_monday = today - timedelta(days=today.weekday())

        gacha_status, _ = PlayerGachaStatus.objects.get_or_create(player=self.player)
        gacha_status.weekly_last_granted_week = this_monday
        gacha_status.save(update_fields=['weekly_last_granted_week'])

        res = self.client.get('/api/gacha/status/')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertTrue(res.data['weekly_ticket_granted_this_week'])

    # S11: weekly_last_granted_week = 前週月曜 → false
    def test_S11_previous_week_returns_false(self):
        from django.utils import timezone
        today = timezone.localdate()
        this_monday = today - timedelta(days=today.weekday())
        prev_monday = this_monday - timedelta(days=7)

        gacha_status, _ = PlayerGachaStatus.objects.get_or_create(player=self.player)
        gacha_status.weekly_last_granted_week = prev_monday
        gacha_status.save(update_fields=['weekly_last_granted_week'])

        # 注: GachaStatusView は atomic ブロック内で「前週 5 日達成 + 未配布」
        # 条件があれば weekly_last_granted_week を this_monday に更新するため、
        # HabitLog ゼロの本テストでは grant は走らず prev_monday のまま維持される。
        res = self.client.get('/api/gacha/status/')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertFalse(res.data['weekly_ticket_granted_this_week'])
