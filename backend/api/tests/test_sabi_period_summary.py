"""【BUG-145】サビのプール選択が `frequency` の期間で達成を数えることを縛る。

## なぜ必要か (実際に起きたこと)

習慣カードの完了表示は `frequency` の期間で判定していた
(`HabitSerializer.get_period_done`、FEAT-520)。一方でサビに渡す summary は
**今日 1 日**の `HabitLog` しか数えていなかった (`today_summary`)。このため

    週次習慣を月曜に達成 → 火曜以降もカードは「完了」
                         → サビは completed=0 を見て `home.none_done` を選ぶ

となり、**同じ習慣をカードは「完了」・サビは「達成ゼロ」と読む**状態だった。

ユーザーは 2026-06-26 にこれに気付き、`home_none_done` プールを admin から
一括無効化して抑えようとしたが、DB が空のプールは YAML にフォールバックする
ため日本語では効かず、**英語だけが日本語に落ちる** 2 次症状を生んだ
(`SabiPoolCoverageGuardTest` がその再発を縛る)。

## 何を縛るか

1. 周期内の達成が `completed` に数えられる (主症状)
2. `get_period_done` と **同じ判定** になる (2 箇所に分かれると必ずずれる)
3. **日次のみのユーザーで挙動が変わらない** (大多数への回帰防止)
4. 日次全達成 + 週次未達成 → `partial` は **仕様として正しい**
   (後日「これもバグでは?」と再議論しないための固定)

実行方法:
```powershell
cd backend; python manage.py test api.tests.test_sabi_period_summary
```
"""
import hashlib
import io
from contextlib import nullcontext as _nullcontext
from datetime import date, timedelta
from unittest.mock import patch

from django.contrib.auth.models import User
from django.core.management import call_command
from django.test import TestCase
from rest_framework.test import APIClient

from api.models import Habit, HabitLog, PlayerProfile, SabiMessage
from api.sabi_loader import _POOL_TO_YAML_PATH, clear_cache
from api.serializers import HabitSerializer
from api.views.sabi import get_sabi_message, period_summary, today_summary

# 2026-08-12 は水曜。その週の月曜は 2026-08-10、月初は 2026-08-01。
WEDNESDAY = date(2026, 8, 12)
MONDAY    = date(2026, 8, 10)
FIRST_OF_MONTH = date(2026, 8, 1)


