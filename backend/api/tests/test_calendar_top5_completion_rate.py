"""【ユーザー要望 2026-06-22】CalendarView の completion_rate を top5 平均に変更した契約テスト 3 件。

旧: 全アクティブ習慣の達成率を均等平均 (低達成率の習慣に引っ張られ
    ユーザーのテンションを下げる原因)。
新: ToDo を除外した習慣別達成率を計算 → 高順 top 5 (5 件未満は全件) の
    平均を採用 (分析画面 StatsView と整合)。

対象 view: api.views.calendar.aggregations.CalendarView (`/api/calendar/`)

注意: 本テストは `summary.completion_rate` のみを検証する。
他指標 (total_completions / days_with_any / current_streak / 日別 pct)
は別概念のため scope 外。
"""
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
class CalendarTop5CompletionRateTest(APITestCase):
    """カレンダー summary.completion_rate を top5 平均化した契約テスト 3 シナリオ。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('p1', email='p1@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='P1')
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        self.today = timezone.localdate()
        self.url = reverse('calendar')

    # ── helpers ──────────────────────────────────────────────────────────

    def _make_habit(self, name, completed_dates, habit_type='count'):
        """指定日付すべてで count=1 の HabitLog を持つ習慣を生成。

        【2026-07-06 hotfix】created_at を「最古の completed_date か月初」の
        小さい方に override。auto_now_add で今日にセットされたままだと、
        月初〜今日にかけて retroactive に注入した logs が「習慣未作成期間の
        達成」として扱われ、rate 計算 (active-in-month 日数ベース) と衝突する。
        """
        habit = Habit.objects.create(
            player=self.player,
            name=name,
            category='その他',
            frequency='daily',
            habit_type=habit_type,
            is_active=True,
        )
        if completed_dates:
            month_start = date(self.today.year, self.today.month, 1)
            earliest = min(completed_dates)
            habit_start = min(month_start, earliest)
            Habit.objects.filter(pk=habit.pk).update(created_at=habit_start)
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

    def _compute_individual_rate(self, completed_n, past_days_n):
        return round(completed_n / past_days_n * 100) if past_days_n > 0 else 0

    # ── tests ────────────────────────────────────────────────────────────

    def test_under_5_habits_uses_all_as_fallback(self):
        """習慣 3 件 (5 件未満) → 全 3 件の平均がフォールバックとして使用される。"""
        past_dates = self._current_month_past_dates()
        n = len(past_dates)
        # 達成率: 100% / 50% / 25% を狙う
        self._make_habit('A', past_dates)
        self._make_habit('B', past_dates[: max(1, n // 2)])
        self._make_habit('C', past_dates[: max(1, n // 4)])

        res = self.client.get(self.url)
        self.assertEqual(res.status_code, 200)

        # 個別習慣の達成率を再現
        rates = [
            self._compute_individual_rate(n, n),
            self._compute_individual_rate(max(1, n // 2), n),
            self._compute_individual_rate(max(1, n // 4), n),
        ]
        rates_desc = sorted(rates, reverse=True)
        expected_rate = round(sum(rates_desc) / 3)  # 5 件未満は全件平均

        self.assertEqual(
            res.data['summary']['completion_rate'],
            expected_rate,
            '5 件未満は全件平均がフォールバック',
        )

    def test_7_habits_only_top5_in_average(self):
        """習慣 7 件 → 達成率高順 top 5 だけ平均、下位 2 件は除外される。"""
        past_dates = self._current_month_past_dates()
        n = len(past_dates)
        # 達成率を 100/85/70/55/40/25/10% で意図的に分散
        ratios = [1.0, 0.85, 0.70, 0.55, 0.40, 0.25, 0.10]
        completed_counts = []
        for i, ratio in enumerate(ratios):
            c = max(1, int(round(n * ratio)))
            completed_counts.append(c)
            self._make_habit(f'H{i}', past_dates[:c])

        res = self.client.get(self.url)
        self.assertEqual(res.status_code, 200)

        # 個別達成率を計算 → 降順 → top5 平均
        rates = [self._compute_individual_rate(c, n) for c in completed_counts]
        rates_desc = sorted(rates, reverse=True)
        expected_rate = round(sum(rates_desc[:5]) / 5)
        self.assertEqual(res.data['summary']['completion_rate'], expected_rate)

        # 下位 2 件除外で top5 平均 > 全 7 件平均 を構造的に検証
        all_avg = round(sum(rates_desc) / 7)
        self.assertGreater(
            res.data['summary']['completion_rate'],
            all_avg,
            '下位 2 件除外で全平均より高い値になる',
        )

    def test_todo_excluded_from_completion_rate(self):
        """ToDo は completion_rate の計算対象外 (分析画面 StatsView と整合)。"""
        past_dates = self._current_month_past_dates()

        # 通常習慣 (count) 1 件: 100% 達成
        self._make_habit('運動', past_dates)
        # ToDo (habit_type='todo') 1 件: 当日達成
        self._make_habit('買い物', [self.today], habit_type='todo')

        res = self.client.get(self.url)
        self.assertEqual(res.status_code, 200)

        # completion_rate は習慣 (count) の 100% のみ採用
        # ToDo の極端に低い達成率 (1/n 日) は計算に含まれない
        self.assertEqual(
            res.data['summary']['completion_rate'],
            100,
            'ToDo を除外して習慣のみで集計 → 100%',
        )
