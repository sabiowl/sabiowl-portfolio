from django.core.management.base import BaseCommand
from django.db.models import Sum

try:
    from api.models import Habit, HabitRewardLog
    _IMPORT_OK = True
except ImportError:
    # HabitRewardLog が api.models に存在しない場合はスキップ
    _IMPORT_OK = False


class Command(BaseCommand):
    help = 'Habit.total_exp と HabitRewardLog の整合性を監査する'

    def handle(self, *args, **options):
        if not _IMPORT_OK:
            self.stdout.write(self.style.ERROR(
                'HabitRewardLog モデルが見つかりません。models に追加されているか確認してください。'
            ))
            return

        bad = []
        for habit in Habit.objects.select_related('player').all():
            agg = HabitRewardLog.objects.filter(habit=habit).aggregate(
                total=Sum('exp_delta')
            )
            recorded = agg['total'] or 0
            if abs(habit.total_exp - recorded) > 100:  # 許容誤差
                bad.append((habit.id, habit.player_id, habit.total_exp, recorded))

        if bad:
            for hid, pid, te, rec in bad:
                self.stdout.write(self.style.WARNING(
                    f'habit={hid} player={pid} total_exp={te} reward_log_sum={rec}'
                ))
            self.stdout.write(self.style.ERROR(f'{len(bad)} 件の不整合が見つかりました'))
        else:
            self.stdout.write(self.style.SUCCESS('不整合なし'))
