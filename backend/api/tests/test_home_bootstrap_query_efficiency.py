"""【2026-08-05】HomeBootstrapView のクエリ効率の契約テスト。

`GET /api/home/` は **アプリ起動時に必ず 1 回叩かれる**集約エンドポイントで、
最もアクセス頻度が高い。ここが N+1 に退行すると全ユーザーの起動が遅くなる。

にもかかわらず、本テスト追加以前は `assertNumQueries` を使うテストが
コードベース全体で 2 件しかなく (announcement / maintenance)、
**ホームのクエリ数は一切縛られていなかった**。

## 本テストの設計方針

固定値 (`assertNumQueries(N)`) だけで縛ると、正当な機能追加のたびに落ちて
「とりあえず数字を増やす」運用になり、ガードとして機能しなくなる。
そこで **2 層**にする:

  1. `test_baseline_query_count` — 現在のコストを数字として記録する。
     増えたら「意図した増加か」を必ず判断させる (数字を上げる前に考える)。

  2. `test_does_not_scale_with_habits` / `..._with_logs` / `..._with_notifications`
     — **データ件数を増やしてもクエリ数が変わらない**ことを縛る。
     これが本命。N+1 は「件数に比例してクエリが増える」ことなので、
     固定値ではなく **増加しないこと** を直接検査する方が退行を確実に捕まえる。

2 の形にしておくと、機能追加でベースラインが +1 されても
「N+1 かどうか」の判定は独立して生き続ける。

## 実測した内訳 (2026-08-05 時点、習慣 5 件で 27 クエリ)

N+1 は無い (件数を増やしてもクエリ数は不変)。コストは **件数に依らない定数**。
内訳のうち注目すべきもの:

| 対象 | 回数 | 備考 |
|---|---:|---|
| `api_playerprofile` | 3 | #2 get_player / #4 select_for_update 再取得 / #25 |
| `api_habit` | 5 | 本体 1 + Legendary 枠 COUNT + 有効数 COUNT + streak + 集計 |
| `api_habitlog` | 4 | prefetch 1 + 達成数 COUNT + EXP SUM + 日別集計 |
| `api_restday` | 1 | **下記参照** |
| savepoint / release | 4 | `transaction.atomic` 2 ブロック |

`api_restday` について: RestDay を **新規作成する経路は production コードに
存在しない** (FEAT-424 で撤去、`habit_count_service.py:180` に「自動作成
ロジックは撤去済み」と明記)。テーブルは「破壊的データマイグレーション禁止」
方針で既存データ参照用に残置されている **documented residual** であり、
バグではない。ただし 2026-06-11 以降に登録したユーザーは RestDay を 1 件も
持たないため、この SELECT は起動のたびに必ず False を返す。
将来 v1.2+ の cleanup (`rest_day.py` の docstring 参照) で解消できる。
"""
from django.contrib.auth import get_user_model
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.db import connection
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from api.models import FreeMemo, Habit, HabitLog, Notification, PlayerProfile

User = get_user_model()


class HomeBootstrapQueryEfficiencyTest(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(username='homeq', password='pw')
        self.player = PlayerProfile.objects.create(user=self.user, name='HomeQ')
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # 【test_announcement_query_efficiency.py と同じ理由】
        # MaintenanceMiddleware の MaintenanceConfig SELECT は 60s TTL cache 経由
        # (FEAT-471)。先に走ったテストが暖めたかどうかでクエリ数が 1 ぶれるため、
        # ここで明示的に暖めて決定的にする。
        from api.services.maintenance_cache import get_maintenance_config
        get_maintenance_config()

        # 初回リクエストでしか走らない遅延初期化 (PlayerGachaStatus の
        # get_or_create、各種 state の生成等) を先に消化しておく。
        # これをしないと 1 回目と 2 回目でクエリ数が変わり、比較が成立しない。
        self.client.get('/api/home/')

    # ── ヘルパー ─────────────────────────────────────────────────

    def _make_habits(self, n: int, prefix: str):
        for i in range(n):
            Habit.objects.create(player=self.player, name=f'{prefix}-{i}')

    def _home_query_count(self) -> int:
        with CaptureQueriesContext(connection) as ctx:
            res = self.client.get('/api/home/')
        self.assertEqual(res.status_code, 200)
        return len(ctx.captured_queries)

    # ── 1. ベースライン ──────────────────────────────────────────

    def test_baseline_query_count(self):
        """習慣 5 件のときのクエリ数を記録する。

        **この数字が増えたら、増やす前に「意図した増加か」を判断すること。**
        機械的に数字を書き換えると本テストはガードとして死ぬ。

        含まれるもの: token 認証 / player 解決 / I18nMiddleware の
        PlayerSettings / maintenance (cache 済) / 本体の集約クエリ群。
        """
        self._make_habits(5, 'base')

        count = self._home_query_count()

        # 上限として縛る。下振れ (最適化) では落とさない。
        self.assertLessEqual(
            count, 30,
            f'ホーム bootstrap のクエリ数が {count} 件に増えている。'
            'アプリ起動時に必ず叩かれる経路なので、増加が意図的か確認すること。',
        )
        # 数値をテスト出力に残す (次に触る人が現状を把握できるように)
        print(f'\n  [home bootstrap] 習慣 5 件でのクエリ数: {count}')

    # ── 2. N+1 ガード (本命) ─────────────────────────────────────

    def test_does_not_scale_with_habits(self):
        """習慣を 5 → 40 件に増やしてもクエリ数が変わらない。

        habits は HabitSerializer で checklist_items / logs を展開するため、
        prefetch が外れると最も N+1 になりやすい箇所。
        """
        self._make_habits(5, 'few')
        before = self._home_query_count()

        self._make_habits(35, 'many')
        after = self._home_query_count()

        self.assertEqual(
            after, before,
            f'習慣を 5 → 40 件に増やしたらクエリが {before} → {after} 件に増えた。'
            'N+1 が発生している (prefetch_related が外れた可能性)。',
        )

    def test_does_not_scale_with_habit_logs(self):
        """習慣ログを増やしてもクエリ数が変わらない。

        今日の達成状況の集計が per-habit のループになっていないことを縛る。
        """
        self._make_habits(10, 'log')
        before = self._home_query_count()

        today = timezone.localdate()
        for habit in Habit.objects.filter(player=self.player):
            HabitLog.objects.create(habit=habit, date=today, count=1)
        after = self._home_query_count()

        self.assertEqual(
            after, before,
            f'HabitLog を 10 件足したらクエリが {before} → {after} 件に増えた。',
        )

    def test_does_not_scale_with_notifications(self):
        """未読通知が増えてもクエリ数が変わらない (COUNT で完結する)。"""
        before = self._home_query_count()

        for i in range(30):
            Notification.objects.create(
                player=self.player, notif_type='level_up',
                title=f'通知 {i}', body='本文', is_read=False,
            )
        after = self._home_query_count()

        self.assertEqual(
            after, before,
            f'未読通知を 30 件足したらクエリが {before} → {after} 件に増えた。',
        )

    def test_does_not_scale_with_free_memos(self):
        """フリーメモが増えてもクエリ数が変わらない (COUNT で完結する)。"""
        before = self._home_query_count()

        for i in range(30):
            FreeMemo.objects.create(player=self.player, text=f'メモ {i}')
        after = self._home_query_count()

        self.assertEqual(
            after, before,
            f'FreeMemo を 30 件足したらクエリが {before} → {after} 件に増えた。',
        )
