"""【FEAT-290】calendar.py 分割: コア / orchestrator view モジュール (~260 LOC)。

旧 `backend/api/views/calendar.py` (1110 LOC, 10 View 同居) を機能別に
3 モジュールへ分割した内の 1 つ。本ファイルは「細部の read 経路 +
ブートストラップ orchestrator」を担う 4 view を集約:
    - CalendarHeatmapView    年間ヒートマップ (1 年分の達成度 + EXP 集計)
    - CalendarDailyView      日次詳細 (1 日の習慣 + Todo + Timeline)
    - CalendarBootstrapView  カレンダー画面の初回描画用集約 (P1-3)
    - Stats30DayView         直近 30 日のカテゴリ別集計 (FEAT-204)

import 互換性は親パッケージ `backend/api/views/calendar/__init__.py` の
re-export 経路で 100% 維持されており、`from api.views import calendar`
配下の旧 import パターンは無改修で動作する。
"""
from collections import defaultdict
from datetime import date, timedelta

from rest_framework.authentication import TokenAuthentication
from rest_framework.response import Response
from rest_framework.views import APIView

from django.db.models import Count, Sum
from django.utils import timezone

from ...authentication import GuestTokenAuthentication  # FEAT-190
from ...models import Habit, HabitLog, TimelineEvent
from ...permissions import IsAuthenticatedOrGuest  # FEAT-187
from ..mixins import PlayerMixin
# 【FEAT-290 hotfix】CalendarBootstrapView は内部で aggregations.py 定義の
# CalendarView / StreakView をインスタンス化して呼び出すため、明示 import が必要。
# 分割前は同一ファイル内で参照できていたが、分割後に import 漏れで NameError → 500
# になっていた（カレンダー画面が「うまくいきませんでした」エラーで表示されない真因）。
from .aggregations import CalendarView, StreakView


class CalendarHeatmapView(PlayerMixin, APIView):
    # FEAT-190: ヒートマップはカレンダー画面の基本表示要素のためゲストでも閲覧可能。
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def get(self, request):
        player = self.get_player(request)
        today  = timezone.localdate()
        start  = today - timedelta(days=90)

        total_habits = Habit.objects.filter(player=player, is_active=True).count()

        logs = (
            HabitLog.objects
            .filter(habit__player=player, date__gte=start, date__lte=today, count__gt=0)
            .values('date')
            .annotate(completed=Count('id'), exp=Sum('exp_gained'))
        )
        log_map = {row['date']: row for row in logs}

        def _quantize(pct: int) -> int:
            if pct == 0:   return 0
            if pct <= 25:  return 25
            if pct <= 50:  return 50
            if pct <= 75:  return 75
            return 100

        days = []
        for i in range(91):
            d   = start + timedelta(days=i)
            row = log_map.get(d, {})
            completed = row.get('completed', 0)
            raw_pct   = (
                round(completed / total_habits * 100)
                if total_habits > 0 else 0
            )
            days.append({
                'date':      d.isoformat(),
                'completed': completed,
                'exp':       row.get('exp', 0) or 0,
                'pct':       _quantize(min(100, raw_pct)),
                'is_today':  d == today,
            })

        return Response({'days': days, 'total_habits': total_habits})




class CalendarDailyView(PlayerMixin, APIView):
    """指定日の習慣・ToDo 達成状況を返すエンドポイント（CAL-01）。"""
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        today = timezone.localdate()
        try:
            d = date.fromisoformat(
                request.query_params.get('date', today.isoformat())
            )
        except (TypeError, ValueError):
            d = today

        player        = self.get_player(request)
        active_habits = Habit.objects.filter(
            player=player, is_active=True
        ).order_by('order', 'id')

        logs = {
            log.habit_id: log
            for log in HabitLog.objects.filter(habit__in=active_habits, date=d)
        }

        # 【BUG-78 fix (2026-06-01)】対象日 d 以外で完了済みの ToDo を除外する。
        #
        # 旧実装は `is_active=True` の全 ToDo を `due_date <= d` or `due_date is None`
        # で表示していたため、ホーム (/api/habits/) では翌日消える完了済 ToDo が、
        # カレンダーには永久に残る挙動になっていた (ホーム / カレンダー API のロジック不整合)。
        #
        # ホーム (`HabitListCreateView.get`) と同じ除外ロジックを適用、ただし
        # 対象日 d 当日に完了したものは「達成感演出」のため残す (`.exclude(date=d)`)。
        other_day_completed_todo_pks = set(
            HabitLog.objects.filter(
                habit__player=player,
                habit__is_active=True,
                habit__habit_type='todo',
                count__gte=1,
            )
            .exclude(date=d)
            .values_list('habit_id', flat=True)
            .distinct()
        )

        # 通常習慣（todo 以外）
        habits = []
        for habit in active_habits.exclude(habit_type='todo'):
            log = logs.get(habit.id)
            habits.append({
                'id':         habit.id,
                'name':       habit.name,
                'category':   habit.category,
                'difficulty': habit.difficulty,
                'priority':   habit.priority,
                'done':       log.count > 0 if log else False,
                'count':      log.count if log else 0,
            })

        # ToDo（期限が d 以前 または 当日完了済み または 期限未設定）
        # 【BUG-78】対象日 d 以外で完了済みの ToDo は除外 (ホーム挙動と整合)。
        todos = []
        for habit in active_habits.filter(habit_type='todo'):
            if habit.id in other_day_completed_todo_pks:
                continue  # 他日に完了済 → カレンダーに永久残留を防ぐ
            log  = logs.get(habit.id)
            done = log.count > 0 if log else False
            if done or habit.due_date is None or habit.due_date <= d:
                todos.append({
                    'id':       habit.id,
                    'name':     habit.name,
                    'priority': habit.priority,
                    'due_date': habit.due_date.isoformat() if habit.due_date else None,
                    'done':     done,
                })

        # ── タイムライン予定 ──────────────────────────────────────────────────
        timeline_events = TimelineEvent.objects.filter(
            player=player,
            date=d,
        ).order_by('start_time', 'created_at')

        timeline_data = []
        for ev in timeline_events:
            timeline_data.append({
                'id':           ev.pk,
                'title':        ev.title,
                'category':     ev.category,
                'icon_key':     ev.icon_key,
                'start_time':   ev.start_time.strftime('%H:%M') if ev.start_time else None,
                'end_time':     ev.end_time.strftime('%H:%M')   if ev.end_time   else None,
                'is_completed': ev.is_completed,
                'memo':         ev.memo,
            })

        return Response({
            'date':            d.isoformat(),
            'is_today':        d == today,
            'is_future':       d > today,
            'habits':          habits,
            'todos':           todos,
            'timeline_events': timeline_data,
        })


