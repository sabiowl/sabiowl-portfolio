"""【FEAT-539 (2026-09-05)】連続達成日数 / 累計達成日数の契約テスト。

## このファイルが守るもの

| # | 縛り | なぜ |
|---|---|---|
| §1 | 連続が 1 → 2 → 3 と伸び、**1 日空けたら 1 に戻る** | 本 FEAT の中身そのもの |
| §2 | 昨日が `RestDay` なら**継続する** | 決定 5。既存の習慣ストリークと定義を揃える |
| §3 | **タイムラインだけ達成した日**も 1 日として数える | 案 C が失格だった理由 |
| §4 | 同日 2 回目で**行が増えない / 数字が動かない** | 冪等 |
| §5 | `best_task_streak_days` が更新され、かつ**減らない** | 決定 4 / Pre-mortem 9 |
| §6 | 🔴 **`update_fields` の入れ忘れ** —— DB から読み直して確認する | FEAT-537 の `free_memo` |
| §7 | **既存キーが 1 つも変わっていない** | `days_count` に報酬 tier が依存 |
| §8 | backfill が**冪等**、かつ**直後の照合が 0 件** | Phase 2/3/4 が同じ関数を共有している証拠 |
| §9 | 壊した `login_streak_days` を照合コマンドが **exit 1 で検出**する | Phase 4 |

## 🔴 §1 が「わざと 2 日空ける」ケースを持っている理由

`had_yesterday` の判定は、`date__gte=yesterday` のように書き間違えても
**大半のケースで緑のまま通る**。連続で達成している限り、昨日の行は
「昨日以降」にも「昨日ちょうど」にも含まれるからである。
**2 日空けたときだけ**、`date__gte` は今日の行を拾って「継続」と誤判定する。

したがって `test_gap_of_two_days_resets_streak` は
「1 日空ける」ではなく **2 日空ける**ケースでなければ意味がない。
"""

from datetime import date, timedelta
from io import StringIO

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone

from api.models import (
    DailyAchievement, Habit, HabitLog, PlayerProfile, RestDay, TimelineEvent,
)
from api.services.daily_achievement import recompute_from_rows
from api.services.diamond_service import award_daily_first_task_bonus

User = get_user_model()

# 基準日は**登録日から 30 日後**に置く。
#
# ⚠️ 固定日 (`date(2026, 6, 1)` 等) を使うと `created_at` (= テスト実行時刻) より
#    過去になり、`days_count < 1` の early-return (Pre-mortem S2) に吸われて
#    **award が丸ごと None を返す**。最初にこれを踏んだ。
# 🔵 30 日後にすることで Day 8+ tier (+20💎) に落ち、Day 1 special
#    (チケット付与) の分岐を踏まずに連続日数だけを見られる。
BASE_OFFSET_DAYS = 30


class _StreakTestBase(TestCase):
    def setUp(self):
        self.user = User.objects.create_user('p1', email='p1@example.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='Player1', diamonds=0, diamonds_total=0,
        )
        # 🔴 JST の登録日。`created_at.date()` (UTC) を使うと JST 00:00〜09:00 の
        #    実行で 1 日ズレる (BUG-130 と同じ罠)。
        self.registered = timezone.localtime(self.player.created_at).date()
        self.base = self.registered + timedelta(days=BASE_OFFSET_DAYS)

    def day(self, offset: int = 0) -> date:
        return self.base + timedelta(days=offset)

    def award(self, day: date) -> dict | None:
        """その日の初回タスク達成ボーナスを発火させる。"""
        return award_daily_first_task_bonus(self.player, day)

    def reread_streak(self):
        """🔴 DB から読み直す。インスタンス上の値を見ると `update_fields` の
        入れ忘れを見逃す (FEAT-537 の `free_memo` と同じ見逃し方)。"""
        return PlayerProfile.objects.get(pk=self.player.pk).streak


