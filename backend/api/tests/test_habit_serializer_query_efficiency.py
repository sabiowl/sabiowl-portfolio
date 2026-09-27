"""【2026-08-16 機能レビュー P1】`HabitSerializer` の単体直列化コストを縛る。

## なぜ必要か (実際に起きたこと)

`_get_cached_logs` は prefetch キャッシュ (`_year_logs`) が無いとき
`list(obj.logs.filter(...))` にフォールバックするが、**結果をどこにも載せて
いなかった**。このメソッドを呼ぶ `SerializerMethodField` は 5 つある
(`get_today_log` / `get_history` / `get_period_count` / `get_period_done` /
`get_period_progress`) ため、**同じ習慣の同じログ集合を 5 回 DB から取っていた**。

リスト経路 (`/api/home/` / `/habits/`) は `Prefetch(..., to_attr='_year_logs')`
が効くので影響が無く、**効いていたのは単体直列化の経路**だった:

    POST /habits/<id>/count/     ← 中核の動詞。1 日に何度も押される
    チェックリスト toggle
    習慣の作成 / 更新 / 詳細

`/api/home/` にはクエリ数ガードがあったのに、**中核の動詞には無かった**ため
2026-08-16 のレビューまで誰も数えていなかった。

## 何を縛るか

1. prefetch なしの単体直列化が **1 クエリ**であること (5 回発行の再発防止)
2. **ログ件数に依らない**こと (N+1 でないこと)
3. prefetch 経路が **0 クエリ**のままであること (リスト経路を壊していない)

実行方法:
```powershell
cd backend; python manage.py test api.tests.test_habit_serializer_query_efficiency
```
"""
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.db import connection
from django.db.models import Prefetch
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.utils import timezone

from api.models import Habit, HabitLog, PlayerProfile
from api.serializers import HabitSerializer

User = get_user_model()


class HabitSerializerQueryEfficiencyTest(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(username='habitq', password='pw')
        self.player = PlayerProfile.objects.create(user=self.user, name='HabitQ')

    def _habit_with_logs(self, n_logs: int, name: str = 'h') -> Habit:
        habit = Habit.objects.create(player=self.player, name=name)
        today = timezone.localdate()
        for i in range(n_logs):
            HabitLog.objects.create(
                habit=habit, date=today - timedelta(days=i), count=1, exp_gained=10,
            )
        return habit

    def _serialize_query_count(self, habit: Habit) -> int:
        with CaptureQueriesContext(connection) as ctx:
            HabitSerializer(habit).data
        return len(ctx.captured_queries)

    def test_single_serialization_is_one_query(self):
        """prefetch 無しの単体直列化は 1 クエリ。

        5 つの SerializerMethodField が同じログ集合を使うが、
        `_get_cached_logs` が結果を `obj._year_logs` に載せるので DB は 1 回だけ。
        """
        habit = self._habit_with_logs(3)
        habit.refresh_from_db()  # 実経路 (habits.py の count / toggle) と同じ形

        count = self._serialize_query_count(habit)

        self.assertEqual(
            count, 1,
            f'単体直列化で {count} クエリ発行されている。'
            '_get_cached_logs の fallback 結果が obj._year_logs に載っていない '
            '(SerializerMethodField 5 つがそれぞれ DB を叩いている)',
        )

    def test_does_not_scale_with_log_count(self):
        """ログを 3 → 60 件に増やしてもクエリ数が変わらない (N+1 でない)。"""
        few  = self._habit_with_logs(3,  name='few')
        many = self._habit_with_logs(60, name='many')

        self.assertEqual(
            self._serialize_query_count(few),
            self._serialize_query_count(many),
            'ログ件数でクエリ数が変わっている (N+1)',
        )

    def test_prefetched_serialization_issues_no_query(self):
        """prefetch 済み (リスト経路) は 0 クエリのまま。

        本修正がリスト経路の挙動を変えていないことの回帰。
        """
        self._habit_with_logs(3)
        today = timezone.localdate()
        year_start = today.replace(month=1, day=1)

        habits = list(
            Habit.objects.filter(player=self.player).prefetch_related(
                Prefetch(
                    'logs',
                    queryset=HabitLog.objects.filter(date__gte=year_start).order_by('date'),
                    to_attr='_year_logs',
                ),
            )
        )

        with CaptureQueriesContext(connection) as ctx:
            HabitSerializer(habits[0]).data

        self.assertEqual(
            len(ctx.captured_queries), 0,
            'prefetch 済みなのに DB を叩いている (_year_logs の分岐が壊れている)',
        )

    def test_memo_does_not_leak_across_instances(self):
        """メモは model インスタンス単位。別インスタンスには漏れない。

        `obj._year_logs` への代入がクラス属性やシリアライザ側に載っていると、
        **別の習慣のログを返す**という最悪の壊れ方をする。
        """
        a = self._habit_with_logs(2, name='a')
        b = self._habit_with_logs(5, name='b')

        data_a = HabitSerializer(a).data
        data_b = HabitSerializer(b).data

        self.assertEqual(len(data_a['history']), 2)
        self.assertEqual(len(data_b['history']), 5,
                         'a のログが b に漏れている (メモの置き場所が誤っている)')
