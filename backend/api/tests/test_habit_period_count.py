"""【FEAT-520 (2026-08-06)】`reset_cycle` / `frequency` を実際に機能させる契約テスト。

## 背景

`reset_cycle` は長らく **表示専用**で、カウントの保存にも完了判定にも影響して
いなかった。BUG-34 (2026-05-07) でバッジを `period_progress.done` に繋いだが中身は
「達成日数」で、BUG-73 (2026-05-27) で `todayCount` に戻した際に「期間内の回数合計」
を作らなかったため、実装が空のまま残っていた。

本 FEAT で 2 設定に別々の役割を与える:

    frequency   = やるべき頻度   → 完了判定の窓 (`period_done`)
    reset_cycle = カウンタの周期 → バッジの集計窓 (`period_count`)

## テスト一覧 (指示書 §6.2)

  A: daily+weekly、月 2 回 / 火 3 回 → 水に取得 → period_count == 5
  B: A の状態で翌週月曜に取得 → period_count == 0 (週境界でリセット)
  C: daily+daily → period_count == 今日の count
  D: daily+monthly、月初をまたぐ → 前月分が入らない
  E: weekly+weekly、月曜達成 → 火曜取得 → period_done == True
  F: daily+daily、昨日達成 → 今日取得 → period_done == False
  G: daily+yearly、**120 日前**の log あり → period_count に含まれる (§4.4 の回帰)
  H: habit_type='todo' → period_count / period_done が日次のまま
  I: 既存 `period_progress` の done / total / label が **一切変わっていない** (§4.2)

> G と I はこのためだけに書いている。G は prefetch 窓 90 日の回帰
> (Flutter は `?period=year` を送っていないので窓を広げないと 1〜9 月が欠落する)、
> I は **launch 済 v1.0 の旧アプリが読んでいる契約**。どちらも落ちなければ気付けない。
"""
from contextlib import contextmanager
from datetime import date, timedelta
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from api.models import Habit, HabitLog, PlayerProfile
from api.serializers import HabitSerializer, get_period_start

User = get_user_model()

# 曜日を確定させた固定日付 (テストを実行日に依存させない)。
MONDAY = date(2026, 8, 3)
TUESDAY = date(2026, 8, 4)
WEDNESDAY = date(2026, 8, 5)
NEXT_MONDAY = date(2026, 8, 10)


@contextmanager
def freeze_today(value: date):
    """`timezone.localdate()` を固定する。

    serializer と view は両方 `from django.utils import timezone` して
    `timezone.localdate()` を呼ぶため、モジュール属性を差し替えれば双方に効く。
    """
    with patch('django.utils.timezone.localdate', return_value=value):
        yield


def _make_player(username='periodtester'):
    user = User.objects.create_user(
        username=username, email=f'{username}@example.com', password='pw',
    )
    return PlayerProfile.objects.create(user=user, name=username)


def _make_habit(player, *, frequency='daily', reset_cycle='daily',
                habit_type='count', name='テスト習慣'):
    return Habit.objects.create(
        player=player, name=name, category='運動',
        frequency=frequency, reset_cycle=reset_cycle, habit_type=habit_type,
    )


def _log(habit, on: date, count: int):
    return HabitLog.objects.create(habit=habit, date=on, count=count)


class PeriodStartHelperTests(TestCase):
    """§4.3 期間境界の定義。`period_count` と `period_done` が同じ関数を使う前提。"""

    def test_boundaries(self):
        self.assertEqual(get_period_start(WEDNESDAY, 'daily'), WEDNESDAY)
        self.assertEqual(get_period_start(WEDNESDAY, 'weekly'), MONDAY)
        self.assertEqual(get_period_start(WEDNESDAY, 'monthly'), date(2026, 8, 1))
        self.assertEqual(get_period_start(WEDNESDAY, 'yearly'), date(2026, 1, 1))

    def test_unknown_cycle_falls_back_to_today(self):
        # 未知の値で年初まで遡ると回数が桁違いになるため、狭い側に倒す。
        self.assertEqual(get_period_start(WEDNESDAY, 'fortnightly'), WEDNESDAY)


