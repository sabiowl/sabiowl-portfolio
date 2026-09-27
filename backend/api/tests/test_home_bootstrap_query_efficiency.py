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

## 【2026-08-16 機能レビュー P1】測っていた URL が実路ではなかった

本テストは `GET /api/home/` を測っていたが、**実アプリは必ず
`GET /api/home/?time_segment=<segment>` を叩く**
(`home_bootstrap_provider.dart:90`)。`home.py:201` の `if time_segment:` の中で
`period_summary()` と `_load_dialogue()` が走るため、**この分岐が丸ごと
測定外**だった。現に BUG-145 で +3 クエリが入っても何も鳴らなかった。

契約テスト (`test_home_bootstrap_sabi.py`) は `?time_segment=` の有無を
きちんと叩き分けていたので、パラメータの存在を忘れていたわけではない。
**「契約は両方の形で、効率は非実路の形だけで」測っていた**という
取り合わせの問題だった。→ `_home_query_count` を実路に向けた。

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

    # 【2026-08-16 機能レビュー P1】実アプリは **必ず `?time_segment=` を付けて**
    # 叩く (`home_bootstrap_provider.dart:90` の `ref.read(timeSegmentProvider)` は
    # 常に有効な segment を返し、`fetchHomeBootstrap` が非空なら必ず query に載せる)。
    #
    # 旧実装は `GET /api/home/` を測っていたため、`home.py:201` の `if time_segment:`
    # 分岐 —— period_summary / locale 解決 / サビ台詞プールの DB 読み —— が
    # **丸ごと測定外**だった。実測 (習慣 5 件):
    #
    #     GET /api/home/                      = 26 クエリ  ← 旧テストが測っていた
    #     GET /api/home/?time_segment=morning = 30 クエリ  ← アプリが叩く形
    #
    # 現に BUG-145 (2026-08-16) で period_summary の 3 本が入ったが、
    # **測定外だったので何も鳴らなかった**。
    DEFAULT_PARAMS = {'time_segment': 'morning'}

    def _home_query_count(self, params: dict | None = None) -> int:
        with CaptureQueriesContext(connection) as ctx:
            res = self.client.get('/api/home/',
                                  self.DEFAULT_PARAMS if params is None else params)
        self.assertEqual(res.status_code, 200)
        return len(ctx.captured_queries)

    # ── 0. 測定対象そのもののガード ───────────────────────────────

    def test_measures_the_sabi_message_branch(self):
        """**測っている URL が実路であること**を縛る。

        本テストの上限を守っているかどうかは、`_home_query_count` が
        どの URL を叩くかで決まる。**その選択自体は、他のどのテストも
        縛っていなかった** —— だから `?time_segment=` 無しを測っていた間、
        `home.py:201` の分岐が丸ごと測定外なのに全部緑だった。

        「`time_segment` を渡している」と直接書くと、キー名を変えただけで
        素通りする。そこで **測定値に分岐のコストが実際に含まれているか**
        を見る: 分岐を通る形と通らない形でクエリ数が違うことを確かめる。

        (負の検証: `DEFAULT_PARAMS` を `{}` に戻すと両者が一致して赤くなる)
        """
        self._make_habits(5, 'branch')

        with_branch = self._home_query_count()
        without_branch = self._home_query_count({})

        self.assertGreater(
            with_branch, without_branch,
            f'測定対象が sabi_message 分岐を含んでいない '
            f'(実路 {with_branch} / 非実路 {without_branch})。'
            '_home_query_count が実アプリの叩き方 (?time_segment=) を'
            '再現しているか確認すること',
        )

    # ── 1. ベースライン ──────────────────────────────────────────

    def test_baseline_query_count(self):
        """習慣 5 件のときのクエリ数を記録する。

        **この数字が増えたら、増やす前に「意図した増加か」を判断すること。**
        機械的に数字を書き換えると本テストはガードとして死ぬ。

        含まれるもの: token 認証 / player 解決 / I18nMiddleware の
        PlayerSettings / maintenance (cache 済) / 本体の集約クエリ群 /
        **sabi_message 分岐** (`?time_segment=` 付きで測るようになったため)。

        ## 上限 30 → 32 に引き上げた理由 (2026-08-16)

        **数字だけを黙って書き換えていない。** 内訳は以下のとおり:

        | | クエリ数 | 出来事 |
        |---|---:|---|
        | 旧測定 (`?time_segment=` なし) | 26 | sabi_message 分岐が測定外だった |
        | 実路の測定に変更 | **33** | +7 = period_summary 3 + locale 1 + サビ台詞プール 1 + ほか 2 |
        | `period_summary` を OR 1 本に畳む | **31** | -2 |

        +5 は **BUG-145 (サビが週次・月次の達成を見落とす) を直すために必要な
        コスト**で、支払う価値がある。問題は「支払ったことに誰も気づけなかった」
        ことで、それは測る URL を実路に向けたことで解消した。上限は現状 31 に
        対して +1 の余裕を持たせて **32** とする。
        """
        self._make_habits(5, 'base')

        count = self._home_query_count()

        # 上限として縛る。下振れ (最適化) では落とさない。
        self.assertLessEqual(
            count, 32,
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
