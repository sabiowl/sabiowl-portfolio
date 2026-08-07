"""【FEAT-290】calendar.py 分割: 集計系 view モジュール。

旧 `backend/api/views/calendar.py` (1110 LOC, 10 View 同居) を機能別に
3 モジュールへ分割した内の 1 つ。本ファイルは「集計・統計の read-only
クエリ」を担う 3 view を集約:
    - CalendarView         月次カレンダーグリッド (達成率 / EXP / Todo / Timeline)
    - StreakView           連続達成日数 + 直近 7 日サマリー
    - StatsView            週次集計 + カテゴリ別達成率

【20260729 review §3 C-1 対応】旧 MonthlySummaryView (181 行) は削除済。
削除理由: Mobile 側は `MonthlySummaryCard` が bootstrap の `summary.completionRate`
から**クライアント側で** grade を計算 (monthly_summary_card.dart:5-11) しており、
Backend `MonthlySummaryView` は誰の目にも触れない dead code だった。しかも
grade 閾値が二重管理で drift 済 (Backend: B≥55, Mobile: B≥60)。
将来 grade 集計を Backend 経由にしたくなった場合は git history から復元可能。

import 互換性は親パッケージ `backend/api/views/calendar/__init__.py` の
re-export 経路で 100% 維持されており、`from api.views import calendar`
配下の旧 import パターンは無改修で動作する。

関連: FEAT-268 (Flutter 側 calendar 分割) の Backend 側対称化。
"""
import calendar as _cal
from collections import defaultdict, OrderedDict
from datetime import date, timedelta

from rest_framework.response import Response
from rest_framework.views import APIView

from django.utils import timezone

from ...models import Habit, HabitLog, RestDay, TimelineEvent
from ...permissions import IsAuthenticatedOrGuest  # FEAT-187
from ..mixins import PlayerMixin


