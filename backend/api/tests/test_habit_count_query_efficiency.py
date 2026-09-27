"""【2026-08-16 機能レビュー P3】習慣タップ (`POST /habits/<id>/count/`) のクエリ効率。

## なぜ必要か

`GET /api/home/` には 2026-08-05 からクエリ数ガードがあったが、
**中核の動詞である習慣タップには無かった**。ホームは起動時の 1 回、
タップは **1 日に何度も**押される。にもかかわらず誰も数えていなかったため、
`HabitSerializer` が同じ HabitLog を 5 回取りに行っていたことが
2026-08-16 のレビューまで発見されなかった。

## 本テストの設計方針

`test_home_bootstrap_query_efficiency.py` と同じ 2 層構造にする:

  1. `test_baseline_retap_query_count` — **再タップ (一番軽い経路)** のコストを
     数字として記録し、上限で縛る。

  2. `test_*_does_not_scale_*` — ログ件数 / 他の習慣の件数を増やしても
     クエリ数が変わらないこと。**これが本命** (N+1 の直接検査)。

**この数字が増えたら、増やす前に「意図した増加か」を判断すること。**
機械的に数字を書き換えると本テストはガードとして死ぬ。

## 実測 (2026-08-16、習慣 5 件、`_get_cached_logs` の memo 修正後)

本テストが実際に print する値:

| 経路 | クエリ数 |
|---|---:|
| その日の初回タップ | **72** |
| **再タップ (throttled 経路を消化した後)** | **35** |

初回が重いのは **設計どおり**で、その日の初回だけチャレンジ進捗 /
初回タスクボーナス / パズルピース / ログインボーナスが発火する。
**初回の絶対値は master data の件数や player の初期状態に依存して振れる**
(同じコードでも計測の組み立て方で 72〜122 の幅が出た) ため上限では縛らず、
「件数で増えないこと」(N+1 でないこと) だけを縛る。上限は再タップに付ける。

実行方法:
```powershell
cd backend; python manage.py test api.tests.test_habit_count_query_efficiency
```
"""
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from api.models import Habit, HabitLog, PlayerProfile

User = get_user_model()


