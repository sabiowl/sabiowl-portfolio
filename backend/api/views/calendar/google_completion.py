"""【FEAT-426 (2026-06-11)】Google カレンダー予定の完了状態 view (設計 Y)。

プライバシー保護のため、Google 予定の本文 (title/start_time/memo) は Mobile
ローカル DB (`LocalGoogleEventStore`) のみに保存する。本モジュールは Backend が
保持する完了状態 (`GoogleEventCompletion`) の Multi-device 同期 + 完了 / 取消を担う:

    - GoogleEventCompletionListView  GET  /api/google-events/completions/
    - GoogleEventCompletionView       POST/DELETE /api/google-events/<id>/complete/

FEAT-419 の「予定時刻 ±15 分以内 + 同日完了でコイン +5 ボーナス」ロジックを
`views/timeline.py:TimelineCompleteView` から流用しつつ、`start_time` は Mobile
からの送信値のため、改ざん緩和として「現在時刻との差が 24h 以内」のみボーナス
判定対象とする (Pre-mortem S3)。
"""
import datetime

from django.db import transaction
from django.utils import timezone
from django.utils.dateparse import parse_date
from rest_framework.authentication import TokenAuthentication
from rest_framework.response import Response
from rest_framework.views import APIView

from ...authentication import GuestTokenAuthentication  # FEAT-190
from ...models import GoogleEventCompletion, PlayerProfile
from ...permissions import IsAuthenticatedOrGuest  # FEAT-187
from ...serializers import GoogleEventCompletionSerializer
from .._error_helpers import error_response  # 【FEAT-475 Phase 3c】新形式統一
from ..mixins import PlayerMixin


class GoogleEventCompletionListView(PlayerMixin, APIView):
    """
    GET /api/google-events/completions/?date_from=YYYY-MM-DD&date_to=YYYY-MM-DD

    Multi-device 同期用に、指定期間内の completion 一覧を返す。
    `date_from` / `date_to` は省略可能（省略時は全件）。
    """
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def get(self, request):
        player = self.get_player(request)
        qs = GoogleEventCompletion.objects.filter(player=player)

        date_from = request.query_params.get('date_from')
        if date_from:
            parsed = parse_date(date_from)
            if parsed is None:
                return error_response(
                    code='google_completion_invalid_date_from',
                    message='date_from の形式が正しくありません 🪶',
                    fields={'date_from': 'YYYY-MM-DD 形式で指定してください'},
                    status=400,
                )
            qs = qs.filter(event_date__gte=parsed)

        date_to = request.query_params.get('date_to')
        if date_to:
            parsed = parse_date(date_to)
            if parsed is None:
                return error_response(
                    code='google_completion_invalid_date_to',
                    message='date_to の形式が正しくありません 🪶',
                    fields={'date_to': 'YYYY-MM-DD 形式で指定してください'},
                    status=400,
                )
            qs = qs.filter(event_date__lte=parsed)

        return Response({
            'completions': GoogleEventCompletionSerializer(qs, many=True).data,
        })


