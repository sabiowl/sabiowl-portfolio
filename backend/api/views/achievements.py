from rest_framework import status
from ..authentication import ExpiringTokenAuthentication  # 【BUG-163】DRF 素の ExpiringTokenAuthentication は停止検査も期限も持たない
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from ..authentication import GuestTokenAuthentication  # FEAT-190
from ..permissions import IsAuthenticatedOrGuest  # FEAT-187

from django.db import transaction
from django.db.models import Count, Max, Q, Sum

from ..constants import FriendStatus
from ..models import Achievement, Friendship, GachaHistory, Habit, HabitLog, PlayerAchievement, PlayerProfile
from ..i18n_messages import resolve_player_locale  # 【FEAT-517】
from ..serializers import AchievementSerializer, get_i18n_field
from ..services.diamond_service import award_diamond_for_title_acquired  # 【FEAT-314】
from ..services.push_service import create_localized_notification  # 【FEAT-517】
from ._error_helpers import error_response  # 【FEAT-475 Phase 3c】新形式統一
from .mixins import PlayerMixin


def check_achievements(player):
    """プレイヤーの現在の状態を確認し、未解除の実績を解除する。

    P0-3a: 60 秒以内に実行済みの場合はスキップ（画面表示のたびに 5 集計クエリが走るのを防ぐ）。
    P0-3b: SQL 側で解除済み実績を除外してから Python ループ。

    【FEAT-314】 戻り値を tuple `(newly_unlocked, title_diamond_total)` に変更。
    各 unlock につき祝福ボーナス +20 ダイヤを `award_diamond_for_title_acquired` で
    付与し、その合計を呼び出し側 (`AchievementListView`) が response に流す。
    """
    from django.utils import timezone as _tz

    # 60 秒ガード
    now = _tz.now()
    player_streak = player.streak
    if (
        player_streak.last_achievement_check_at is not None
        and (now - player_streak.last_achievement_check_at).total_seconds() < 60
    ):
        return [], 0

    already_unlocked = set(
        PlayerAchievement.objects.filter(player=player)
        .values_list('achievement_id', flat=True)
    )

    # 【新規 (2026-06-26)】30 件拡張に伴う 3 種の追加 metric。
    # - active_habits:     現在アクティブな count/checklist 習慣数 (ToDo 除外)
    # - perfect_day_count: 現在 active な習慣すべてに log がある日数 (heuristic)
    # - total_exp_earned:  累計獲得 EXP (HabitLog.exp_gained 合計)
    active_habits_qs = Habit.objects.filter(
        player=player, is_active=True,
    ).exclude(habit_type='todo')
    active_habits_count = active_habits_qs.count()
    if active_habits_count > 0:
        perfect_day_count = (
            HabitLog.objects
            .filter(habit__in=active_habits_qs, count__gte=1)
            .values('date')
            .annotate(habit_count=Count('habit', distinct=True))
            .filter(habit_count=active_habits_count)
            .count()
        )
    else:
        perfect_day_count = 0
    total_exp_earned = (
        HabitLog.objects.filter(habit__player=player)
        .aggregate(s=Sum('exp_gained'))['s'] or 0
    )

    metrics = {
        'total_logs':        HabitLog.objects.filter(habit__player=player, count__gte=1).count(),
        'best_streak':       Habit.objects.filter(player=player).aggregate(v=Max('best_streak'))['v'] or 0,
        'level_reached':     player.battle.level,
        'gacha_pulls':       GachaHistory.objects.filter(player=player).count(),
        'friends_count':     Friendship.objects.filter(
            Q(from_player=player) | Q(to_player=player),
            status=FriendStatus.ACCEPTED,
        ).count(),
        'active_habits':     active_habits_count,
        'perfect_day_count': perfect_day_count,
        'total_exp_earned':  total_exp_earned,
    }

    newly_unlocked = []
    # P0-3b: SQL 側で解除済みを除外（Python ループの回数を削減）
    for achievement in Achievement.objects.exclude(id__in=already_unlocked):
        current = metrics.get(achievement.condition_type, 0)
        if current >= achievement.condition_value:
            PlayerAchievement.objects.get_or_create(player=player, achievement=achievement)
            newly_unlocked.append(achievement)

    # 【FEAT-314】unlock 祝福 +20 ダイヤを各称号について付与（冪等性は helper 側で担保）
    title_diamond_total = 0
    for achievement in newly_unlocked:
        granted = award_diamond_for_title_acquired(player, achievement.id)
        if granted:
            title_diamond_total += 20  # DIAMOND_TITLE_ACQUIRED_AMOUNT
        # 通知文面: claim 経路の reward_diamonds に加えて、unlock 祝福 +20 ダイヤを併記
        # 【FEAT-517】文面は api/i18n_messages.py が宛先の言語で組み立てる。
        locale = resolve_player_locale(player)
        if granted:
            bonus_suffix = (
                '（+20💎 称号獲得ボーナス）' if locale == 'ja'
                else ' (+20💎 title bonus)'
            )
        else:
            bonus_suffix = ''
        # 実績名は master data。`Achievement.name_en` は FEAT-516 で追加予定で、
        # それまでは ja に fallback する (英文中に日本語の実績名が入る)。
        create_localized_notification(
            player,
            'achievement',
            'achievement_unlocked',
            achievement_name=get_i18n_field(achievement, 'name', locale),
            diamonds=achievement.reward_diamonds,
            bonus_suffix=bonus_suffix,
        )

    # タイムスタンプを更新（ガード用）
    player_streak.last_achievement_check_at = now
    player_streak.save(update_fields=['last_achievement_check_at'])

    return newly_unlocked, title_diamond_total