# ──────────────────────────────────────────────────────────────────────────
# §1 連続が伸びる / 途切れる
# ──────────────────────────────────────────────────────────────────────────
class StreakAccumulationTest(_StreakTestBase):

    def test_consecutive_days_count_up(self):
        """連続で達成すると 1 → 2 → 3 と伸びる。"""
        for offset, expected in ((0, 1), (1, 2), (2, 3)):
            result = self.award(self.day() + timedelta(days=offset))
            self.assertIsNotNone(result)
            self.assertEqual(result['streak_days'], expected)
            self.assertEqual(result['total_days'], offset + 1)

    def test_gap_of_two_days_resets_streak(self):
        """🔴 **2 日空けたら 1 に戻る。**

        1 日だけ空けるケースでは `date__gte=yesterday` のような書き間違いでも
        緑のまま通ってしまうので、ここは必ず 2 日空ける (ファイル冒頭の注記)。
        """
        self.award(self.day())                          # 連続 1
        self.award(self.day(1))      # 連続 2
        # 2 日空ける (self.day()+2 と self.day()+3 は達成しない)
        result = self.award(self.day(4))
        self.assertEqual(result['streak_days'], 1)
        # 累計は消えない —— これが「途切れた翌日は累計だけ出す」の根拠になる
        self.assertEqual(result['total_days'], 3)

    def test_gap_of_one_day_also_resets_streak(self):
        """1 日空けても当然リセットされる。"""
        self.award(self.day())
        result = self.award(self.day(2))
        self.assertEqual(result['streak_days'], 1)
        self.assertEqual(result['total_days'], 2)


# ──────────────────────────────────────────────────────────────────────────
# §2 休息日は連続をつなぐ (決定 5)
# ──────────────────────────────────────────────────────────────────────────
class RestDayBridgesStreakTest(_StreakTestBase):

    def test_rest_day_yesterday_continues_streak(self):
        """昨日が `RestDay` なら連続は続く (既存の習慣ストリークと同じ扱い)。"""
        self.award(self.day())                                    # 連続 1
        RestDay.objects.create(player=self.player, date=self.day(1))
        result = self.award(self.day(2))
        self.assertEqual(result['streak_days'], 2)
        # 🔵 休息日は**つなぐが伸ばさない**。累計は達成日だけを数える。
        self.assertEqual(result['total_days'], 2)

    def test_two_rest_days_still_bridge(self):
        """休息日が 2 日続いても橋渡しは成立する。"""
        self.award(self.day())
        for offset in (1, 2):
            RestDay.objects.create(
                player=self.player, date=self.day() + timedelta(days=offset),
            )
        result = self.award(self.day(3))
        self.assertEqual(result['streak_days'], 2)

    def test_rest_day_then_gap_still_resets(self):
        """🔴 **休息日で 1 日だけ橋を架けても、その先が空いていれば切れる。**

        達成 (day0) → 休息 (day1) → **何も無い (day2)** → 達成 (day3)。

        これは「1 日空ける」テストでは絶対に踏めない形である。
        全走査側 (`recompute_from_rows`) で**隙間の先頭 1 日しか見ない**
        書き方をすると、day1 の休息日を見た時点で「つながった」と判断し、
        差分更新側 (連続 1) と食い違う —— **照合は通らないが、
        1 日空けるテストだけなら緑のまま通る**。
        """
        self.award(self.day())
        RestDay.objects.create(player=self.player, date=self.day(1))
        result = self.award(self.day(3))
        self.assertEqual(result['streak_days'], 1)          # 差分更新
        snapshot = recompute_from_rows(self.player)
        self.assertEqual(snapshot.streak_days, 1)           # 全走査
        self.assertEqual(snapshot.total_days, 2)

    def test_recompute_agrees_with_incremental_across_rest_day(self):
        """🔴 差分更新 (Phase 2) と全走査 (Phase 3/4) が休息日を挟んでも一致する。

        ここがズレると「照合は通るのに実態が違う」の入り口になる。
        """
        self.award(self.day())
        RestDay.objects.create(player=self.player, date=self.day(1))
        result = self.award(self.day(2))
        snapshot = recompute_from_rows(self.player)
        self.assertEqual(snapshot.streak_days, result['streak_days'])
        self.assertEqual(snapshot.total_days, result['total_days'])


