"""【FEAT-539 (2026-09-05)】`login_streak_days` が行とズレていないか照合する。

    python manage.py check_daily_achievement_consistency          # 検出のみ (不一致で exit 1)
    python manage.py check_daily_achievement_consistency --fix    # 検出して直す

🔵 **このコマンドがあることが、案 A (カウンタ 2 本) ではなく案 B (行) を
選んだ理由そのものである。** カウンタだけなら、ズレても誰も気付けない ——
`login_streak_days` が FEAT-331 から本 FEAT までの間ずっと 0 のままで、
admin が「連続日数の多い順」に並べても全員 0 だったことに誰も気付かなかったのが、
まさにその実例である (指示書 §2)。

🔴 再計算は `services/daily_achievement.recompute_from_rows()` —— Phase 2 の
発火点と Phase 3 の backfill が使うのと**同じ関数**である。ここに独自の
数え方を書くと「**照合は通るのに実態が違う**」という最悪の形になる。

⚠️ `best_task_streak_days` も検証対象に含める。v1.1.2 では表示しないが、
検証から外すと「更新漏れに気付けない field」に逆戻りする (Pre-mortem 9)。
"""

from django.core.management.base import BaseCommand

from api.models import PlayerProfile
from api.services.daily_achievement import (
    STREAK_UPDATE_FIELDS,
    apply_snapshot,
    recompute_from_rows,
)


class Command(BaseCommand):
    help = (
        '【FEAT-539】DailyAchievement の行と PlayerStreakState のキャッシュが'
        '一致するか照合する (不一致があれば exit 1、--fix で修復)'
    )

    def add_arguments(self, parser):
        parser.add_argument(
            '--fix', action='store_true',
            help='不一致を行の値で上書きして修復する',
        )
        parser.add_argument(
            '--player-id', type=int, default=None,
            help='特定プレイヤーのみ照合する (検証用)',
        )

    def handle(self, *args, **options):
        fix = options['fix']
        player_id = options['player_id']

        players = PlayerProfile.objects.all().order_by('pk')
        if player_id is not None:
            players = players.filter(pk=player_id)

        mismatches = []
        checked = 0

        for player in players.iterator():
            checked += 1
            snapshot = recompute_from_rows(player)
            streak_state = player.streak
            if (streak_state.login_streak_days == snapshot.streak_days
                    and streak_state.best_task_streak_days == snapshot.best_streak_days):
                continue

            mismatches.append((
                player,
                streak_state.login_streak_days, snapshot.streak_days,
                streak_state.best_task_streak_days, snapshot.best_streak_days,
            ))
            if fix:
                apply_snapshot(streak_state, snapshot)
                streak_state.save(update_fields=STREAK_UPDATE_FIELDS)

        self.stdout.write('')
        self.stdout.write(self.style.MIGRATE_HEADING(
            '【FEAT-539】DailyAchievement 整合性チェック'
        ))
        self.stdout.write(f'  照合したプレイヤー: {checked}')
        self.stdout.write(f'  不一致            : {len(mismatches)}')

        for player, cur_streak, row_streak, cur_best, row_best in mismatches:
            self.stdout.write(
                f'    - player={player.pk} ({player.name}) '
                f'連続 {cur_streak} -> {row_streak} / '
                f'最長 {cur_best} -> {row_best}'
            )

        if not mismatches:
            self.stdout.write('')
            self.stdout.write(self.style.SUCCESS('  [OK] 不一致はありません。'))
            return

        self.stdout.write('')
        if fix:
            self.stdout.write(self.style.SUCCESS(
                f'  [OK] {len(mismatches)} 件を行の値で修復しました。'
            ))
            return

        self.stdout.write(self.style.ERROR(
            '  [NG] 不一致があります。--fix で行の値に揃えられます。'
        ))
        raise SystemExit(1)