class CalendarView(PlayerMixin, APIView):
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        today = timezone.localdate()
        try:
            year  = int(request.query_params.get('year',  today.year))
            month = int(request.query_params.get('month', today.month))
            if not (1 <= month <= 12):
                month = today.month
        except (TypeError, ValueError):
            year, month = today.year, today.month

        player        = self.get_player(request)
        active_habits = Habit.objects.filter(player=player, is_active=True).order_by('order', 'id')
        total_habits  = active_habits.count()
        days_in_month = _cal.monthrange(year, month)[1]

        # Action 3: select_related で habit への追加クエリを防止
        month_logs = HabitLog.objects.filter(
            habit__in=active_habits,
            date__year=year,
            date__month=month,
        ).select_related('habit')

        # P0-4: month_logs を Python 側で集計（重複クエリを廃止）
        logs_by_date = defaultdict(list)
        exp_by_date  = defaultdict(int)
        for log in month_logs:
            logs_by_date[log.date].append(log)
            exp_by_date[log.date] += log.exp_gained or 0

        # 休息日セット（この月分をまとめて取得）
        rest_day_dates = set(
            RestDay.objects.filter(
                player=player,
                date__year=year,
                date__month=month,
            ).values_list('date', flat=True)
        )

        # ── Todo の当月分を一括取得して N+1 なしでマッピング ─────────────────
        from collections import defaultdict as _defaultdict

        todos_qs = Habit.objects.filter(
            player=player,
            habit_type='todo',
            is_active=True,
            due_date__year=year,
            due_date__month=month,
        )
        todo_ids = list(todos_qs.values_list('id', flat=True))
        done_ids = set(
            HabitLog.objects.filter(
                habit_id__in=todo_ids,
                date__year=year,
                date__month=month,
            ).values_list('habit_id', flat=True)
        )
        todo_by_date = _defaultdict(list)
        for todo in todos_qs:
            todo_by_date[todo.due_date].append({
                'priority': todo.priority,
                'done':     todo.id in done_ids,
            })

        # FEAT-108: タイムライン予定を月まとめて取得し、日付ごとにグループ化
        timeline_qs = TimelineEvent.objects.filter(
            player=player,
            date__year=year,
            date__month=month,
        ).order_by('date', 'start_time')

        timeline_by_date = defaultdict(list)
        for ev in timeline_qs:
            timeline_by_date[ev.date].append({
                'id':           ev.id,
                'title':        ev.title,
                'category':     ev.category,
                'icon_key':     ev.icon_key,
                'is_completed': ev.is_completed,
            })

        days              = []
        total_completions = 0
        days_with_any     = 0
        # 【ユーザー要望 2026-06-22】completion_rate を top5 平均で再計算するため、
        # 既存ループ内で各 habit の月間達成日数を集計しておく (追加 DB クエリなし)。
        habit_completed_days = defaultdict(int)  # habit_id -> 月内達成日数

        for day_num in range(1, days_in_month + 1):
            d         = date(year, month, day_num)
            is_future = d > today
            day_logs  = logs_by_date.get(d, [])
            log_by_habit = {log.habit_id: log for log in day_logs}

            habit_results   = []
            completed_count = 0

            if not is_future:
                for habit in active_habits:
                    log   = log_by_habit.get(habit.id)
                    count = log.count if log else 0
                    done  = count > 0
                    if done:
                        completed_count += 1
                        habit_completed_days[habit.id] += 1
                    habit_results.append({
                        'id':         habit.id,
                        'name':       habit.name,
                        'category':   habit.category,
                        'done':       done,
                        'count':      count,
                        'difficulty': habit.difficulty,
                    })

            if completed_count > 0:
                total_completions += completed_count
                days_with_any     += 1

            pct = 0
            if total_habits > 0 and not is_future:
                raw = completed_count / total_habits * 100
                if   raw == 0:   pct = 0
                elif raw <= 25:  pct = 25
                elif raw <= 50:  pct = 50
                elif raw <= 75:  pct = 75
                else:            pct = 100

            todo_list = todo_by_date.get(d, [])
            pending   = [t for t in todo_list if not t['done']]

            days.append({
                'date':               d.isoformat(),
                'day':                day_num,
                'dow':                d.isoweekday() % 7,
                'is_today':           d == today,
                'is_future':          is_future,
                'completed':          completed_count,
                'total':              total_habits,
                'pct':                pct,
                'exp':                exp_by_date.get(d, 0) or 0,
                'habits':             habit_results,
                'is_rest_day':        d in rest_day_dates,
                'todo_pending':       len(pending),
                'todo_high_pending':  any(t['priority'] == 'high' for t in pending),
                # FEAT-108: タイムライン予定（月次グリッドのチップ表示用）
                'timeline_events':    timeline_by_date.get(d, []),
            })

        past_days_count = sum(1 for d in days if not d['is_future'])

        # ── 【ユーザー要望 2026-06-22 → 2026-07-06 hotfix】達成率を per-habit
        # active-in-month 日数ベースに変更 ─────────────────────────────
        # 旧 (2026-06-22): completed_days / past_days_count で per-habit rate
        #   計算 → 高順 top5 平均。
        #   問題: 月半ばに作成した習慣が「まだ活動していない前半日数」で
        #        分母が水増しされ、実質達成率が過小評価される
        #        (例: 7/5 作成、7/5-6 完璧に達成 → 2/6 = 33% と表示)。
        # 新: 各習慣の「その月内に active だった日数」を分母に使う。
        #   effective_start = max(habit.created_at, 月初)
        #   effective_end   = min(today, 月末)  ← 当月は today、先月末は月末
        #   effective_days  = end - start + 1  (負なら 0 = 該当月未活動)
        # これによりユーザー要望「当月は経過日数、先月は月末で月内のみ」を
        # 両方満たしつつ、月半ば作成の習慣も適正評価される。
        # 他指標 (total_completions / days_with_any / current_streak / 日別 pct)
        # は別概念のため現状維持 (scope creep 回避)。
        month_start = date(year, month, 1)
        month_end   = date(year, month, days_in_month)
        effective_end = min(today, month_end)  # 未来月は past_days_count=0
        non_todo_rates = []
        for habit in active_habits:
            if habit.habit_type == 'todo':
                continue
            habit_start = max(habit.created_at, month_start)
            if habit_start > effective_end:
                # habit created after the evaluation window → skip
                continue
            effective_days = (effective_end - habit_start).days + 1
            if effective_days <= 0:
                continue
            completed = habit_completed_days.get(habit.id, 0)
            non_todo_rates.append(round(completed / effective_days * 100))
        non_todo_rates.sort(reverse=True)
        top5 = non_todo_rates[:5]
        completion_rate = round(sum(top5) / len(top5)) if top5 else 0

        current_streak = (
            active_habits.order_by('-streak').values_list('streak', flat=True).first() or 0
        )

        return Response({
            'year':  year,
            'month': month,
            'days':  days,
            'summary': {
                'total_completions': total_completions,
                'completion_rate':   completion_rate,
                'current_streak':    current_streak,
                'days_with_any':     days_with_any,
                'past_days':         past_days_count,
                'total_habits':      total_habits,
            },
        })