# ──────────────────────────────────────────────────────────────────────────
# §3 タイムラインだけの日も数える (案 C 失格の理由)
# ──────────────────────────────────────────────────────────────────────────
class TimelineOnlyDayCountsTest(_StreakTestBase):

    def test_timeline_only_day_is_counted(self):
        """`HabitLog` が 1 件も無い日でも、発火点を通れば 1 日として数える。

        タイムライン予定の完了は `HabitLog` を作らない。`HabitLog` から
        数える実装 (案 C) だと**ボーナスは出たのに日数が増えない日**ができる。
        """
        result = self.award(self.day())
        self.assertEqual(result['total_days'], 1)
        self.assertEqual(
            HabitLog.objects.filter(habit__player=self.player).count(), 0,
        )
        self.assertTrue(
            DailyAchievement.objects.filter(player=self.player, date=self.day()).exists()
        )


# ──────────────────────────────────────────────────────────────────────────
# §4 冪等
# ──────────────────────────────────────────────────────────────────────────
class SameDayIdempotencyTest(_StreakTestBase):

    def test_second_award_same_day_is_noop(self):
        """同日 2 回目は None を返し、行も数字も動かない。"""
        first = self.award(self.day())
        self.assertIsNotNone(first)
        second = self.award(self.day())
        self.assertIsNone(second)
        self.assertEqual(
            DailyAchievement.objects.filter(player=self.player).count(), 1,
        )
        self.assertEqual(self.reread_streak().login_streak_days, 1)


# ──────────────────────────────────────────────────────────────────────────
# §5 best_task_streak_days (決定 4 / Pre-mortem 9)
# ──────────────────────────────────────────────────────────────────────────
class BestStreakTest(_StreakTestBase):

    def test_best_streak_is_written_even_though_not_displayed(self):
        """v1.1.2 では表示しないが、**書き込みはする**。

        表示しないからと省くと `login_streak_days` が §2 で陥っていた
        「誰も更新しない field」がもう 1 本増える。
        """
        self.award(self.day())
        self.award(self.day(1))
        self.assertEqual(self.reread_streak().best_task_streak_days, 2)

    def test_best_streak_never_decreases(self):
        """連続が途切れても最長記録は減らない (`max` であること)。"""
        for offset in range(3):                     # 3 日連続 → best = 3
            self.award(self.day() + timedelta(days=offset))
        self.assertEqual(self.reread_streak().best_task_streak_days, 3)

        result = self.award(self.day(10))   # 途切れる
        self.assertEqual(result['streak_days'], 1)
        streak = self.reread_streak()
        self.assertEqual(streak.login_streak_days, 1)
        self.assertEqual(streak.best_task_streak_days, 3)    # 減らない


# ──────────────────────────────────────────────────────────────────────────
# §6 🔴 update_fields の入れ忘れ (FEAT-537 の再発防止)
# ──────────────────────────────────────────────────────────────────────────
class UpdateFieldsPersistenceTest(_StreakTestBase):
    """`save(update_fields=[...])` に field を入れ忘れると**黙って保存されない**。

    インスタンス上の値だけ見ると気付けないので、**必ず DB から読み直す**。
    FEAT-537 の `free_memo` はこの形で 1 経路だけ 0pt になっていた。
    """

    def test_streak_days_survive_a_reread_from_db(self):
        self.award(self.day())
        self.award(self.day(1))
        streak = self.reread_streak()
        self.assertEqual(streak.login_streak_days, 2)
        self.assertEqual(streak.best_task_streak_days, 2)
        # 既存 field も引き続き保存されている (追加で壊していないこと)
        self.assertEqual(streak.last_login_diamond_at, self.day(1))