class AchievementListView(PlayerMixin, APIView):
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def get(self, request):
        player = self.get_player(request)
        # 【FEAT-314】 check_achievements は tuple `(newly_unlocked, title_diamond_total)` を返す
        _, title_diamond_total = check_achievements(player)

        achievements = Achievement.objects.all().order_by('id')
        player_achievements = {
            pa.achievement_id: pa
            for pa in PlayerAchievement.objects.filter(player=player)
        }
        serializer = AchievementSerializer(
            achievements, many=True,
            # 【FEAT-516】`request` を渡さないと I18nFieldMixin が locale を
            # 読めず、`_en` を用意しても英語にならない (仕組みを呼ぶ 1 行)。
            context={'player': player, 'player_achievements': player_achievements,
                     'request': request},
        )
        unclaimed_count = sum(1 for pa in player_achievements.values() if not pa.is_claimed)
        response = {
            'achievements':    serializer.data,
            'unclaimed_count': unclaimed_count,
        }
        # 【FEAT-314】 unlock 祝福 +20 ダイヤが今回付与された場合のみ ToastCenter 起動キー
        if title_diamond_total > 0:
            response['title_diamond']  = title_diamond_total
            response['diamonds_total'] = player.economy.diamonds
        return Response(response)


class AchievementClaimView(PlayerMixin, APIView):
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def post(self, request, key):
        player = self.get_player(request)
        try:
            achievement = Achievement.objects.get(key=key)
        except Achievement.DoesNotExist:
            return error_response(
                code='achievement_claim_not_found',
                message='実績が見つかりませんでした 🪶',
                status=404,
            )

        try:
            pa = PlayerAchievement.objects.get(player=player, achievement=achievement)
        except PlayerAchievement.DoesNotExist:
            return error_response(
                code='achievement_claim_not_unlocked',
                message='まだ解除されていません 🪶',
                status=400,
            )

        if pa.is_claimed:
            return error_response(
                code='achievement_claim_already_claimed',
                message='すでに受け取り済みです 🪶',
                status=400,
            )

        with transaction.atomic():
            pa = PlayerAchievement.objects.select_for_update().get(pk=pa.pk)
            if pa.is_claimed:
                return error_response(
                    code='achievement_claim_already_claimed',
                    message='すでに受け取り済みです 🪶',
                    status=400,
                )
            pa.is_claimed = True
            pa.save(update_fields=['is_claimed'])
            locked_player = PlayerProfile.objects.select_for_update().get(pk=player.pk)
            locked_eco = locked_player.economy
            locked_eco.diamonds       += achievement.reward_diamonds
            locked_eco.diamonds_total += achievement.reward_diamonds
            locked_eco.save(update_fields=['diamonds', 'diamonds_total'])

        return Response({
            'diamonds':        locked_eco.diamonds,
            'reward_diamonds': achievement.reward_diamonds,
            'message':         f'💎 {achievement.reward_diamonds}ダイヤを獲得しました！',
        })