class StreakView(PlayerMixin, APIView):
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        today         = timezone.localdate()
        player        = self.get_player(request)
        # ToDo はストリーク・ヒートマップの対象外なので除外する
        active_habits = (
            Habit.objects
            .filter(player=player, is_active=True)
            .exclude(habit_type='todo')
            .order_by('order', 'id')
        )

        current_streak = (
            active_habits.order_by('-streak').values_list('streak', flat=True).first() or 0
        )
        best_streak = (
            active_habits.order_by('-best_streak').values_list('best_streak', flat=True).first() or 0
        )
        days_to_record = max(0, best_streak - current_streak + 1) if current_streak < best_streak else 0

        dates_7 = [today - timedelta(days=i) for i in range(6, -1, -1)]

        # Action 3: select_related で habit への追加クエリを防止
        logs_7 = HabitLog.objects.filter(
            habit__in=active_habits,
            date__in=dates_7,
        ).select_related('habit')

        logs_by_date = defaultdict(dict)
        for log in logs_7:
            logs_by_date[log.date][log.habit_id] = log

        DOW_JP = ['月', '火', '水', '木', '金', '土', '日']

        seven_days = []
        for d in dates_7:
            day_habits = []
            for habit in active_habits:
                log   = logs_by_date.get(d, {}).get(habit.id)
                count = log.count if log else 0
                day_habits.append({
                    'id':         habit.id,
                    'name':       habit.name,
                    'category':   habit.category,
                    'done':       count > 0,
                    'count':      count,
                    'difficulty': habit.difficulty,
                })
            seven_days.append({
                'date':     d.isoformat(),
                'label':    DOW_JP[d.weekday()],
                'is_today': d == today,
                'habits':   day_habits,
            })

        habit_streaks = [
            {
                'id':          habit.id,
                'name':        habit.name,
                'category':    habit.category,
                'streak':      habit.streak,
                'best_streak': habit.best_streak,
            }
            for habit in active_habits
        ]
        habit_streaks.sort(key=lambda h: h['streak'], reverse=True)

        return Response({
            'current_streak':  current_streak,
            'best_streak':     best_streak,
            'days_to_record':  days_to_record,
            'seven_days':      seven_days,
            'habit_streaks':   habit_streaks,
        })