# ──────────────────────────────────────────────────────────────────────────
# §7 既存キーを変えていない
# ──────────────────────────────────────────────────────────────────────────
class ExistingKeysUnchangedTest(_StreakTestBase):
    """⚠️ `days_count` は「登録日からの経過日数」のまま。

    報酬 tier の判定と、Mobile 側のカレンダー登録日算出
    (`todayOnly - (daysCount - 1)`) が依存している。**追加であって置換ではない**。
    """

    def test_day_1_keys_are_untouched(self):
        result = award_daily_first_task_bonus(self.player, self.registered)
        self.assertEqual(result['days_count'], 1)
        self.assertEqual(result['amount'], 500)
        self.assertEqual(result['granted_daily_tickets'], 3)
        self.assertEqual(result['granted_weekly_tickets'], 3)

    def test_days_count_is_elapsed_days_not_achievement_days(self):
        """🔴 `days_count` と `total_days` は**別物**である。

        1 日も達成していなくても `days_count` は増える。
        ユーザーに見せる「何日目か」は `total_days` の方。
        """
        result = award_daily_first_task_bonus(
            self.player, self.registered + timedelta(days=29),
        )
        self.assertEqual(result['days_count'], 30)   # 登録から 30 日目
        self.assertEqual(result['total_days'], 1)    # 達成したのは今日が初めて


# ──────────────────────────────────────────────────────────────────────────
# §8 backfill (Phase 3) と照合 (Phase 4) が同じ関数を共有している
# ──────────────────────────────────────────────────────────────────────────
class BackfillCommandTest(_StreakTestBase):

    def setUp(self):
        super().setUp()
        self.habit = Habit.objects.create(
            player=self.player, name='走る', category='運動',
        )
        # HabitLog 由来 3 日 (連続)
        for offset in range(3):
            HabitLog.objects.create(
                habit=self.habit, date=self.day() + timedelta(days=offset), count=1,
            )
        # TimelineEvent 由来 1 日 (HabitLog が無い日) —— 案 C なら落ちる日
        TimelineEvent.objects.create(
            player=self.player, title='通院',
            date=self.day(3), is_completed=True,
        )
        # 🔴 休息日を 1 日挟んだうえで、その先も達成している。
        #    backfill 側が「達成日だけ」で数える独自実装だとここで切れてしまい、
        #    `recompute_from_rows()` を使う照合コマンドと食い違う。
        #    **Phase 3 と Phase 4 が同じ関数を共有しているかを分ける形**である。
        RestDay.objects.create(player=self.player, date=self.day(4))
        HabitLog.objects.create(habit=self.habit, date=self.day(5), count=1)
        # 未完了の予定は数えない
        TimelineEvent.objects.create(
            player=self.player, title='未完了',
            date=self.day(9), is_completed=False,
        )

    def _run(self, *args):
        out = StringIO()
        call_command('backfill_daily_achievements', *args, stdout=out)
        return out.getvalue()

    def test_dry_run_does_not_write(self):
        output = self._run()
        self.assertIn('dry-run', output)
        self.assertEqual(DailyAchievement.objects.count(), 0)

    def test_apply_creates_rows_from_both_sources(self):
        self._run('--apply')
        dates = set(
            DailyAchievement.objects.filter(player=self.player)
            .values_list('date', flat=True)
        )
        # day0-2 = HabitLog / day3 = TimelineEvent / day5 = HabitLog
        # day4 は休息日なので**行は作らない** (つなぐが伸ばさない)
        self.assertEqual(dates, {self.day(n) for n in (0, 1, 2, 3, 5)})
        streak = self.reread_streak()
        self.assertEqual(streak.login_streak_days, 5)
        self.assertEqual(streak.best_task_streak_days, 5)

    def test_apply_is_idempotent(self):
        self._run('--apply')
        before = DailyAchievement.objects.count()
        self._run('--apply')
        self.assertEqual(DailyAchievement.objects.count(), before)

    def test_backfill_then_check_reports_zero(self):
        """🔴 backfill 直後の照合は **0 件**でなければならない。

        Phase 3 と Phase 4 が同じ `recompute_from_rows()` を呼んでいれば
        構造的に必ず通る。**通らなければ、再計算がもう 1 箇所に
        別々に書かれている証拠**である。
        """
        self._run('--apply')
        out = StringIO()
        call_command('check_daily_achievement_consistency', stdout=out)
        self.assertIn('不一致            : 0', out.getvalue())