class PeriodCountSerializerTests(TestCase):
    """A-F / H / I — serializer を直接叩いて集計ロジックだけを検証する。"""

    def setUp(self):
        self.player = _make_player()

    # ── A ────────────────────────────────────────────────────────────────
    def test_a_daily_weekly_accumulates_across_days(self):
        """daily + weekly: 月 2 回 + 火 3 回 → 水曜時点で 5。

        これが本 FEAT の主目的。旧実装は「水曜の回数 = 0」を返していた。
        """
        habit = _make_habit(self.player, frequency='daily', reset_cycle='weekly')
        _log(habit, MONDAY, 2)
        _log(habit, TUESDAY, 3)

        with freeze_today(WEDNESDAY):
            data = HabitSerializer(habit).data

        self.assertEqual(data['period_count'], 5)

    # ── B ────────────────────────────────────────────────────────────────
    def test_b_week_boundary_resets(self):
        """翌週月曜には前週分が残らない (週境界でリセット)。"""
        habit = _make_habit(self.player, frequency='daily', reset_cycle='weekly')
        _log(habit, MONDAY, 2)
        _log(habit, TUESDAY, 3)

        with freeze_today(NEXT_MONDAY):
            data = HabitSerializer(habit).data

        self.assertEqual(
            data['period_count'], 0,
            '週が変われば 0 に戻ること。ここが落ちるなら集計窓が reset_cycle '
            'ではなく「全期間」になっている',
        )

    # ── C ────────────────────────────────────────────────────────────────
    def test_c_daily_daily_equals_today_count(self):
        """daily + daily (既存ユーザーの大多数) は今日の回数と一致 = 挙動不変。"""
        habit = _make_habit(self.player, frequency='daily', reset_cycle='daily')
        _log(habit, TUESDAY, 4)
        _log(habit, WEDNESDAY, 2)

        with freeze_today(WEDNESDAY):
            data = HabitSerializer(habit).data

        self.assertEqual(data['period_count'], 2)
        self.assertEqual(data['period_count'], data['today_log']['count'])

    # ── D ────────────────────────────────────────────────────────────────
    def test_d_monthly_excludes_previous_month(self):
        """daily + monthly: 月初をまたぐと前月分は入らない。"""
        habit = _make_habit(self.player, frequency='daily', reset_cycle='monthly')
        _log(habit, date(2026, 7, 31), 9)   # 前月末
        _log(habit, date(2026, 8, 1), 1)    # 当月初日
        _log(habit, date(2026, 8, 5), 2)

        with freeze_today(WEDNESDAY):        # 2026-08-05
            data = HabitSerializer(habit).data

        self.assertEqual(
            data['period_count'], 3,
            '前月末の 9 回が混入している = 集計窓が月初で切れていない',
        )

    # ── E ────────────────────────────────────────────────────────────────
    def test_e_weekly_frequency_stays_done_through_the_week(self):
        """weekly + weekly: 月曜に達成したら火曜も period_done。"""
        habit = _make_habit(self.player, frequency='weekly', reset_cycle='weekly')
        _log(habit, MONDAY, 1)

        with freeze_today(TUESDAY):
            data = HabitSerializer(habit).data

        self.assertTrue(data['period_done'])
        self.assertIsNone(
            data['today_log'],
            '今日の log は無いまま = 操作系 (isCompletedToday) は未完了のはず。'
            'この 2 つが同時に成立するのが FEAT-520 の設計 (§5.4)',
        )

    # ── F ────────────────────────────────────────────────────────────────
    def test_f_daily_frequency_resets_next_day(self):
        """daily + daily: 昨日達成しても今日は period_done == False。"""
        habit = _make_habit(self.player, frequency='daily', reset_cycle='daily')
        _log(habit, TUESDAY, 3)

        with freeze_today(WEDNESDAY):
            data = HabitSerializer(habit).data

        self.assertFalse(data['period_done'])
        self.assertEqual(data['period_count'], 0)

    def test_f2_daily_frequency_done_today(self):
        """daily の period_done は today_log.count > 0 と完全一致する。"""
        habit = _make_habit(self.player, frequency='daily', reset_cycle='weekly')
        _log(habit, MONDAY, 2)
        _log(habit, WEDNESDAY, 1)

        with freeze_today(WEDNESDAY):
            data = HabitSerializer(habit).data

        self.assertTrue(data['period_done'])
        self.assertEqual(
            data['period_count'], 3,
            'period_done は frequency (daily) 窓、period_count は reset_cycle '
            '(weekly) 窓。同じ窓を使っていると片方が壊れる',
        )

    # ── H ────────────────────────────────────────────────────────────────
    def test_h_todo_stays_daily(self):
        """ToDo は単発タスクなので、reset_cycle を持っていても日次で扱う。"""
        habit = _make_habit(
            self.player, frequency='daily', reset_cycle='monthly',
            habit_type='todo', name='買い物に行く',
        )
        _log(habit, date(2026, 8, 1), 5)
        _log(habit, WEDNESDAY, 1)

        with freeze_today(WEDNESDAY):
            data = HabitSerializer(habit).data

        self.assertEqual(data['period_count'], 1)
        self.assertTrue(data['period_done'])

    def test_h2_todo_not_done_when_completed_earlier(self):
        habit = _make_habit(
            self.player, frequency='daily', reset_cycle='monthly',
            habit_type='todo', name='書類を出す',
        )
        _log(habit, date(2026, 8, 1), 1)

        with freeze_today(WEDNESDAY):
            data = HabitSerializer(habit).data

        self.assertEqual(data['period_count'], 0)
        self.assertFalse(data['period_done'])

    # ── I ────────────────────────────────────────────────────────────────
    def test_i_period_progress_contract_unchanged(self):
        """§4.2: `period_progress` の既存キーは意味も値も変えない。

        v1.0 は launch 済で旧アプリが実機で動いている。`done` を「回数」に変えると
        ストアから更新していないユーザーの進捗バーが即座に壊れ、しかもこちらからは
        観測できない。
        """
        habit = _make_habit(self.player, frequency='daily', reset_cycle='weekly')
        _log(habit, MONDAY, 2)
        _log(habit, TUESDAY, 3)

        with freeze_today(WEDNESDAY):
            data = HabitSerializer(habit).data

        pp = data['period_progress']
        self.assertEqual(
            pp['done'], 2,
            'done は「達成した日数」(月・火の 2 日) のまま。回数合計 (5) に'
            '変わっていたら旧アプリの進捗バーが壊れる',
        )
        self.assertEqual(pp['total'], 7)
        self.assertEqual(pp['label'], '今週 2/7日')
        # 新アプリ用の構造化フィールドは追加のみ (§4.5)。
        self.assertEqual(pp['scope'], 'week')
        self.assertEqual(pp['unit'], 'day')
        # 回数合計は別フィールドで提供する。
        self.assertEqual(data['period_count'], 5)

    def test_i2_period_progress_none_when_freq_equals_cycle(self):
        """frequency == reset_cycle では従来どおり None (docstring と実装の一致)。"""
        habit = _make_habit(self.player, frequency='daily', reset_cycle='daily')
        _log(habit, WEDNESDAY, 1)

        with freeze_today(WEDNESDAY):
            data = HabitSerializer(habit).data

        self.assertIsNone(data['period_progress'])