class HabitCountQueryEfficiencyTest(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(username='tapq', password='pw')
        self.player = PlayerProfile.objects.create(user=self.user, name='TapQ')
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # MaintenanceConfig の 60s TTL cache を暖める (先行テスト次第で 1 ぶれる)。
        from api.services.maintenance_cache import get_maintenance_config
        get_maintenance_config()

        # 遅延初期化 (PlayerGachaStatus の get_or_create 等) を消化しておく。
        self.client.get('/api/home/')

        self.habits = [
            Habit.objects.create(player=self.player, name=f'base-{i}')
            for i in range(5)
        ]

        # 【重要】1 日に 1 回だけ走る throttled な経路を先に消化する。
        # これをしないと「何回目のタップを測ったか」でクエリ数が変わり、
        # 比較が成立しない。3 回叩くのは以下の理由:
        #
        #   1 回目 … その日の初回だけの経路 (チャレンジ進捗 / 初回タスク
        #            ボーナス / パズルピース / ログインボーナス)
        #   3 回目 … フレンド gift popup 判定 (FEAT-452)。
        #            **当日 3 回目のタスク達成でのみ発火**する documented な仕様で
        #            (`friend_gift_popup_service.py` docstring)、
        #            `api_gift` + `api_friendship` の 2 本が乗る。
        #
        # 最初にこれを消化せずに書いたところ、「習慣を 5 → 40 件に増やすと
        # +2 クエリ」と読める失敗が出た。実際は習慣数と無関係で、
        # **たまたま 3 回目を測っていた**だけだった (37 -> 39 -> 37 -> 37)。
        for _ in range(3):
            self._tap(self.habits[0])

    # ── ヘルパー ─────────────────────────────────────────────────

    def _tap(self, habit: Habit, action: str = 'plus'):
        res = self.client.post(f'/api/habits/{habit.pk}/count/',
                               {'action': action}, format='json')
        self.assertEqual(res.status_code, 200, res.data)
        return res

    def _tap_query_count(self, habit: Habit) -> int:
        with CaptureQueriesContext(connection) as ctx:
            self._tap(habit)
        return len(ctx.captured_queries)

    def _habit_with_history(self, n_logs: int, name: str) -> Habit:
        habit = Habit.objects.create(player=self.player, name=name)
        today = timezone.localdate()
        # 今日ぶんは作らない (タップで作られる経路をそのまま測るため)。
        for i in range(1, n_logs + 1):
            HabitLog.objects.create(
                habit=habit, date=today - timedelta(days=i), count=1, exp_gained=10,
            )
        return habit

    # ── 1. ベースライン ──────────────────────────────────────────

    def test_baseline_retap_query_count(self):
        """同じ習慣を再タップしたときのクエリ数を記録する。

        **一番軽いはずの経路**なので、ここが太ると全タップが太る。

        2026-08-16 実測 = 35。`HabitSerializer` が同じ HabitLog を 5 回
        取りに行っていた重複を潰した後の値。上限は +10 の余裕を見て 45 とする。
        """
        count = self._tap_query_count(self.habits[0])

        self.assertLessEqual(
            count, 45,
            f'習慣タップのクエリ数が {count} 件に増えている。'
            '1 日に何度も押される中核の経路なので、増加が意図的か確認すること。',
        )
        print(f'\n  [habit count] 再タップのクエリ数: {count}')

    # ── 2. N+1 ガード (本命) ─────────────────────────────────────

    def test_does_not_scale_with_log_history(self):
        """ログ履歴を 3 → 60 件に増やしてもクエリ数が変わらない。

        `HabitSerializer` は今年ぶんのログを直列化するため、ここが件数に
        比例すると **履歴の長い古参ユーザーほどタップが重くなる**。
        """
        few  = self._habit_with_history(3,  'few')
        many = self._habit_with_history(60, 'many')

        # 各習慣の「その日の初回」経路を消化してから比較する
        # (gift popup 判定は setUp で消化済み、こちらは habit 単位の初回)。
        self._tap(few)
        self._tap(many)

        before = self._tap_query_count(few)
        after  = self._tap_query_count(many)

        self.assertEqual(
            before, after,
            f'ログ件数でクエリ数が変わっている (3 件: {before} / 60 件: {after})。'
            'N+1 が入り込んでいる',
        )

    def test_does_not_scale_with_other_habits(self):
        """他の習慣を 5 → 40 件に増やしても、1 タップのクエリ数が変わらない。

        タップのレスポンスは対象の習慣 1 件しか含まないので、
        所持数に比例してはいけない。
        """
        target = self.habits[0]
        before = self._tap_query_count(target)

        for i in range(35):
            Habit.objects.create(player=self.player, name=f'extra-{i}')

        after = self._tap_query_count(target)

        self.assertEqual(
            before, after,
            f'習慣の所持数でクエリ数が変わっている (5 件: {before} / 40 件: {after})',
        )

    def test_first_tap_of_day_does_not_scale_with_habits(self):
        """その日の初回タップも、習慣の所持数でクエリ数が変わらない。

        初回は**設計上重い** (チャレンジ進捗 / 初回タスクボーナス / パズルピース /
        ログインボーナスが発火する) ため絶対値では縛らない —— master data の
        件数に依存して振れるので、上限で縛ると無関係な変更で赤くなる。
        **件数で増えないこと**だけを縛るのが N+1 ガードとしての本質。
        """
        few_user = User.objects.create_user(username='tapq_few', password='pw')
        many_user = User.objects.create_user(username='tapq_many', password='pw')
        counts = []

        for user, n_habits in ((few_user, 5), (many_user, 40)):
            player = PlayerProfile.objects.create(user=user, name=user.username)
            token = Token.objects.create(user=user)
            client = APIClient()
            client.credentials(HTTP_AUTHORIZATION=f'Token {token.key}')
            client.get('/api/home/')  # 遅延初期化を消化

            habits = [
                Habit.objects.create(player=player, name=f'{user.username}-{i}')
                for i in range(n_habits)
            ]
            with CaptureQueriesContext(connection) as ctx:
                res = client.post(f'/api/habits/{habits[0].pk}/count/',
                                  {'action': 'plus'}, format='json')
            self.assertEqual(res.status_code, 200, res.data)
            counts.append(len(ctx.captured_queries))

        self.assertEqual(
            counts[0], counts[1],
            f'初回タップが習慣の所持数でスケールしている '
            f'(5 件: {counts[0]} / 40 件: {counts[1]})',
        )
        print(f'\n  [habit count] その日の初回タップのクエリ数: {counts[0]}')
