"""【ユーザー判断 2026-06-22】先月比較の達成率を top5 平均に変更した契約テスト 4 件。

旧: 全アクティブ習慣の達成率を均等平均 (低達成率の習慣に引っ張られて
    ユーザーのテンションを下げる原因となっていた)。
新: 各月で習慣別達成率の高い順 top 5 (5 件未満は全件) を平均化。
    当月と先月で独立に top5 を選定し、それぞれの平均で比較。
    累計達成回数 (total) は別軸の指標として全習慣合算を維持。

対象 view: api.views.calendar.aggregations.StatsView (`/api/calendar/stats/`)
"""
from calendar import monthrange
from datetime import date, timedelta

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Habit, HabitLog, PlayerProfile

User = get_user_model()


_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
}


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class StatsTop5ComparisonTest(APITestCase):
    """先月比較の達成率を top5 平均に変更した契約テスト 4 シナリオ。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('p1', email='p1@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='P1')
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        self.today = timezone.localdate()
        self.url = reverse('calendar-stats')

    # ── helpers ──────────────────────────────────────────────────────────

    def _make_habit(self, name, completed_dates):
        """指定日付すべてで count=1 の HabitLog を持つ習慣を生成。"""
        habit = Habit.objects.create(
            player=self.player,
            name=name,
            category='その他',
            frequency='daily',
            habit_type='count',
            is_active=True,
        )
        for d in completed_dates:
            HabitLog.objects.create(habit=habit, date=d, count=1)
        return habit

    def _current_month_past_dates(self):
        """当月 1 日 〜 today までの全日付リスト (past_days と一致)。"""
        first = date(self.today.year, self.today.month, 1)
        result = []
        d = first
        while d <= self.today:
            result.append(d)
            d += timedelta(days=1)
        return result

    def _prev_month_past_dates(self):
        """先月 1 日 〜 末日までの全日付リスト (今日が先月内になることはない)。"""
        if self.today.month == 1:
            prev_year, prev_month = self.today.year - 1, 12
        else:
            prev_year, prev_month = self.today.year, self.today.month - 1
        days_in_prev = monthrange(prev_year, prev_month)[1]
        return [date(prev_year, prev_month, d) for d in range(1, days_in_prev + 1)]

    # ── tests ────────────────────────────────────────────────────────────

    def test_under_5_habits_uses_all_as_fallback(self):
        """習慣が 5 件未満の場合、全件の平均をフォールバックとして使用する。"""
        past_dates = self._current_month_past_dates()
        # 達成率 100% / 50% / 25% を狙って 3 件作成
        self._make_habit('A', past_dates)
        half = max(1, len(past_dates) // 2)
        self._make_habit('B', past_dates[:half])
        quarter = max(1, len(past_dates) // 4)
        self._make_habit('C', past_dates[:quarter])

        res = self.client.get(self.url)
        self.assertEqual(res.status_code, 200)

        # habit_rates は降順ソート済 (StatsView L342)
        rates_desc = [h['rate'] for h in res.data['habit_rates']]
        self.assertEqual(len(rates_desc), 3, '習慣 3 件が返却される')

        # 5 件未満なので全 3 件の平均が curr_rate になることを期待
        expected_curr = round(sum(rates_desc) / len(rates_desc))
        self.assertEqual(
            res.data['comparison']['curr']['rate'],
            expected_curr,
            '5 件未満は全件平均がフォールバック',
        )

    def test_7_habits_only_top5_in_average(self):
        """習慣が 7 件あるとき、達成率上位 5 件だけが平均に含まれる。"""
        past_dates = self._current_month_past_dates()
        n = len(past_dates)
        # 達成率を 100/85/70/55/40/25/10% で意図的に分散
        ratios = [1.0, 0.85, 0.70, 0.55, 0.40, 0.25, 0.10]
        for i, ratio in enumerate(ratios):
            dates_i = past_dates[: max(1, int(round(n * ratio)))]
            self._make_habit(f'H{i}', dates_i)

        res = self.client.get(self.url)
        self.assertEqual(res.status_code, 200)

        rates_desc = sorted(
            [h['rate'] for h in res.data['habit_rates']], reverse=True
        )
        self.assertEqual(len(rates_desc), 7, '習慣 7 件が返却される')

        # curr_rate は habit_rates の top 5 平均と一致するべき
        expected_curr = round(sum(rates_desc[:5]) / 5)
        self.assertEqual(
            res.data['comparison']['curr']['rate'],
            expected_curr,
            'top 5 の平均のみが採用される (下位 2 件は除外)',
        )

        # 全 7 件平均と top5 平均は同値ではないことを構造的に検証
        # (下位 2 件 = 25%, 10% を除外することで top5 平均 > 全平均 が成立)
        all_avg = round(sum(rates_desc) / 7)
        self.assertGreater(
            res.data['comparison']['curr']['rate'],
            all_avg,
            '下位 2 件除外で全平均よりも高い値になる',
        )

    def test_zero_habits_returns_zero(self):
        """習慣 0 件のとき、curr/prev/rate_diff すべて 0 で安全フォールバック。"""
        res = self.client.get(self.url)
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.data['comparison']['curr']['rate'], 0)
        self.assertEqual(res.data['comparison']['prev']['rate'], 0)
        self.assertEqual(res.data['comparison']['rate_diff'], 0)

    def test_rate_diff_reflects_top5_change(self):
        """先月と当月の top5 平均差が rate_diff に反映される。"""
        prev_dates = self._prev_month_past_dates()
        curr_dates = self._current_month_past_dates()

        # 当月: 100% (全日達成)、先月: ~50% (半分達成)
        prev_half = prev_dates[: max(1, len(prev_dates) // 2)]
        self._make_habit('改善習慣', prev_half + curr_dates)

        res = self.client.get(self.url)
        self.assertEqual(res.status_code, 200)

        curr_rate = res.data['comparison']['curr']['rate']
        prev_rate = res.data['comparison']['prev']['rate']

        # 1 件しかないので top5 平均 = その 1 件の rate
        # 当月 100% > 先月 ~50% を期待
        self.assertEqual(curr_rate, 100, '当月は全日達成で 100%')
        self.assertGreater(curr_rate, prev_rate, '当月が先月を上回る')
        self.assertEqual(
            res.data['comparison']['rate_diff'],
            curr_rate - prev_rate,
            'rate_diff = curr_rate - prev_rate',
        )

    def test_todo_excluded_from_habit_rates(self):
        """【ユーザー要望 2026-06-22】習慣別達成率に ToDo は含まれない。"""
        past_dates = self._current_month_past_dates()

        # 通常習慣 (count) を 1 件作成
        self._make_habit('運動', past_dates)
        # ToDo (habit_type='todo') を 1 件作成 (アクティブ、達成済み)
        todo = Habit.objects.create(
            player=self.player,
            name='買い物',
            category='その他',
            frequency='daily',
            habit_type='todo',
            is_active=True,
        )
        HabitLog.objects.create(habit=todo, date=self.today, count=1)

        res = self.client.get(self.url)
        self.assertEqual(res.status_code, 200)

        # habit_rates には ToDo「買い物」は含まれず、習慣「運動」のみ含まれる
        habit_names = [h['name'] for h in res.data['habit_rates']]
        self.assertIn('運動', habit_names, '習慣 (count) は集計対象')
        self.assertNotIn(
            '買い物', habit_names,
            'ToDo (habit_type=todo) は habit_rates から除外される',
        )
        self.assertEqual(len(habit_names), 1, 'ToDo を除外して 1 件のみ返却')