# ──────────────────────────────────────────────────────────────────────────
# §8.5 運用コマンドの出力が Windows のコンソールで落ちない
# ──────────────────────────────────────────────────────────────────────────
class CommandOutputIsConsoleSafeTest(_StreakTestBase):
    """🔴 コマンドの stdout に絵文字を入れると Windows で落ちる。

    実際に踏んだ: `backfill_daily_achievements` の出力に ⚠️ を入れていたところ、
    Windows の cp932 コンソールで `UnicodeEncodeError` になり、
    **投入は終わっているのにトレースバックで落ちる**という最悪の見え方をした。
    Render (Linux/UTF-8) では出ないので、CI もローカルの test も緑のまま通る。

    運用コマンドは PM が Windows ターミナルからも叩くので、ここで縛る。
    docstring やコメントは表示されないので対象外。
    """

    def _assert_cp932_safe(self, text: str, label: str):
        try:
            text.encode('cp932')
        except UnicodeEncodeError as exc:
            self.fail(
                f'{label} の出力が Windows (cp932) で落ちます: '
                f'{text[exc.start:exc.end]!r} —— 絵文字を [!] / [OK] 等に置き換えてください'
            )

    def test_backfill_output_is_cp932_safe(self):
        for args in ((), ('--apply',)):
            out = StringIO()
            call_command('backfill_daily_achievements', *args, stdout=out)
            self._assert_cp932_safe(out.getvalue(), 'backfill_daily_achievements')

    def test_check_output_is_cp932_safe(self):
        self.award(self.day())
        out = StringIO()
        call_command('check_daily_achievement_consistency', stdout=out)
        self._assert_cp932_safe(out.getvalue(), 'check_daily_achievement_consistency')

        # 不一致がある経路の出力も見る (--fix の成功メッセージを含む)
        streak = self.reread_streak()
        streak.login_streak_days = 99
        streak.save(update_fields=['login_streak_days'])
        out = StringIO()
        call_command('check_daily_achievement_consistency', '--fix', stdout=out)
        self._assert_cp932_safe(out.getvalue(), 'check_daily_achievement_consistency --fix')


# ──────────────────────────────────────────────────────────────────────────
# §9 照合コマンドがドリフトを検出する (Phase 4)
# ──────────────────────────────────────────────────────────────────────────
class ConsistencyCommandTest(_StreakTestBase):

    def _break_cache(self):
        self.award(self.day())
        self.award(self.day(1))
        streak = self.reread_streak()
        streak.login_streak_days = 99          # 行と食い違わせる
        streak.save(update_fields=['login_streak_days'])

    def test_drift_exits_with_error(self):
        self._break_cache()
        with self.assertRaises(SystemExit) as ctx:
            call_command('check_daily_achievement_consistency', stdout=StringIO())
        self.assertEqual(ctx.exception.code, 1)

    def test_fix_repairs_from_rows(self):
        self._break_cache()
        out = StringIO()
        call_command('check_daily_achievement_consistency', '--fix', stdout=out)
        self.assertIn('修復しました', out.getvalue())
        self.assertEqual(self.reread_streak().login_streak_days, 2)

    def test_best_streak_drift_is_also_detected(self):
        """⚠️ 表示しない `best_task_streak_days` も検証対象に含める。

        検証から外すと「更新漏れに気付けない field」に逆戻りする (Pre-mortem 9)。
        """
        self.award(self.day())
        streak = self.reread_streak()
        streak.best_task_streak_days = 42
        streak.save(update_fields=['best_task_streak_days'])
        with self.assertRaises(SystemExit):
            call_command('check_daily_achievement_consistency', stdout=StringIO())
