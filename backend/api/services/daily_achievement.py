"""【FEAT-539 (2026-09-05)】連続達成日数 / 累計達成日数の**単一の真実値**。

## このモジュールが存在する理由

`DailyAchievement` の行が真実値で、`PlayerStreakState.login_streak_days` と
`best_task_streak_days` はその**キャッシュ**である。キャッシュが壊れても
行から数え直せる —— それが案 A (カウンタ 2 本) ではなく案 B (行) を選んだ理由である
(指示書 §4)。

🔴 **再計算ロジックは 3 箇所から使われるが、実体はこのファイルの 1 つだけ。**

    Phase 2  発火点        `record_daily_achievement()`      ← 差分更新 (+1 / リセット)
    Phase 3  backfill      `recompute_from_rows()`           ← 行から数え直して埋める
    Phase 4  照合コマンド   `recompute_from_rows()`           ← 行から数え直して突き合わせ

3 箇所に別々に書くと「**照合は通るのに実態が違う**」という最悪の形になる。
Phase 3 と Phase 4 が同じ `recompute_from_rows()` を呼ぶので、
**backfill 直後の照合は構造的に 0 件になる** (通らなければ実装が分かれている証拠。
`test_backfill_then_check_reports_zero` がそれを縛っている)。

Phase 2 だけは差分更新である (毎回全走査しないため。指示書 §4「走査は検証コマンド側の
仕事」)。差分と全走査が食い違わないよう、**「昨日は継続日か」の判定だけは
`_CONTINUATION_SOURCES` という同じ 1 つの定義から導いている** ——
`is_continuation_day()` (hot path、2 本の EXISTS) と `_continuation_dates()`
(全走査、2 本の VALUES) は同じタプルを回す。片方だけ直すことができない形にしてある。

## 「連続」の定義 (指示書 決定 5)

既存の習慣ストリーク (`habit_count_service.py:201` の `yesterday_done or yesterday_rest`)
に揃える。**同じ画面に 2 種類の「連続」の定義が並ぶ事故を避ける**ため。

    達成日 (DailyAchievement)  … 連続を 1 伸ばす
    休息日 (RestDay)           … 連続を **つなぐが伸ばさない** (橋渡し)
    どちらも無い日             … ここで切れる

⚠️ `RestDay` は FEAT-424 で作成経路が廃止済なので新規行は増えないが、
**既存行は尊重する** (backfill / 照合でも同じ)。
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta

from ..models import DailyAchievement, PlayerProfile, RestDay

# 🔴 「その日は連続をつなぐか」の定義はここ 1 つだけ。
#    hot path (EXISTS) も全走査 (VALUES) もこのタプルを回すので、
#    片方だけ直して定義がズレる、という壊し方ができない。
_CONTINUATION_SOURCES = (DailyAchievement, RestDay)

# `PlayerStreakState.save(update_fields=...)` に渡す field 名。
# 🔴 定数にしているのは、`login_streak_days` を足したのに `best_task_streak_days` を
#    入れ忘れる、という**黙って保存されない**壊れ方を防ぐため
#    (FEAT-537 の `free_memo` が 1 経路だけ 0pt になったのがこの形)。
STREAK_UPDATE_FIELDS = ['login_streak_days', 'best_task_streak_days']


@dataclass(frozen=True)
class StreakSnapshot:
    """行から数え直した連続 / 最長 / 累計。"""

    streak_days: int
    best_streak_days: int
    total_days: int


def is_continuation_day(player: PlayerProfile, day: date) -> bool:
    """`day` に「連続をつなぐ記録」があるか (達成日 or 休息日)。"""
    return any(
        model.objects.filter(player=player, date=day).exists()
        for model in _CONTINUATION_SOURCES
    )


def _continuation_dates(player: PlayerProfile) -> set[date]:
    """`is_continuation_day` と同じ定義を、全走査用にまとめて引く。"""
    days: set[date] = set()
    for model in _CONTINUATION_SOURCES:
        days.update(model.objects.filter(player=player).values_list('date', flat=True))
    return days


def recompute_from_rows(player: PlayerProfile) -> StreakSnapshot:
    """`DailyAchievement` の行だけから連続 / 最長 / 累計を数え直す。

    キャッシュ (`PlayerStreakState`) を一切見ないので、
    **これが常に正しい**。Phase 3 の backfill と Phase 4 の照合が
    どちらもこれを呼ぶ。

    ⚠️ `streak_days` は「**最後の達成日を終端とする連続**」であって
    「今日時点の連続」ではない。今日を基準にすると照合コマンドの結果が
    実行日に依存してしまい、日付をまたいだだけで不一致が出る。
    Phase 2 も達成日にしか書かないので、両者の意味は一致する。
    """
    achieved = set(
        DailyAchievement.objects.filter(player=player).values_list('date', flat=True)
    )
    if not achieved:
        return StreakSnapshot(streak_days=0, best_streak_days=0, total_days=0)

    bridges = _continuation_dates(player)  # 達成日 ∪ 休息日

    best = 0
    current = 0
    previous: date | None = None
    for day in sorted(achieved):
        if previous is None:
            current = 1
        else:
            # previous と day の**間**の日がすべて橋渡しできるか。
            # 隣り合っていれば range が空なので all() は True。
            bridged = all(
                previous + timedelta(days=offset) in bridges
                for offset in range(1, (day - previous).days)
            )
            current = current + 1 if bridged else 1
        best = max(best, current)
        previous = day

    return StreakSnapshot(
        streak_days=current,        # 最後の達成日で終わる連続
        best_streak_days=best,
        total_days=len(achieved),
    )


def apply_snapshot(streak_state, snapshot: StreakSnapshot) -> bool:
    """スナップショットをキャッシュへ反映する。変更があれば True。

    Phase 3 の backfill と Phase 4 の `--fix` が共有する。
    保存は呼び出し側が `STREAK_UPDATE_FIELDS` で行う。
    """
    changed = (
        streak_state.login_streak_days != snapshot.streak_days
        or streak_state.best_task_streak_days != snapshot.best_streak_days
    )
    streak_state.login_streak_days = snapshot.streak_days
    streak_state.best_task_streak_days = snapshot.best_streak_days
    return changed


def record_daily_achievement(
    locked_player: PlayerProfile,
    locked_streak,
    today: date,
) -> tuple[int, int]:
    """その日の達成を 1 行記録し、連続 / 累計を返す。

    🔴 **必ず `award_daily_first_task_bonus` の `transaction.atomic()` +
    `select_for_update()` のロック内から呼ぶこと。** 外に出すと並列リクエストで
    連続が 2 回加算される (Pre-mortem 5)。`UniqueConstraint` は最後の砦であって、
    1 本目の防御ではない。

    ⚠️ 呼び出し側は `locked_streak.save(update_fields=...)` に
    `STREAK_UPDATE_FIELDS` を含めること。含めないと**黙って保存されない**。

    Args:
        locked_player: `select_for_update()` で取得済の PlayerProfile
        locked_streak: その PlayerStreakState (保存は呼び出し側)
        today:         JST の当日 (`timezone.localdate()`)

    Returns:
        (streak_days, total_days)
    """
    yesterday = today - timedelta(days=1)
    # 🔴 昨日を見るのは行を作る**前**。先に作ると today の行が邪魔をする…
    #    ことは無い (見ているのは yesterday) が、順序を変えない方が読みやすい。
    continued = is_continuation_day(locked_player, yesterday)

    DailyAchievement.objects.get_or_create(player=locked_player, date=today)

    locked_streak.login_streak_days = (
        locked_streak.login_streak_days + 1 if continued else 1
    )
    # 決定 4: v1.1.2 では表示しないが、書き込みはする。
    # 表示しないからと省くと「誰も更新しない field」がもう 1 本増える (§2)。
    locked_streak.best_task_streak_days = max(
        locked_streak.best_task_streak_days,
        locked_streak.login_streak_days,
    )

    total_days = DailyAchievement.objects.filter(player=locked_player).count()
    return locked_streak.login_streak_days, total_days