class YearlyPrefetchWindowTests(TestCase):
    """G — §4.4 の回帰。prefetch 窓 90 日で 1〜9 月が欠落しないこと。

    serializer 単体では `_get_cached_logs()` が DB フォールバックで年初から読むため
    **この欠陥は再現しない**。必ず view (prefetch 経路) を通すこと。
    """

    def setUp(self):
        self.player = _make_player('yearlytester')
        token = Token.objects.create(user=self.player.user)
        self.client = APIClient()
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token.key}')

    def _fetch(self, path):
        with freeze_today(WEDNESDAY):
            return self.client.get(path)

    def test_g_yearly_includes_log_120_days_ago_via_habits_list(self):
        habit = _make_habit(self.player, frequency='daily', reset_cycle='yearly')
        old_day = WEDNESDAY - timedelta(days=120)   # 2026-04-07、同一年内
        self.assertEqual(old_day.year, WEDNESDAY.year)
        _log(habit, old_day, 7)
        _log(habit, WEDNESDAY, 1)

        res = self._fetch('/api/habits/')
        self.assertEqual(res.status_code, 200)
        payload = res.json()
        items = payload['results'] if isinstance(payload, dict) else payload
        row = next(h for h in items if h['id'] == habit.id)

        self.assertEqual(
            row['period_count'], 8,
            '120 日前の 7 回が欠落している = prefetch 窓が 90 日のまま。'
            'Flutter は ?period=year を送っていないので、view 側で '
            'reset_cycle=yearly の存在を見て窓を広げる必要がある (§4.4)',
        )

    def test_g2_yearly_includes_log_120_days_ago_via_home(self):
        """§4.4 は habits.py と home.py の **2 箇所とも**直す必要がある。"""
        habit = _make_habit(self.player, frequency='daily', reset_cycle='yearly')
        _log(habit, WEDNESDAY - timedelta(days=120), 7)
        _log(habit, WEDNESDAY, 1)

        res = self._fetch('/api/home/')
        self.assertEqual(res.status_code, 200)
        row = next(h for h in res.json()['habits'] if h['id'] == habit.id)

        self.assertEqual(
            row['period_count'], 8,
            'home.py 側の窓が広がっていない。ホーム画面のバッジだけ値が違う '
            '= 画面によって数字が食い違う状態になる',
        )

    def test_g3_non_yearly_player_keeps_90day_window(self):
        """yearly を持たないプレイヤーの窓は広げない (無用な読み込みを増やさない)。"""
        habit = _make_habit(self.player, frequency='daily', reset_cycle='weekly')
        _log(habit, WEDNESDAY - timedelta(days=120), 7)
        _log(habit, MONDAY, 2)

        res = self._fetch('/api/habits/')
        self.assertEqual(res.status_code, 200)
        payload = res.json()
        items = payload['results'] if isinstance(payload, dict) else payload
        row = next(h for h in items if h['id'] == habit.id)

        # 120 日前は今週の外なので、窓の広さに関係なく period_count には入らない。
        self.assertEqual(row['period_count'], 2)
        self.assertNotIn(
            str(WEDNESDAY - timedelta(days=120)), row['history'],
            'history は直近 30 日なので 120 日前の log は入らない',
        )
