import logging
from datetime import timedelta

from django.db import transaction
from django.db.models import Count, Sum
from django.db.models import Prefetch
from django.utils import timezone
from ..authentication import ExpiringTokenAuthentication  # 【BUG-163】DRF 素の ExpiringTokenAuthentication は停止検査も期限も持たない
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from ..authentication import GuestTokenAuthentication  # FEAT-190
from ..models import FreeMemo, Habit, HabitLog, Notification, PlayerProfile, RestDay
from ..permissions import IsAuthenticatedOrGuest  # FEAT-187
from ..serializers import HabitSerializer, PlayerProfileSerializer
from ..services.challenge_reward_service import grant_pending_rewards  # 【20260729】
from ..services.locale_sync_service import sync_preferred_language  # 【FEAT-517】
from ..services.daily_throttle_service import (
    reset_battle_charges_if_new_day,
    reset_daily_battle_count_if_new_day,
)
from .mixins import PlayerMixin
from .sabi import (  # 【BUG-145】period_summary を追加
    CONTEXT_EMOTION_MAP, _apply_greeting, get_sabi_message, period_summary,
)

_logger = logging.getLogger(__name__)


class HomeBootstrapView(PlayerMixin, APIView):
    """
    GET /api/home/
    ホーム画面初回描画に必要なデータを 1 リクエストで返す集約エンドポイント。

    レスポンス:
    {
        "player": {...},         # PlayerProfileSerializer
        "habits": [...],         # HabitSerializer（list）
        "summary": {...},        # HabitSummaryView と同じ構造
        "rest_day": {...},       # RestDayStatusView と同じ構造
        "unread_notif_count": 0, # 未読通知数
        "free_memo_count": 0     # 【FEAT-493 + BUG-141】未 archive フリーメモ件数
    }
    """
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        player = self.get_player(request)
        today  = timezone.localdate()

        # 【FEAT-517】Accept-Language を PlayerSettings.preferred_language に反映する。
        #
        # 通知 (FCM / リマインダー) はリクエストの外で送られるため、宛先の言語を
        # 知る手掛かりが preferred_language しかない。しかし Mobile がこの field を
        # 送るのは「設定画面で明示的に言語を選んだとき」だけなので、
        # 「英語端末で新規インストール → 設定画面を開かない」という最も普通の導線で
        # 'ja' のまま残り、英語ユーザーに日本語の通知が届く。
        #
        # 全リクエストではなく **ホーム bootstrap でだけ** 同期する
        # (= アプリを開いた 1 点。毎リクエストだと SELECT が 1 本増える)。
        # 詳細と設計判断: api/services/locale_sync_service.py の docstring。
        sync_preferred_language(request, player)

        # ── player ──────────────────────────────────────────────────
        # 【BUG-78】日付変更後、Flutter が stale な daily_battle_count=10 を見て
        # BattleStartView 到達前に出陣ボタンを塞ぐ問題を防ぐ。read path で DB も同期。
        # 【BUG-118 (2026-06-14)】battle_charges も同じ理由で read path で同期する
        # (FEAT-406 で導入された日次リセットが write path のみで、ホーム/ギルド画面
        # の表示で翌日も古い charges が残るユーザー報告の真因)。
        # 【FEAT-478 Phase 2b (2026-07-04)】reset_*_if_new_day 関数は内部で
        # player.battle (PlayerBattleState) を save 済のため、外側の
        # player.save(update_fields=[...]) は不要 (旧実装は OLD field を stale
        # なまま no-op save していた副産物、Phase 2b で NEW state 一元化)。
        with transaction.atomic():
            player = PlayerProfile.objects.select_for_update().get(pk=player.pk)
            reset_daily_battle_count_if_new_day(player)
            reset_battle_charges_if_new_day(player)
        player_data = PlayerProfileSerializer(player, context={"request": request}).data

        # ── habits ──────────────────────────────────────────────────
        # HabitListCreateView.get() のロジックを直接再現する
        completed_todo_pks = (
            HabitLog.objects
            .filter(
                habit__player=player,
                habit__is_active=True,
                habit__habit_type='todo',
                count__gte=1,
            )
            .exclude(date=today)
            .values_list('habit_id', flat=True)
            .distinct()
        )

        # デフォルトは直近 90 日
        #
        # 【FEAT-520 §4.4】`reset_cycle='yearly'` の習慣を 1 件でも持つ場合は
        # 年初まで窓を広げる。
        #
        # `_year_logs` は名前に反して既定 90 日しか読まず、しかも Flutter は
        # `?period=year` を一度も送っていない (grep 実測)。そのまま
        # `period_count` を実装すると **1〜9 月の回数が黙って欠落する**。
        # 日数表示 (`period_progress`) なら「今年 12/365 日」で違和感が薄いが、
        # 回数合計は桁が変わるためユーザーから見て明確な誤りになる。
        # weekly / monthly は 90 日窓に収まるので影響なし。
        period = request.query_params.get('period', '90d')
        has_yearly = Habit.objects.filter(
            player=player, is_active=True, reset_cycle='yearly',
        ).exists()
        if period == 'year' or has_yearly:
            range_start = today.replace(month=1, day=1)
        else:
            range_start = today - timedelta(days=89)

        habits_qs = (
            Habit.objects
            .filter(player=player, is_active=True)
            .exclude(pk__in=completed_todo_pks)
            .order_by('order', 'id')
            .prefetch_related(
                Prefetch(
                    'logs',
                    queryset=HabitLog.objects.filter(
                        date__gte=range_start,
                    ).order_by('date'),
                    to_attr='_year_logs',
                ),
                'checklist_items',
            )
        )
        # 【FEAT-474】Bootstrap は最初の 50 件のみ。51 件取得して has_more を判定。
        habit_rows        = list(habits_qs[:51])
        has_more_habits   = len(habit_rows) > 50
        habits_data       = HabitSerializer(habit_rows[:50], many=True).data

        # ── summary ──────────────────────────────────────────────────
        # HabitSummaryView.get() のロジックを直接再現する
        active_habits = Habit.objects.filter(player=player, is_active=True)
        total = active_habits.count()

        today_completed = HabitLog.objects.filter(
            habit__in=active_habits, date=today, count__gte=1,
        ).count()

        total_exp_today = (
            HabitLog.objects
            .filter(habit__in=active_habits, date=today)
            .aggregate(total=Sum('exp_gained'))['total'] or 0
        )

        current_streak = (
            active_habits.order_by('-streak').values_list('streak', flat=True).first() or 0
        )

        week_rate = 0
        if total > 0:
            week_start = today - timedelta(days=6)
            done_by_date = {
                r['date']: r['c']
                for r in HabitLog.objects
                .filter(habit__in=active_habits, date__range=(week_start, today), count__gte=1)
                .values('date')
                .annotate(c=Count('id'))
            }
            daily_rates = [
                done_by_date.get(today - timedelta(days=i), 0) / total
                for i in range(7)
            ]
            week_rate = int(sum(daily_rates) / 7 * 100)

        summary_data = {
            'today_completed': today_completed,
            'today_total':     total,
            'week_rate':       week_rate,
            'current_streak':  current_streak,
            'total_exp_today': total_exp_today,
        }

        # ── rest_day ─────────────────────────────────────────────────
        # 【2026-07-08 検証時 hotfix】FEAT-424 で休息の果実機能は廃止済み、
        # migration 0173 (FEAT-478 Phase 2d) で PlayerProfile.rest_fruits が
        # DB column ごと削除され `_DEAD_FIELDS` 経由で None 固定になった。
        # `player.rest_fruits > 0` は None との比較で TypeError → GET /api/home/
        # が (today_is_rest=False の) 大半のリクエストで 500 になっていた。
        # `or 0` で dead field を「0 個」として扱う (機能廃止と整合、Mobile は
        # rest_fruits/can_take_rest を参照していないため契約影響なし)。
        today_is_rest = RestDay.objects.filter(player=player, date=today).exists()
        rest_fruits = player.rest_fruits or 0

        rest_day_data = {
            'today_is_rest': today_is_rest,
            'rest_fruits':   rest_fruits,
            'can_take_rest': not today_is_rest and rest_fruits > 0,
        }

        # ── sabi_message (オプション) ─────────────────────────────────
        # ?time_segment=<key> が指定された場合のみ含む。
        # nonce='' (seed=player.id+today) で 1 日 1 メッセージ互換を維持する。
        time_segment = request.query_params.get('time_segment', '')
        sabi_message_data = None
        if time_segment:
            # 【BUG-145】今日 1 日ではなく frequency の期間で達成を数える。
            #
            # 旧: `{'completed': today_completed, 'total': total}` を渡していた。
            # `today_completed` は今日の HabitLog のみを数えるため、週次 / 月次
            # 習慣を今日以外に達成したユーザーは **その周期のあいだずっと
            # 「達成ゼロ」扱い**になり、習慣カードの完了表示 (`period_done`) と
            # 食い違っていた。`total` は既に数えてあるので渡して重複クエリを避ける。
            #
            # `exp_today` は `get_sabi_message` が参照しないため渡さない。
            sabi_today_summary = period_summary(player, total=total)
            # 【FEAT-489 Phase 4 hotfix (2026-08-02)】locale を渡す。
            #
            # FEAT-484 でホーム画面のサビセリフ取得が SabiMessageView から本
            # bootstrap に統合された際、SabiMessageView 側にだけ locale 引数が
            # 足されて本経路が取り残されていた。ホーム画面は bootstrap しか
            # 叩かないため、**英語 UI でもサビだけ日本語のまま**になっていた
            # (2026-08-02 実機 QA で検出)。
            locale = getattr(request, 'locale', 'ja')
            sabi_msg_text = _apply_greeting(
                get_sabi_message(
                    player, sabi_today_summary, nonce='', locale=locale,
                ),
                time_segment,
                locale=locale,
            )
            sabi_message_data = {
                'message':    sabi_msg_text,
                'is_rest_day': today_is_rest,
                'context':    'default',
                'emotion':    CONTEXT_EMOTION_MAP['default'],
            }

        # ── unread_notif_count ───────────────────────────────────────
        unread_count = Notification.objects.filter(
            player=player, is_read=False,
        ).count()

        # ── free_memo_count ──────────────────────────────────────────
        # 【2026-07-25 codebase-functional-review 20260725 対応 (P1 #2)】
        # home_body.dart の _FreeMemoSection は「未整理のメモ (N)」の整数 1 個
        # しか使わないのに、独立 fetch `GET /free-memos/` で全メモ本文を取得して
        # いた。ホーム bootstrap に count のみを統合、独立 fetch を廃止する。
        # 判断根拠: `home_bootstrap_provider.dart` の Q1 判断フロー = YES
        # (above-the-fold で描画される機能、default ON で全ユーザー影響)。
        free_memo_count = FreeMemo.objects.filter(
            player=player, archived_at__isnull=True,
        ).count()

        # ── pending_challenge_rewards ────────────────────────────────
        # 【20260729 user feedback + gameplay-review §3 対応 (v1.0.5 Option A)】
        # FEAT-465/466 Challenge の lazy 報酬配布を Home 経路に統合。
        # 従来は /api/challenges/ (Challenge 画面 open 時) にしか呼ばれず、
        # Challenge 画面を開かない user は期限切れ後の報酬が永久に配布されず
        # 放置される問題があった (問題 1: 「Challenge 画面を開かないと配布
        # されない」/ 問題 2: 「Home / Calendar での告知経路がない」)。
        # 本 FEAT で /api/home/ にも grant_pending_rewards() を統合、Home 表示
        # 経由で全 user に自動配布 + Mobile 側 home_listeners で SnackBar 告知。
        # best-effort: 例外は握り潰して Home 表示は継続 (Sabi 哲学「押し付けない」)。
        pending_challenge_rewards: list[dict] = []
        try:
            # 【2026-08-11】locale を渡す。ここが既定 'ja' のままだと
            # 「Challenge 画面では英語 / Home の SnackBar では日本語」になる。
            pending_challenge_rewards = grant_pending_rewards(
                player, locale=getattr(request, 'locale', 'ja'),
            )
        except Exception as exc:
            _logger.warning(
                'HomeBootstrapView: grant_pending_rewards failed (best-effort continue): %s',
                exc, exc_info=True,
            )

        response_data: dict = {
            'player':             player_data,
            'habits':             habits_data,
            'has_more_habits':    has_more_habits,
            'summary':            summary_data,
            'rest_day':           rest_day_data,
            'unread_notif_count': unread_count,
            'free_memo_count':    free_memo_count,
            'pending_challenge_rewards': pending_challenge_rewards,
        }
        if sabi_message_data is not None:
            response_data['sabi_message'] = sabi_message_data
        return Response(response_data)