class _PeriodBase(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(username='bug145', password='p')
        self.player = PlayerProfile.objects.create(user=self.user, name='T', level=10)

    def _habit(self, *, frequency='daily', habit_type='count', name='h'):
        # reset_cycle は frequency 以上でなければならない (serializer の不変条件)。
        return Habit.objects.create(
            player=self.player, name=name, category='運動',
            frequency=frequency, reset_cycle=frequency,
            habit_type=habit_type, difficulty='normal', is_active=True,
        )

    def _log(self, habit, on: date, count=1):
        return HabitLog.objects.create(habit=habit, date=on, count=count, exp_gained=10)

    def _summary(self, **kwargs):
        with patch('api.views.sabi.timezone') as tz:
            tz.localdate.return_value = WEDNESDAY
            return period_summary(self.player, **kwargs)


class PeriodSummaryTest(_PeriodBase):
    """`period_summary` が frequency の期間で達成を数える。"""

    def test_weekly_habit_done_on_monday_counts_on_wednesday(self):
        """主症状。月曜に達成した週次習慣が、水曜でも達成済みとして数えられる。"""
        h = self._habit(frequency='weekly')
        self._log(h, MONDAY)

        self.assertEqual(
            self._summary(), {'completed': 1, 'total': 1},
            '週次習慣を今週すでに達成しているのに未達成と数えられている',
        )

    def test_monthly_habit_done_on_first_counts_mid_month(self):
        """月次習慣も同様に、その月のあいだ達成済みとして数えられる。"""
        h = self._habit(frequency='monthly')
        self._log(h, FIRST_OF_MONTH)

        self.assertEqual(self._summary(), {'completed': 1, 'total': 1})

    def test_weekly_habit_done_last_week_does_not_count(self):
        """先週の達成は今週には持ち越さない (窓の上端が効いていること)。"""
        h = self._habit(frequency='weekly')
        self._log(h, MONDAY - timedelta(days=1))  # 前週の日曜

        self.assertEqual(self._summary(), {'completed': 0, 'total': 1})

    def test_zero_count_log_is_not_counted(self):
        """`count=0` の log は達成ではない (`get_period_done` と同条件)。"""
        h = self._habit(frequency='weekly')
        self._log(h, MONDAY, count=0)

        self.assertEqual(self._summary(), {'completed': 0, 'total': 1})

    def test_multiple_logs_in_period_count_habit_once(self):
        """同じ習慣を期間内に複数回やっても 1 件として数える (distinct)。"""
        h = self._habit(frequency='weekly')
        self._log(h, MONDAY)
        self._log(h, MONDAY + timedelta(days=1))

        self.assertEqual(self._summary(), {'completed': 1, 'total': 1})

    def test_inactive_habit_excluded_from_both_sides(self):
        """無効化した習慣は分母にも分子にも入らない。"""
        h = self._habit(frequency='weekly')
        self._log(h, MONDAY)
        h.is_active = False
        h.save(update_fields=['is_active'])

        self.assertEqual(self._summary(), {'completed': 0, 'total': 0})

    def test_total_can_be_passed_in(self):
        """呼び出し側が数え済みの total を渡せる (ホーム bootstrap の重複クエリ回避)。"""
        self._habit(frequency='weekly')

        self.assertEqual(self._summary(total=99)['total'], 99)


class TodoBucketTest(_PeriodBase):
    """ToDo は `frequency` に関わらず daily 窓 (`get_period_done` と同じ扱い)。"""

    def test_todo_done_on_monday_does_not_count_on_wednesday(self):
        """ToDo は単発タスクなので、月曜の達成を水曜に持ち越さない。"""
        h = self._habit(frequency='weekly', habit_type='todo')
        self._log(h, MONDAY)

        self.assertEqual(self._summary(), {'completed': 0, 'total': 1})

    def test_todo_is_not_double_counted(self):
        """`habit_type='todo'` かつ `frequency='weekly'` が二重計上されない。

        daily バケットは `todo または frequency='daily'`、weekly / monthly バケットは
        `todo でない かつ frequency=...` で相互排他にしている。この排他が崩れると
        completed が total を超える。
        """
        h = self._habit(frequency='weekly', habit_type='todo')
        self._log(h, WEDNESDAY)

        summary = self._summary()
        self.assertEqual(summary, {'completed': 1, 'total': 1})
        self.assertLessEqual(
            summary['completed'], summary['total'],
            'completed が total を超えている = バケットが二重計上している',
        )


class BucketExclusivityTest(_PeriodBase):
    """【2026-08-16 機能レビュー P2】バケットの相互排他性を docstring からテストへ移す。

    `period_summary` は 4 つの `Q` を OR して 1 クエリで数える。この 4 つが
    相互排他でないと、`distinct()` が効いていても **同じ習慣が別々の条件で
    ヒットして** 二重計上される。「排他である」は実装の主張なので、
    主張のままにせず assert する。
    """

    COMBOS = [
        (habit_type, frequency)
        for habit_type in ('count', 'checklist', 'todo')
        for frequency in ('daily', 'weekly', 'monthly')
    ]

    def _done_on(self, habit_type: str, frequency: str) -> date:
        # ToDo は frequency に関わらず daily 窓なので今日でないと入らない。
        if habit_type == 'todo':
            return WEDNESDAY
        return {'daily': WEDNESDAY, 'weekly': MONDAY, 'monthly': FIRST_OF_MONTH}[frequency]

    def test_buckets_are_mutually_exclusive_and_total(self):
        """全 9 通りを期間内に達成 → completed == total（二重計上ゼロ）。"""
        for habit_type, frequency in self.COMBOS:
            h = self._habit(frequency=frequency, habit_type=habit_type,
                            name=f'{habit_type}_{frequency}')
            self._log(h, self._done_on(habit_type, frequency))

        summary = self._summary()
        self.assertEqual(
            summary, {'completed': len(self.COMBOS), 'total': len(self.COMBOS)},
            'バケットが相互排他でない (completed が total とずれている)',
        )

    def test_buckets_cover_every_combination(self):
        """全 9 通りを 1 件ずつ単独で数えて、どれも漏れなく 1 と数えられる。

        排他性 (二重計上しない) と網羅性 (取りこぼさない) は別の性質なので、
        上のテストとは別に確かめる。
        """
        for habit_type, frequency in self.COMBOS:
            with self.subTest(habit_type=habit_type, frequency=frequency):
                Habit.objects.filter(player=self.player).delete()
                h = self._habit(frequency=frequency, habit_type=habit_type)
                self._log(h, self._done_on(habit_type, frequency))

                self.assertEqual(
                    self._summary(), {'completed': 1, 'total': 1},
                    f'{habit_type} × {frequency} がどのバケットにも入っていない',
                )

    def test_nothing_done_counts_zero_for_every_combination(self):
        """逆方向。未達成なら 9 件とも 0 (条件が緩すぎて拾っていない)。"""
        for habit_type, frequency in self.COMBOS:
            self._habit(frequency=frequency, habit_type=habit_type,
                        name=f'{habit_type}_{frequency}')

        self.assertEqual(self._summary(), {'completed': 0, 'total': len(self.COMBOS)})


class MatchesCardDisplayTest(_PeriodBase):
    """カードの完了表示 (`period_done`) とサビの判定が一致する。"""

    def test_period_done_true_implies_counted_as_completed(self):
        """カードが「完了」なら、サビも達成済みとして数える。

        本 BUG の本体。この 2 つがずれていたことが原因だった。
        """
        for freq, done_on in (('daily', WEDNESDAY),
                              ('weekly', MONDAY),
                              ('monthly', FIRST_OF_MONTH)):
            with self.subTest(frequency=freq):
                Habit.objects.filter(player=self.player).delete()
                h = self._habit(frequency=freq, name=f'h_{freq}')
                self._log(h, done_on)

                with patch('api.serializers.timezone') as tz:
                    tz.localdate.return_value = WEDNESDAY
                    card_done = HabitSerializer(h).data['period_done']

                self.assertTrue(card_done, f'前提: {freq} のカードは完了表示のはず')
                self.assertEqual(
                    self._summary()['completed'], 1,
                    f'カードは「完了」なのにサビは未達成と数えている ({freq})',
                )


class DailyOnlyRegressionTest(_PeriodBase):
    """日次のみのユーザー (大多数) で挙動が変わらない。"""

    def test_matches_today_summary_for_daily_only(self):
        a, b = self._habit(name='a'), self._habit(name='b')
        self._log(a, WEDNESDAY)

        with patch('api.views.sabi.timezone') as tz:
            tz.localdate.return_value = WEDNESDAY
            legacy = today_summary(self.player)
            new    = period_summary(self.player)

        self.assertEqual(
            (new['completed'], new['total']),
            (legacy['completed'], legacy['total']),
            '日次のみのユーザーで today_summary と食い違っている',
        )
        self.assertEqual(new, {'completed': 1, 'total': 2})
        del b  # 未達成側 (分母にだけ効く)


class PoolSelectionTest(_PeriodBase):
    """`get_sabi_message` が選ぶプールが変わることまで縛る。"""

    def _pool_of(self, message: str) -> str:
        from api.sabi_loader import load_sabi_dialogue
        for key, values in load_sabi_dialogue()['home'].items():
            if message in values:
                return key
        return '?'

    def _message(self, summary):
        with patch('api.views.sabi.timezone') as tz:
            tz.localdate.return_value = WEDNESDAY
            return get_sabi_message(self.player, summary)

    def test_weekly_done_selects_all_done_not_none_done(self):
        """週次習慣を今週達成済みなら「達成ゼロ」ではなくなる。"""
        h = self._habit(frequency='weekly')
        self._log(h, MONDAY)

        pool = self._pool_of(self._message(self._summary()))
        self.assertNotEqual(
            pool, 'none_done',
            '達成済みなのに「達成ゼロ」プールが選ばれている (本 BUG の症状)',
        )
        # level=10 かつ pun/knowledge は seed 依存なので all_done 固定はしない。
        self.assertIn(pool, {'all_done', 'pun', 'knowledge_general'})

    def test_daily_done_weekly_not_done_is_partial(self):
        """日次を全部やっても週次が未達成なら `partial`。

        **これは仕様として正しい** (週次がまだ残っている)。後日「これもバグでは?」
        と再議論しないために固定する。Pre-mortem シナリオ 1。
        """
        daily = self._habit(frequency='daily', name='d')
        self._habit(frequency='weekly', name='w')  # 未達成
        self._log(daily, WEDNESDAY)

        summary = self._summary()
        self.assertEqual(summary, {'completed': 1, 'total': 2})
        self.assertEqual(self._pool_of(self._message(summary)), 'partial')


class ViewsUsePeriodSummaryTest(_PeriodBase):
    """view が実際に `period_summary` を通っていることを縛る。

    `period_summary` の単体テストだけでは、**呼び出し側を `today_summary` に
    戻しても全部緑のまま**になる。ホーム bootstrap と `/api/sabi/message/` の
    2 経路を実際に叩いて、達成済みのときに「達成ゼロ」プールが返らないことを
    確認する。

    日付は `django.utils.timezone.localdate` を 1 箇所で固定する
    (views.home / views.sabi / serializers がすべて同じ関数を見ているため)。
    """

    def setUp(self):
        super().setUp()
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)
        clear_cache()
        self.addCleanup(clear_cache)

    def _none_done_lines(self) -> set:
        from api.sabi_loader import load_sabi_dialogue
        return set(load_sabi_dialogue()['home']['none_done'])

    def _is_knowledge_day(self) -> bool:
        """この player / 日付で `knowledge_general` が `none_done` を**上書きする**か。

        🔴 【2026-08-29 CI で実際に踏んだ】`get_sabi_message` は

            seed = md5(f"{player.id}{localdate()}{nonce}")
            is_knowledge_day = (seed % 7 == 0) and total > 0

        で ~14% の確率でプールごと差し替える (`views/sabi.py`)。
        日付は固定してあるが **`player.id` はテストの実行順で動く** ——
        別のテストファイルが user を増やすと id がずれ、この 1 本だけが
        「知識プールが返ってきた」で落ちる。実際 FEAT-535 で 26 件足したときに
        CI (Postgres、sequence は rollback されない) で発火した。

        ローカル (SQLite) では id が小さく踏まなかったため **CI だけ赤**になる。
        テスト側で同じ式を持って分岐し、実行順に依存しない形にする。

        ⚠️ level override (`>= 30` / `< 5`) は `_PeriodBase` が level=10 で
        作るので発火しない。ここでは考慮不要。
        """
        seed_str = f'{self.player.id}{WEDNESDAY}'
        return int(hashlib.md5(seed_str.encode()).hexdigest(), 16) % 7 == 0

    def _expected_none_done_pool(self):
        """(期待するプール, 名前)。知識の日は knowledge_general が正解になる。"""
        from api.sabi_loader import load_sabi_dialogue
        if self._is_knowledge_day():
            return (set(load_sabi_dialogue()['home']['knowledge_general']),
                    'knowledge_general (seed % 7 == 0 の日)')
        return (self._none_done_lines(), 'none_done')

    def test_home_bootstrap_does_not_return_none_done_when_weekly_is_done(self):
        h = self._habit(frequency='weekly')
        self._log(h, MONDAY)

        with patch('django.utils.timezone.localdate', return_value=WEDNESDAY):
            res = self.client.get('/api/home/', {'time_segment': 'morning'})

        self.assertEqual(res.status_code, 200)
        message = res.data['sabi_message']['message']
        # _apply_greeting が挨拶を前置するため、末尾行だけを取り出して照合する。
        body = message.split('\n')[-1]
        self.assertNotIn(
            body, self._none_done_lines(),
            'ホーム bootstrap が今日 1 日基準のまま (period_summary を通っていない)',
        )

    def test_sabi_message_endpoint_does_not_return_none_done_when_weekly_is_done(self):
        h = self._habit(frequency='weekly')
        self._log(h, MONDAY)

        with patch('django.utils.timezone.localdate', return_value=WEDNESDAY):
            res = self.client.get('/api/sabi/message/', {'time_segment': 'morning'})

        self.assertEqual(res.status_code, 200)
        body = res.data['message'].split('\n')[-1]
        self.assertNotIn(
            body, self._none_done_lines(),
            '/api/sabi/message/ が今日 1 日基準のまま (period_summary を通っていない)',
        )

    def test_home_bootstrap_still_returns_none_done_when_nothing_is_done(self):
        """逆方向。本当に未達成なら「達成ゼロ」が返る (無条件に消していない)。"""
        self._habit(frequency='weekly')  # log なし

        with patch('django.utils.timezone.localdate', return_value=WEDNESDAY):
            res = self.client.get('/api/home/', {'time_segment': 'morning'})

        body = res.data['sabi_message']['message'].split('\n')[-1]
        expected, name = self._expected_none_done_pool()
        self.assertIn(
            body, expected,
            f'未達成なのに {name} プールが選ばれていない',
        )
        # プールが入れ替わっても「達成した側」に落ちていないことは常に見る
        # (BUG-145 の症状はこちら)。
        from api.sabi_loader import load_sabi_dialogue
        dlg = load_sabi_dialogue()['home']
        self.assertNotIn(
            body, set(dlg['all_done']) | set(dlg['partial']),
            '未達成なのに達成側のプールが選ばれている (BUG-145 の症状)',
        )