class GoogleEventCompletionView(PlayerMixin, APIView):
    """
    POST   /api/google-events/<google_event_id>/complete/  完了マーク + ボーナス判定
    DELETE /api/google-events/<google_event_id>/complete/  完了取消（コイン -5 対称化）
    """
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    # 【FEAT-419 流用】予定時刻 ±15 分以内 + 同日完了でコイン +5。
    ON_TIME_BONUS_COIN     = 5
    ON_TIME_WINDOW_MINUTES = 15
    # 【Pre-mortem S3】Mobile から送信される start_time の改ざん緩和。
    # 現在時刻との差が 24h を超える場合はボーナス判定対象外（completion 自体は成立）。
    TAMPER_VALIDITY_HOURS = 24

    def post(self, request, google_event_id):
        player = self.get_player(request)

        event_date_str = request.data.get('event_date')
        event_date = parse_date(event_date_str) if event_date_str else None
        if event_date is None:
            return error_response(
                code='google_completion_invalid_event_date',
                message='event_date の形式が正しくありません 🪶',
                fields={'event_date': 'YYYY-MM-DD 形式で指定してください'},
                status=400,
            )

        start_time_str = request.data.get('start_time')

        with transaction.atomic():
            completion, _ = GoogleEventCompletion.objects.select_for_update().get_or_create(
                player=player,
                google_event_id=google_event_id,
                defaults={'event_date': event_date},
            )

            # 冪等：既に完了済みなら再判定せず 200 を返す
            if completion.is_completed:
                return Response({
                    'completion':            GoogleEventCompletionSerializer(completion).data,
                    'on_time_bonus_awarded': completion.on_time_bonus_awarded,
                    'on_time_bonus_coin':    0,
                }, status=200)

            completion.event_date   = event_date
            completion.is_completed = True
            completion.completed_at = timezone.now()

            on_time_bonus = self._check_on_time_bonus(event_date, start_time_str)

            on_time_bonus_coin = 0
            update_fields = ['event_date', 'is_completed', 'completed_at', 'updated_at']
            if on_time_bonus:
                # 【FEAT-478 Phase 2b hotfix (2026-07-05、gameplay_review 20260704 P1-新)】
                # bonus_coins は PlayerEconomyState (NEW state proxy) 経由で書込。
                # 旧実装は player_obj.bonus_coins (OLD field) 直書きだったが、
                # 実際にユーザーに見えるコイン残高 (shop.py:compute_coins) は
                # eco.bonus_coins (= PlayerEconomyState.bonus_coins) のみを参照する
                # ため、+5 コインを付与しても残高に反映されない状態だった。
                # timeline.py:TimelineCompleteView (同 FEAT-478 hotfix で既対応)
                # と完全同パターン。
                player_obj = PlayerProfile.objects.select_for_update().get(pk=player.pk)
                economy = player_obj.economy
                economy.bonus_coins += self.ON_TIME_BONUS_COIN
                economy.save(update_fields=['bonus_coins'])
                completion.on_time_bonus_awarded = True
                on_time_bonus_coin = self.ON_TIME_BONUS_COIN
                update_fields.append('on_time_bonus_awarded')

            completion.save(update_fields=update_fields)

        return Response({
            'completion':            GoogleEventCompletionSerializer(completion).data,
            'on_time_bonus_awarded': completion.on_time_bonus_awarded,
            'on_time_bonus_coin':    on_time_bonus_coin,
        }, status=200)

    def delete(self, request, google_event_id):
        player = self.get_player(request)

        with transaction.atomic():
            try:
                completion = GoogleEventCompletion.objects.select_for_update().get(
                    player=player, google_event_id=google_event_id,
                )
            except GoogleEventCompletion.DoesNotExist:
                return Response({'completion': None}, status=200)

            # 冪等：既に未完了なら何もせず 200
            if not completion.is_completed:
                return Response({
                    'completion': GoogleEventCompletionSerializer(completion).data,
                }, status=200)

            completion.is_completed = False
            completion.completed_at = None
            update_fields = ['is_completed', 'completed_at', 'updated_at']

            # 【FEAT-419 対称化】完了取消時、ボーナス受領済ならコイン -5 + フラグ False
            # 【FEAT-478 Phase 2b hotfix (2026-07-05)】上記付与経路と対称で NEW state 経由。
            if completion.on_time_bonus_awarded:
                player_obj = PlayerProfile.objects.select_for_update().get(pk=player.pk)
                economy = player_obj.economy
                economy.bonus_coins = max(0, economy.bonus_coins - self.ON_TIME_BONUS_COIN)
                economy.save(update_fields=['bonus_coins'])
                completion.on_time_bonus_awarded = False
                update_fields.append('on_time_bonus_awarded')

            completion.save(update_fields=update_fields)

        return Response({
            'completion': GoogleEventCompletionSerializer(completion).data,
        }, status=200)

    def _check_on_time_bonus(self, event_date, start_time_str):
        if not start_time_str:
            return False

        try:
            parts = start_time_str.split(':')
            hour, minute = int(parts[0]), int(parts[1])
            start_time = datetime.time(hour=hour, minute=minute)
        except (ValueError, IndexError, TypeError):
            return False

        now_local = timezone.localtime()
        scheduled = datetime.datetime.combine(event_date, start_time, tzinfo=now_local.tzinfo)
        delta_sec = (now_local - scheduled).total_seconds()

        # 改ざん緩和: scheduled が現在時刻から 24h 以上離れていればボーナス対象外
        if abs(delta_sec) > self.TAMPER_VALIDITY_HOURS * 3600:
            return False

        # 同日 + ±15 分以内のみボーナス対象
        return event_date == now_local.date() and abs(delta_sec) <= self.ON_TIME_WINDOW_MINUTES * 60
