from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from api.models import PlayerProfile

# user スロットル 300/hour × Legendary 60 EXP = 18,000 EXP/hour
# timeline 経路（EXP 5〜20）も含めると実質上限はやや下だが、余裕を持って設定
_HOURLY_MAX_EXP = 300 * 60  # = 18,000 EXP/hour

_LEVEL_EXP_CUMULATIVE = [i * 100 for i in range(1, 201)]  # Lv i → Lv i+1 に必要 EXP


def _cumulative_exp(level, current_exp):
    """累積 EXP（level 1 からの合計）を算出する"""
    base = sum(_LEVEL_EXP_CUMULATIVE[:max(0, level - 1)])
    return base + current_exp


class Command(BaseCommand):
    help = '直近1時間の EXP 増分が異常なプレイヤーを抽出する（audit_habit_rewards の補完）'

    def handle(self, *args, **options):
        # PlayerProfile の snapshot を直接見る方式（HabitRewardLog がない timeline 経路もカバー）
        # 実運用ではレベルアップ前後の current_exp をスナップショットテーブルに記録するのが理想。
        # ここでは簡易版として「level が高すぎる + current_exp が max_exp に近い」player を警告する。
        suspicious = []
        for player in PlayerProfile.objects.select_related('user').all():
            # Lv.1 開始から最速で到達可能なレベルを計算
            hours_since_created = max(1, (timezone.now() - player.created_at).total_seconds() / 3600)
            max_theoretical_exp = hours_since_created * _HOURLY_MAX_EXP
            actual_cumulative   = _cumulative_exp(player.level, player.current_exp)
            if actual_cumulative > max_theoretical_exp:
                suspicious.append((player.id, player.user.email, player.level, actual_cumulative, int(max_theoretical_exp)))

        if suspicious:
            for pid, email, lv, actual, theoretical in suspicious:
                self.stdout.write(self.style.WARNING(
                    f'player={pid} email={email} level={lv} '
                    f'cumulative_exp={actual} max_theoretical={theoretical}'
                ))
            self.stdout.write(self.style.ERROR(f'{len(suspicious)} 件の異常な EXP 増分を検出'))
        else:
            self.stdout.write(self.style.SUCCESS('EXP 増分に異常なし'))
