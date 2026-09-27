"""【FEAT-539 (2026-09-05)】既存ユーザーの `DailyAchievement` を過去データから復元する。

    python manage.py backfill_daily_achievements            # dry-run (件数のみ)
    python manage.py backfill_daily_achievements --apply    # 投入

🔴 **これは近似である。**

  - `HabitLog` (count > 0) の `date` は**達成日そのもの**なので正確。
  - `TimelineEvent` (is_completed=True) は**完了日時を持たず `date` (予定日) しか無い**。
    「予定日と違う日に完了した」ケースは正確に復元できない。

それでも backfill する理由は、60 日遊んでいる人に「累計 1 日」と出すほうが
害が大きいためである (指示書 決定 3)。1 日のズレは許容する。

⚠️ prod で `--apply` を流す前に、**dry-run の件数を報告すること**。

## 投入後に何をするか

行を入れたら、各プレイヤーの `login_streak_days` / `best_task_streak_days` を
**行から数え直して埋める**。数え直しは `services/daily_achievement.recompute_from_rows()`
—— Phase 4 の照合コマンドが使うのと**同じ関数**である。したがって
**backfill 直後の照合は必ず 0 件になる**。0 件にならなければ、
どこかに再計算がもう 1 つ書かれている証拠である
(`test_backfill_then_check_reports_zero` がこれを縛っている)。
"""

from django.core.management.base import BaseCommand
from django.db import transaction

from api.models import DailyAchievement, HabitLog, PlayerProfile, TimelineEvent
from api.services.daily_achievement import (
    STREAK_UPDATE_FIELDS,
    apply_snapshot,
    recompute_from_rows,
)


def collect_achievement_dates(player: PlayerProfile) -> set:
    """そのプレイヤーが「タスクを達成した」とみなせる日付の集合。

    🔴 **`HabitLog` だけでは足りない。** タイムライン予定の完了は `HabitLog` を
    作らないので、`HabitLog` のみで数えると「タイムラインだけ達成した日」が
    落ちる —— **ボーナスは出たのに日数が増えない日**ができてしまう
    (指示書 §4「案 C が失格な理由」と同じ穴)。
    """
    habit_dates = HabitLog.objects.filter(
        habit__player=player, count__gt=0,
    ).values_list('date', flat=True)
    timeline_dates = TimelineEvent.objects.filter(
        player=player, is_completed=True,
    ).values_list('date', flat=True)
    return set(habit_dates) | set(timeline_dates)


class Command(BaseCommand):
    help = (
        '【FEAT-539】HabitLog / TimelineEvent から DailyAchievement を復元し、'
        '連続 / 最長達成日数を数え直す (既定は dry-run)'
    )

    def add_arguments(self, parser):
        parser.add_argument(
            '--apply', action='store_true',
            help='実際に投入する (指定しなければ件数を表示するだけ)',
        )
        parser.add_argument(
            '--player-id', type=int, default=None,
            help='特定プレイヤーのみ対象にする (検証用)',
        )

    def handle(self, *args, **options):
        apply = options['apply']
        player_id = options['player_id']

        players = PlayerProfile.objects.all().order_by('pk')
        if player_id is not None:
            players = players.filter(pk=player_id)

        total_players = 0
        total_new_rows = 0
        total_streak_updated = 0

        for player in players.iterator():
            dates = collect_achievement_dates(player)
            if not dates:
                continue
            total_players += 1

            existing = set(
                DailyAchievement.objects.filter(
                    player=player, date__in=dates,
                ).values_list('date', flat=True)
            )
            missing = sorted(dates - existing)
            total_new_rows += len(missing)

            if not apply:
                continue

            with transaction.atomic():
                # 冪等: 既にある行は無視する。2 回流しても件数は変わらない。
                DailyAchievement.objects.bulk_create(
                    [DailyAchievement(player=player, date=d) for d in missing],
                    ignore_conflicts=True,
                )
                # 🔴 行を入れたら必ず数え直す。ここを飛ばすと、行はあるのに
                #    キャッシュが 0 のままになり、照合コマンドが即不一致を吐く。
                snapshot = recompute_from_rows(player)
                streak_state = player.streak
                if apply_snapshot(streak_state, snapshot):
                    streak_state.save(update_fields=STREAK_UPDATE_FIELDS)
                    total_streak_updated += 1

        mode = '投入' if apply else 'dry-run'
        self.stdout.write('')
        self.stdout.write(self.style.MIGRATE_HEADING(
            f'【FEAT-539】DailyAchievement backfill ({mode})'
        ))
        self.stdout.write(f'  対象プレイヤー          : {total_players}')
        self.stdout.write(f'  追加する DailyAchievement: {total_new_rows}')
        if apply:
            self.stdout.write(f'  連続日数を更新した人数   : {total_streak_updated}')
        self.stdout.write('')
        self.stdout.write(self.style.WARNING(
            '  [!] この復元は近似です。TimelineEvent は完了日時を持たず予定日しか'
        ))
        self.stdout.write(self.style.WARNING(
            '     無いため、予定日と違う日に完了した分は 1 日ズレます。'
        ))
        if not apply:
            self.stdout.write('')
            self.stdout.write('  投入するには --apply を付けて再実行してください。')