# ────────────────────────────────────────────────────────────────────────────
# 外部カレンダーインポート（BUG-17 / Google・Apple カレンダー対応）
# ────────────────────────────────────────────────────────────────────────────



class CalendarBootstrapView(PlayerMixin, APIView):
    """
    GET /api/calendar/bootstrap/?year=YYYY&month=MM&date=YYYY-MM-DD

    カレンダー画面の初回表示に必要な 3 つのデータセットを 1 リクエストで返す。
    内訳:
      - calendar: CalendarView と同等（月次グリッド + 月間サマリー）
      - streak:   StreakView と同等（7 日ストリーク + 習慣別ストリーク）
      - daily:    CalendarDailyView と同等（指定日の習慣・ToDo・タイムライン）

    Flutter 側の API 本数を 3 → 1 に削減（機能レビュー 20260511 P1-3）。
    既存の個別エンドポイント（/calendar/, /calendar/streak/, /calendar/daily/）は
    月送り・日付タップ等の局所更新で引き続き使用するため保守的に残す。

    クエリパラメータ:
      - year:  CalendarView に転送（未指定なら今日の年）
      - month: CalendarView に転送（未指定なら今月）
      - date:  CalendarDailyView に転送（未指定なら今日）
    """
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        calendar_resp = CalendarView().get(request)
        if calendar_resp.status_code >= 400:
            return calendar_resp

        streak_resp = StreakView().get(request)
        if streak_resp.status_code >= 400:
            return streak_resp

        daily_resp = CalendarDailyView().get(request)
        if daily_resp.status_code >= 400:
            return daily_resp

        return Response({
            'calendar': calendar_resp.data,
            'streak':   streak_resp.data,
            'daily':    daily_resp.data,
        })




class Stats30DayView(PlayerMixin, APIView):
    """過去 30 日の習慣完了数累積データを返す（FEAT-204）。

    Sabiowl のコア思想「積み上げ（Stacking）」を UI で可視化するためのデータ源。
    アプリ名にまで入っている思想なのに UI から「自分が積み上げた厚み」を一目で見る経路が
    なかったため、本エンドポイントを新設してホーム画面下部の折れ線グラフを支える。

    返却形式:
        {
          "days": [
            {"date": "2026-04-15", "count": 0,  "cumulative": 0},
            {"date": "2026-04-16", "count": 2,  "cumulative": 2},
            ...
            {"date": "2026-05-14", "count": 3,  "cumulative": 65},
          ],
          "milestones": {
            "current_streak":         12,
            "next_streak_milestone":  30,
            "days_to_next_milestone": 18,
            "total_completions_30d":  65,
          }
        }
    """

    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    _MILESTONES = [7, 30, 100, 365]

    def get(self, request):
        player = self.get_player(request)
        today  = timezone.localdate()
        start  = today - timedelta(days=29)

        # ToDo はストリーク・累積カウントの対象外（StreakView と同じ扱い）。
        # 「達成した習慣の回数」を 1 日ごとに集計し、30 日分の連続データに整形する。
        active_habits = (
            Habit.objects
            .filter(player=player, is_active=True)
            .exclude(habit_type='todo')
        )
        logs = (
            HabitLog.objects
            .filter(
                habit__in=active_habits,
                date__gte=start,
                date__lte=today,
                count__gt=0,
            )
            .values('date')
            .annotate(count=Count('id'))
            .order_by('date')
        )
        by_date = {row['date']: row['count'] for row in logs}

        days = []
        cumulative = 0
        for i in range(30):
            d = start + timedelta(days=i)
            count = by_date.get(d, 0)
            cumulative += count
            days.append({
                'date':       d.isoformat(),
                'count':      count,
                'cumulative': cumulative,
            })

        current_streak = (
            active_habits.order_by('-streak').values_list('streak', flat=True).first() or 0
        )
        next_milestone = self._next_milestone(current_streak)

        return Response({
            'days': days,
            'milestones': {
                'current_streak':         current_streak,
                'next_streak_milestone':  next_milestone,
                'days_to_next_milestone': max(0, next_milestone - current_streak),
                'total_completions_30d':  cumulative,
            },
        })

    def _next_milestone(self, current):
        """次のマイルストーン日数を返す（7 / 30 / 100 / 365）。"""
        for m in self._MILESTONES:
            if current < m:
                return m
        return current + 100