class StatsView(PlayerMixin, APIView):
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        today = timezone.localdate()
        try:
            year  = int(request.query_params.get('year',  today.year))
            month = int(request.query_params.get('month', today.month))
            if not (1 <= month <= 12):
                month = today.month
        except (TypeError, ValueError):
            year, month = today.year, today.month

        player        = self.get_player(request)
        # 【ユーザー要望 2026-06-22】分析画面の習慣別達成率には ToDo を含めない。
        # ToDo は ID で個別管理される 1 回限りタスクであり、達成「率」の概念と
        # 親和性が低いため、習慣 (count / checklist) のみを集計対象にする。
        active_habits = (
            Habit.objects
            .filter(player=player, is_active=True)
            .exclude(habit_type='todo')
            .order_by('order', 'id')
        )
        total_habits  = active_habits.count()
        days_in_month = _cal.monthrange(year, month)[1]

        # Action 3: select_related で habit への追加クエリを防止
        month_logs = HabitLog.objects.filter(
            habit__in=active_habits,
            date__year=year, date__month=month,
        ).select_related('habit')
        logs_by_date = defaultdict(dict)
        for log in month_logs:
            logs_by_date[log.date][log.habit_id] = log

        habit_rates = []
        for habit in active_habits:
            completed_days = 0
            past_days = 0
            for day_num in range(1, days_in_month + 1):
                d = date(year, month, day_num)
                if d > today:
                    break
                past_days += 1
                log = logs_by_date.get(d, {}).get(habit.id)
                if log and log.count > 0:
                    completed_days += 1
            rate = round(completed_days / past_days * 100) if past_days > 0 else 0
            habit_rates.append({
                'id':        habit.id,
                'name':      habit.name,
                'category':  habit.category,
                'completed': completed_days,
                'past_days': past_days,
                'rate':      rate,
            })
        habit_rates.sort(key=lambda h: h['rate'], reverse=True)

        DOW_JP  = ['日', '月', '火', '水', '木', '金', '土']
        dow_acc = defaultdict(list)
        week_map = OrderedDict()

        for day_num in range(1, days_in_month + 1):
            d = date(year, month, day_num)
            if d > today:
                break
            dow = d.isoweekday() % 7
            log_map = logs_by_date.get(d, {})
            completed = sum(
                1 for h in active_habits
                if log_map.get(h.id) and log_map[h.id].count > 0
            )
            pct = round(completed / total_habits * 100) if total_habits > 0 else 0
            dow_acc[dow].append(pct)

            iso_week = d.isocalendar()[1]
            wk = f"{d.isocalendar()[0]}-W{iso_week:02d}"
            if wk not in week_map:
                week_map[wk] = {}
            week_map[wk][dow] = pct

        dow_avgs = []
        for i in range(7):
            vals = dow_acc.get(i, [])
            avg  = round(sum(vals) / len(vals)) if vals else None
            dow_avgs.append({'dow': i, 'label': DOW_JP[i], 'rate': avg})

        measured = [d for d in dow_avgs if d['rate'] is not None]
        weakest  = min(measured, key=lambda d: d['rate']) if measured else None

        weeks_list = []
        for idx, (wk, dow_map) in enumerate(week_map.items()):
            weeks_list.append({
                'label': f'W{idx + 1}',
                'data':  [dow_map.get(i) for i in range(7)],
            })

        if month == 1:
            prev_year, prev_month = year - 1, 12
        else:
            prev_year, prev_month = year, month - 1

        prev_days_in_month = _cal.monthrange(prev_year, prev_month)[1]
        # Action 3: select_related で habit への追加クエリを防止
        prev_logs = HabitLog.objects.filter(
            habit__in=active_habits,
            date__year=prev_year, date__month=prev_month,
        ).select_related('habit')
        prev_logs_by_date = defaultdict(dict)
        for log in prev_logs:
            prev_logs_by_date[log.date][log.habit_id] = log

        # 累計達成回数 (comparison.{prev,curr}.total) は全習慣合算を維持。
        # 「達成率」のみ後段で top5 平均に置き換える (ユーザー判断 2026-06-22)。
        prev_completed = 0
        prev_past_days = 0
        for day_num in range(1, prev_days_in_month + 1):
            d = date(prev_year, prev_month, day_num)
            if d > today:
                break
            prev_past_days += 1
            for habit in active_habits:
                log = prev_logs_by_date.get(d, {}).get(habit.id)
                if log and log.count > 0:
                    prev_completed += 1

        curr_completed = 0
        curr_past_days = 0
        for day_num in range(1, days_in_month + 1):
            d = date(year, month, day_num)
            if d > today:
                break
            curr_past_days += 1
            for habit in active_habits:
                log = logs_by_date.get(d, {}).get(habit.id)
                if log and log.count > 0:
                    curr_completed += 1

        # ── 【ユーザー判断 2026-06-22】先月比較の達成率を top5 平均に変更 ─────
        # 旧: 全アクティブ習慣の達成率を均等平均 (低達成率の習慣に引っ張られ
        #     ユーザーのテンションを下げる原因となっていた)。
        # 新: 各月で習慣別達成率の高い順 top 5 (5 件未満なら全件) を平均化。
        #     当月と先月で独立に top5 を選び、それぞれの平均で比較する。
        # 累計達成回数 (total) は別軸の指標として全習慣合算を維持し、
        # 達成率 (rate) のみ top5 平均で置換する。

        def _top5_avg(rates_list):
            """達成率降順ソート済リストから上位 5 件 (未満なら全件) の平均を返す。

            Args:
                rates_list: 達成率降順ソート済の dict のリスト ({'rate': int, ...})。

            Returns:
                int: 上位 5 件の rate 平均 (0-100)。空リストなら 0。
            """
            if not rates_list:
                return 0
            top = rates_list[:5]
            return round(sum(h['rate'] for h in top) / len(top))

        # 先月分の習慣別達成率を独立に計算 (当月の habit_rates と同じ手順)。
        prev_habit_rates = []
        for habit in active_habits:
            h_completed = 0
            h_past_days = 0
            for day_num in range(1, prev_days_in_month + 1):
                d = date(prev_year, prev_month, day_num)
                if d > today:
                    break
                h_past_days += 1
                log = prev_logs_by_date.get(d, {}).get(habit.id)
                if log and log.count > 0:
                    h_completed += 1
            rate = round(h_completed / h_past_days * 100) if h_past_days > 0 else 0
            prev_habit_rates.append({'rate': rate})
        prev_habit_rates.sort(key=lambda h: h['rate'], reverse=True)

        # 当月の habit_rates は既に上で達成率降順ソート済 (L342) なのでそのまま使用。
        curr_rate = _top5_avg(habit_rates)
        prev_rate = _top5_avg(prev_habit_rates)

        best_habit  = habit_rates[0] if habit_rates else None
        worst_habit = habit_rates[-1] if len(habit_rates) > 1 else None

        return Response({
            'year':         year,
            'month':        month,
            'habit_rates':  habit_rates,
            'dow_heatmap': {
                'weeks':    weeks_list,
                'dow_avgs': dow_avgs,
                'weakest':  weakest,
            },
            'comparison': {
                'prev': {
                    'year': prev_year, 'month': prev_month,
                    'total': prev_completed, 'rate': prev_rate,
                },
                'curr': {
                    'year': year, 'month': month,
                    'total': curr_completed, 'rate': curr_rate,
                },
                'total_diff': curr_completed - prev_completed,
                'rate_diff':  curr_rate - prev_rate,
            },
            'insight': {
                'best_habit_name':  best_habit['name']  if best_habit  else None,
                'best_habit_rate':  best_habit['rate']  if best_habit  else 0,
                'worst_habit_name': worst_habit['name'] if worst_habit else None,
                'worst_habit_rate': worst_habit['rate'] if worst_habit else 0,
                'weak_dow_label':   weakest['label']    if weakest     else None,
                'weak_dow_rate':    weakest['rate']      if weakest     else 0,
            },
        })