class SabiPoolCoverageGuardTest(TestCase):
    """【BUG-145 Phase 3】プール暗転を `check_i18n_coverage` が検出する。

    `_en` の空欄率だけを見ていた旧実装では、`home_none_done` が丸ごと
    `is_active=False` でも **SabiMessage 100% filled** と報告されていた。
    """

    # 【重要】テスト DB には migration が master data を seed するが `_en` は空なので、
    # `--fail-on-empty` は **プールが健全でも常に exit 1** になる。素直に
    # `assertEqual(code, 1)` と書くと、**プール検査が無くても緑になる**
    # (= ガードを外しても気付けない) 偽陽性テストになる。
    #
    # そこで `i18n_targets` を空にして `_en` 空欄チェックを黙らせ、
    # **プール検査だけが exit code を決める**状態で配線を確かめる。
    def _run(self, *, isolate_pools=False):
        buf = io.StringIO()
        ctx = (patch('api.management.commands.check_i18n_coverage.i18n_targets',
                     return_value=[])
               if isolate_pools else _nullcontext())
        try:
            with ctx:
                call_command('check_i18n_coverage', '--fail-on-empty', stdout=buf)
            return 0, buf.getvalue()
        except SystemExit as e:
            return e.code, buf.getvalue()

    def setUp(self):
        clear_cache()
        self.addCleanup(clear_cache)
        # 全プールに 1 件ずつ、英訳込みで用意する。
        for pool in _POOL_TO_YAML_PATH:
            SabiMessage.objects.create(
                pool=pool, content=f'{pool} の台詞ですね。',
                content_en=f'A line for {pool}.', is_active=True,
            )

    def test_healthy_when_every_pool_has_an_active_row(self):
        _, out = self._run()
        self.assertIn(f'{len(_POOL_TO_YAML_PATH)} プールすべてに有効な行あり', out)
        self.assertNotIn('有効な行が 0 件のプール', out)

    def test_detects_pool_with_all_rows_inactive(self):
        """2026-06-26 に実際に起きた状態 (9 行すべて OFF) を検出する。"""
        SabiMessage.objects.filter(pool='home_none_done').update(is_active=False)

        _, out = self._run()
        self.assertIn('有効な行が 0 件のプール', out)
        self.assertIn('home_none_done', out)
        self.assertIn('is_active=False', out, '原因 (無効化 or 行なし) が出ていない')

    def test_detects_pool_with_no_rows_at_all(self):
        SabiMessage.objects.filter(pool='context_undo').delete()

        _, out = self._run()
        self.assertIn('context_undo', out)
        self.assertIn('レコード自体が存在しない', out)

    def test_dark_pool_alone_drives_the_exit_code(self):
        """プール暗転**だけ**で `--fail-on-empty` が exit 1 になる。

        これがガードと gate の配線を縛る本体。`_en` 空欄チェックを黙らせた
        状態で、健全なら 0 / 暗転させたら 1 になることを両方向で確認する。
        """
        code, _ = self._run(isolate_pools=True)
        self.assertEqual(code, 0, '健全なのに落ちている')

        SabiMessage.objects.filter(pool='home_none_done').update(is_active=False)

        code, _ = self._run(isolate_pools=True)
        self.assertEqual(code, 1, 'プール暗転が --fail-on-empty に届いていない')

    def test_skips_when_no_records(self):
        """seed されていない環境ではプール検査自体を行わない。

        「レコードが無いだけ」で CI を赤くしないための逃げ道
        (指示書 Pre-mortem シナリオ 5)。
        """
        SabiMessage.objects.all().delete()

        code, out = self._run(isolate_pools=True)
        self.assertIn('(no records)', out)
        self.assertEqual(code, 0, 'レコード 0 件で落ちてはいけない')
