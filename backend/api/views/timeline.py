import datetime

from django.db import IntegrityError, transaction
from django.shortcuts import get_object_or_404
from django.utils import timezone
from ..authentication import ExpiringTokenAuthentication  # 【BUG-163】DRF 素の ExpiringTokenAuthentication は停止検査も期限も持たない
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from ..authentication import GuestTokenAuthentication  # FEAT-190
from ..constants import GameBalance  # 【FEAT-285】経路別 allocatable points
from ..services.daily_throttle_service import (  # 【FEAT-398 / FEAT-406】
    apply_daily_exp_throttle,
    reset_battle_charges_if_new_day,
)
from ..models import TimelineEvent, PlayerProfile, SocialAccount
from ..permissions import IsAuthenticatedOrGuest  # FEAT-187
from ..serializers import TimelineEventSerializer
from ._error_helpers import error_response  # 【FEAT-475 Phase 3c】新形式統一
from ._helpers import get_player_for_request  # FEAT-187
from ..services.exp_service import (
    calc_timeline_exp,
    award_diamond_if_first_today,
    apply_xp_boost_if_active,  # 【FEAT-318 (2026-06-13 再活性化)】
)
from .mixins import PlayerMixin


def _initial_pending_google_push(player):
    """新規 TimelineEvent の pending_google_push 初期値を返す。

    【FEAT-373 (2026-05-29)】v1.0 で Google Calendar push (Sabiowl → Google) 機能を
    構造的に廃止。pending_google_push は常に False を返す。

    旧実装では Google 連携状態 + gcal_push_enabled を参照して True/False を決定していたが、
    BUG-74 系の「設定無視で push されるバグ」の構造的再発リスクを根絶するため廃止。

    v1.1+ で push 機能を再有効化する場合は git history (FEAT-373 commit 直前) を参照し、
    旧実装を復元してから FeatureFlags.gcalPushEnabled = true に戻すこと。
    """
    # 【FEAT-373】v1.0 で push 機能廃止のため常時 False
    return False


class TimelineListView(APIView):
    """
    GET  /api/timeline/?date=YYYY-MM-DD  — 指定日のイベント一覧
    POST /api/timeline/                  — イベント新規作成
    """
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def get(self, request):
        player   = get_player_for_request(request)

        # 【FEAT-256】Pending な Google push 対象を返す専用クエリ。
        # `?pending_google_push=true` → pending_google_push=True のイベントのみ。
        # 機内モードで push 失敗した予定や、Google 連携前に作った予定（後で連携時に
        # True に補正する設計）が対象。アプリ起動時の auto-retry / 手動同期で共有。
        # 旧 `?unpushed_to_google=true` (FEAT-244) も互換性のため受け付ける。
        pending_param  = request.query_params.get('pending_google_push')
        unpushed_param = request.query_params.get('unpushed_to_google')  # 旧 FEAT-244
        if pending_param == 'true' or unpushed_param == 'true':
            events     = TimelineEvent.objects.filter(
                player=player,
                pending_google_push=True,
            )
            serializer = TimelineEventSerializer(events, many=True)
            return Response(serializer.data)

        # 【FEAT-253】Google 側削除の追随用クエリ。`?has_google_event_id=true` で
        # google_event_id を持つイベント（= Sabiowl が push 済 or Google から
        # 取り込み済）のみを返す。Flutter 側で個別に Google API GET し、404/410
        # を検出した分を Sabiowl 側からも削除する（幽霊状態解消）。
        if request.query_params.get('has_google_event_id') == 'true':
            events = TimelineEvent.objects.filter(
                player=player,
            ).exclude(
                google_event_id__isnull=True,
            ).exclude(
                google_event_id='',
            )
            serializer = TimelineEventSerializer(events, many=True)
            return Response(serializer.data)

        date_str = request.query_params.get('date')
        if not date_str:
            return error_response(
                code='timeline_list_date_required',
                message='日付を選び直してください 🪶',
                fields={'date': '?date=YYYY-MM-DD 形式で指定してください'},
                status=400,
            )
        try:
            date = datetime.date.fromisoformat(date_str)
        except ValueError:
            return error_response(
                code='timeline_list_invalid_date',
                message='日付の形式が正しくありません 🪶',
                fields={'date': 'YYYY-MM-DD 形式で指定してください'},
                status=400,
            )

        events     = TimelineEvent.objects.filter(player=player, date=date)
        serializer = TimelineEventSerializer(events, many=True)
        return Response(serializer.data)

    def post(self, request):
        player     = get_player_for_request(request)
        serializer = TimelineEventSerializer(data=request.data, context={'request': request})
        if not serializer.is_valid():
            return Response(serializer.errors, status=400)
        # 【FEAT-256 / FEAT-257】pending_google_push の初期値を制御:
        #   - Google 未連携ユーザー → False（push 対象外）
        #   - 連携済 + gcal_push_enabled=True → True（fire-and-forget で push される）
        #   - 連携済 + gcal_push_enabled=False（FEAT-257 設定 OFF）→ False（push しない）
        pending_default = _initial_pending_google_push(player)

        # 【FEAT-370 (2026-05-28)】BUG-70 構造解消: migration 0100 の UniqueConstraint で
        # 同 (player, date, title, start_time) の二重 INSERT が IntegrityError になる。
        # client 側に 409 を返して retry させると UX が割れるため、既存 event を 200 で
        # 返却して「サーバ側で実体は 1 件」を gracefully 伝える設計。
        #
        # CLAUDE.md「@transaction.atomic 内 IntegrityError は savepoint を切る (BUG-67)」
        # 遵守: 本 view は class レベルで atomic を持たないが、DRF middleware に依らず
        # 安全側に入れ子 `with transaction.atomic():` を切る (multi-DB 設定や ATOMIC_REQUESTS
        # 将来導入時の defense-in-depth)。
        try:
            with transaction.atomic():
                instance = serializer.save(
                    player=player,
                    pending_google_push=pending_default,
                )
            return Response(
                TimelineEventSerializer(instance).data,
                status=201,
            )
        except IntegrityError:
            # 重複検出 → 既存 event を返却。
            # migration 0100 の 2 つの部分 constraint 経路に対応:
            #   - start_time IS NOT NULL → (player, date, title, start_time) で一意
            #   - start_time IS NULL     → (player, date, title)            で一意
            # validated_data から lookup を組み立てて get() する。
            validated = serializer.validated_data
            lookup = {
                'player':     player,
                'date':       validated.get('date'),
                'title':      validated.get('title'),
                'start_time': validated.get('start_time'),  # None で IS NULL 検索
            }
            try:
                existing = TimelineEvent.objects.get(**lookup)
            except TimelineEvent.DoesNotExist:
                # 想定外の IntegrityError (別 constraint 起因 = external_id 衝突等) → 500 系。
                # ここで sneak で 500 にせず明示的に 409 で返し、client にログ収集を促す。
                return error_response(
                    code='timeline_create_integrity_error',
                    message='時間帯の予定が競合しています。少し時間をおいてお試しください 🪶',
                    status=409,
                )
            return Response(
                TimelineEventSerializer(existing).data,
                status=200,
            )


class TimelineDetailView(APIView):
    """
    PATCH  /api/timeline/<pk>/  — イベント部分更新
    DELETE /api/timeline/<pk>/  — イベント削除
    """
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def _get_object(self, request, pk):
        return get_object_or_404(
            TimelineEvent, pk=pk, player=get_player_for_request(request),
        )

    def get(self, request, pk):
        # 【FEAT-244】DELETE 前に google_event_id を取得するため GET を追加。
        # 既存 LIST は ?date=YYYY-MM-DD 必須で個別取得用途に使えなかった。
        event      = self._get_object(request, pk)
        serializer = TimelineEventSerializer(event)
        return Response(serializer.data)

    def patch(self, request, pk):
        event      = self._get_object(request, pk)
        serializer = TimelineEventSerializer(event, data=request.data, partial=True, context={'request': request})
        if not serializer.is_valid():
            return Response(serializer.errors, status=400)
        serializer.save()
        return Response(serializer.data)

    def delete(self, request, pk):
        event = self._get_object(request, pk)
        event.delete()
        return Response(status=204)


class TimelineGoogleLinkView(APIView):
    """【FEAT-244】Sabiowl → Google push 成功時に Google Event ID を保存する。

    POST /api/timeline/<pk>/google-link/
      {"google_event_id": "abc123@google.com"}

    `TimelineEventSerializer.read_only_fields` で `google_event_id` を保護しているため、
    PATCH /timeline/<pk>/ では更新できない。Google への push 成功時のみ Flutter から
    本エンドポイントで一方向に書き込む設計。Google ID 上書き（再 push）は禁止しない。
    """
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def post(self, request, pk):
        event = get_object_or_404(
            TimelineEvent, pk=pk, player=get_player_for_request(request),
        )
        google_event_id = request.data.get('google_event_id')
        if not isinstance(google_event_id, str) or not google_event_id:
            return error_response(
                code='timeline_mark_google_pushed_event_id_required',
                message='google_event_id を指定してください 🪶',
                fields={'google_event_id': 'google_event_id は必須です'},
                status=400,
            )
        event.google_event_id     = google_event_id
        # 【FEAT-255】push 成功 = Google と同期した瞬間。
        # 次回 sync 時に `google_updated <= last_synced_at + 1s` なので取り込みされず、
        # 双方向ループが構造的に遮断される。
        event.last_synced_at      = timezone.now()
        # 【FEAT-256】push 成功フラグ。次回 sync / 起動時 auto-retry の対象から外す。
        event.pending_google_push = False
        event.save(update_fields=[
            'google_event_id', 'last_synced_at', 'pending_google_push',
        ])
        return Response(TimelineEventSerializer(event).data)


# ── timeline/<pk>/complete/ ────────────────────────────────────────────────
class TimelineCompleteView(PlayerMixin, APIView):
    """
    タイムライン予定の達成を記録し、EXP・ダイヤを付与する。

    POST /api/timeline/<pk>/complete/
    - is_completed を False → True に変更したとき EXP とダイヤを付与する。
    - すでに完了済みの予定を再度 POST しても EXP は付与しない（冪等）。
    - レスポンス: { event, exp_gain, diamond_earned }
    """
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def post(self, request, pk):
        player = self.get_player(request)
        today  = timezone.localdate()

        # NEW-01: select_for_update でイベントをロックしてから is_completed を判定。
        # トランザクション外で was_completed を読むと、並列リクエストが両方
        # False 経路を通って EXP / ダイヤを二重付与してしまう。
        with transaction.atomic():
            try:
                event = TimelineEvent.objects.select_for_update().get(
                    pk=pk, player=player,
                )
            except TimelineEvent.DoesNotExist:
                return error_response(
                    code='timeline_event_not_found',
                    message='予定が見つかりませんでした 🪶',
                    status=404,
                )

            # 冪等：既に完了済みなら EXP を付与せず 200 を返す
            if event.is_completed:
                return Response({
                    'event':                 TimelineEventSerializer(event).data,
                    'exp_gain':              0,
                    'diamond_earned':        False,
                    'on_time_bonus_awarded': event.on_time_bonus_awarded,
                    'on_time_bonus_coin':    0,
                }, status=200)

            event.is_completed = True
            event.save(update_fields=['is_completed'])

            exp_gain = calc_timeline_exp(event)

            # EXP をプレイヤーに付与（行ロックで競合防止）
            player_obj = PlayerProfile.objects.select_for_update().get(pk=player.pk)

            # 【FEAT-478 Phase 2b (2026-07-04)】NEW state proxy 経由で書込。
            # 旧実装は player_obj.current_exp / level / battle_charges 等の OLD field
            # を直接更新していたが、read path (PlayerProfileSerializer) は既に NEW state
            # (PlayerBattleState / PlayerEconomyState) を読むため、Flutter に反映されず
            # 「予定完了しても EXP / Lv / battle_charges が増えない」不整合が発生していた。
            # 本 view の write path を NEW state に統一することで乖離を解消する。
            battle_state = player_obj.battle       # PlayerBattleState (proxy)
            economy      = player_obj.economy      # PlayerEconomyState (proxy)

            # 【FEAT-398】日次 EXP スロットル (経路 2: タイムライン予定完了)
            # apply_daily_exp_throttle は内部で player.battle を参照 + save 済 (Phase 2b 適用済)。
            #
            # 【FEAT-537 (2026-08-29)】旧実装はここで配分 pt も 1 に落としていた。
            # pt のスロットルは **本経路にしか効いておらず** (習慣経路は戻り値を
            # 捨てていた)、経路差の温存になっていたので廃止した。
            # EXP 側の削減は従来どおり効く。
            exp_gain, daily_throttle_triggered = apply_daily_exp_throttle(
                player_obj, exp_gain,
            )

            # 【FEAT-318 (2026-06-13 再活性化)】XP ブースト有効時 ×1.5。
            exp_gain = apply_xp_boost_if_active(player_obj, exp_gain)

            battle_state.current_exp += exp_gain
            while battle_state.current_exp >= battle_state.max_exp:
                battle_state.current_exp        -= battle_state.max_exp
                battle_state.level              += 1
                battle_state.allocatable_points += GameBalance.ALLOCATABLE_POINTS_PER_LEVEL
                # 【FEAT-319】level_to_max_exp で単一真実値化、直書き禁止 (habit_count_service と統一)。
                battle_state.max_exp             = GameBalance.level_to_max_exp(battle_state.level)

            # 【FEAT-299 hotfix 2026-05-24】タイムライン予定完了でも battle_charges +1。
            # 【FEAT-398 第 3 段階】battle_charges_awarded フラグで取り消し対称化。
            # 【FEAT-406 (2026-06-01)】3 達成 = 1 戦の思想復活 + 日次リセット導入。
            # 【FEAT-410 (2026-06-01)】上限 3 → 30 (= 10 戦分ストック = daily 上限と整合)。
            # stockCount = charges // 3 のため、10 戦分には charges 上限 = 30 必要。
            # Pre-mortem S1 対応: charges 加算前に日次リセットを確認。
            # 【FEAT-478 Phase 2b】reset_battle_charges_if_new_day は内部で battle_state を save 済 (更新後の DB 値を再取得)。
            reset_battle_charges_if_new_day(player_obj)
            battle_state = player_obj.battle  # 内部 save 後に最新 DB 状態を取得
            if battle_state.battle_charges < 30:
                battle_state.battle_charges += 1
                event.battle_charges_awarded = True
            else:
                event.battle_charges_awarded = False  # 上限到達、加算されなかった記録
            event.save(update_fields=['battle_charges_awarded'])

            # 【FEAT-419 (2026-06-10)】予定時刻 ±15 分以内 + 同日完了でコイン +5 ボーナス。
            # - 同日条件: 過去日付の予定を後から完了 → 誤発火防止 (Pre-mortem S2)
            # - start_time null ガード: 終日予定は対象外 (Pre-mortem S3)
            # - TZ ずれ防止: timezone.localtime() で必ず localize (Pre-mortem S1)
            ON_TIME_BONUS_COIN     = 5
            ON_TIME_WINDOW_MINUTES = 15

            on_time_bonus = False
            if event.start_time is not None:
                now_local = timezone.localtime()
                if event.date == now_local.date():
                    scheduled = datetime.datetime.combine(
                        event.date, event.start_time, tzinfo=now_local.tzinfo,
                    )
                    delta_sec = abs((now_local - scheduled).total_seconds())
                    if delta_sec <= ON_TIME_WINDOW_MINUTES * 60:
                        on_time_bonus = True

            if on_time_bonus and not event.on_time_bonus_awarded:
                # コイン残高は compute_coins() の派生値 (= Σhabit.total_exp//10 + bonus_coins
                # - coins_spent) のため、コイン直接フィールドは存在しない。
                # 「クエスト報酬コイン」用の bonus_coins を加算する (shop.py compute_coins 参照)。
                # 【FEAT-478 Phase 2b】bonus_coins は PlayerEconomyState 経由で書込。
                economy.bonus_coins += ON_TIME_BONUS_COIN
                event.on_time_bonus_awarded = True
                event.save(update_fields=['on_time_bonus_awarded'])
                economy.save(update_fields=['bonus_coins'])

            # 【FEAT-478 Phase 2b】battle_state を save (level up + battle_charges +1 反映)。
            battle_state.save(update_fields=[
                'current_exp', 'level', 'max_exp', 'allocatable_points', 'battle_charges',
            ])

            # その日最初のタイムライン完了ならダイヤを付与
            diamond_earned = award_diamond_if_first_today(player_obj, today)

            # 【BUG-122 (2026-06-14)】その日初回タスク達成ボーナス
            # (タイムライン予定の完了も「タスク」に含む、ユーザー確認済 2026-06-14)。
            # last_login_diamond_at で当日重複防止、Mobile は non-null で 7 日カレンダー演出表示。
            from ..services.diamond_service import award_daily_first_task_bonus
            today_login_bonus = award_daily_first_task_bonus(player_obj, today)

            # 【FEAT-452 (2026-06-20)】当日 3 回目のタスク達成でフレンドプレゼント
            # popup 候補を抽選。habit_count_service と同じ helper を呼び、3 経路
            # 横断で daily_task_count を共有 (= timeline + habit count + checklist
            # の合計で 3 回目に発火)。
            from ..services.friend_gift_popup_service import check_friend_gift_popup_trigger
            friend_gift_candidate = check_friend_gift_popup_trigger(player_obj, today)

            # 【FEAT-479 (2026-07-06)】その日初回タスク達成でパズルピース (grey) 付与。
            # 【FEAT-479 hotfix (2026-07-06)】旧 `daily_task_count == 1` 外側ガード
            # を撤廃 (habit_count_service と同一措置)。ガードは try_grant_task_piece
            # 内部の `last_task_piece_date == today` で idempotent 化されており冗長。
            # Silent auto-activate 修正との悪循環で今日中に piece 復帰できない
            # 詰み状態を解消するため。
            from ..services.puzzle_world_service import try_grant_task_piece
            puzzle_piece_awarded = try_grant_task_piece(player_obj, today)

        return Response({
            'event':                    TimelineEventSerializer(event).data,
            'exp_gain':                 exp_gain,
            'diamond_earned':           diamond_earned,
            # 【FEAT-398】日次 EXP 閾値到達直後のみ True (Flutter が SnackBar 表示)
            'daily_throttle_triggered': daily_throttle_triggered,
            # 【FEAT-419】予定時刻 ±15 分以内ボーナス
            'on_time_bonus_awarded':    event.on_time_bonus_awarded,
            'on_time_bonus_coin':       ON_TIME_BONUS_COIN if event.on_time_bonus_awarded else 0,
            # 【BUG-122 (2026-06-14)】その日初回タスク達成ボーナス (Day 1/2-7/8+ で配布額変化)
            'today_login_bonus':        today_login_bonus,
            # 【FEAT-452 (2026-06-20)】3 回目のタスク達成でフレンドプレゼント popup 候補
            'friend_gift_candidate':    friend_gift_candidate,
            # 【FEAT-479 (2026-07-06)】その日初回タスク達成でパズルピース (grey) 付与
            'puzzle_piece_awarded':     puzzle_piece_awarded,
        }, status=200)


# ── timeline/<pk>/uncomplete/ ──────────────────────────────────────────────
class TimelineUncompleteView(PlayerMixin, APIView):
    """
    タイムライン予定の完了を取り消す（is_completed = False に戻す）。

    POST /api/timeline/<pk>/uncomplete/
    - すでに未完了の場合は冪等で 200 を返す。
    - EXP・ダイヤは戻さない（誤タップ救済目的のためマイナス補正は行わない）。
    - レスポンス: { event }

    BUG-B: TimelineEventSerializer は is_completed を read_only にしているため、
    フロントから PATCH /timeline/<pk>/ {is_completed: false} を投げても
    silently 無視されていた。専用 POST エンドポイントを設けて意図的な
    取り消しのみを許可する。
    """
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def post(self, request, pk):
        player = self.get_player(request)

        with transaction.atomic():
            try:
                event = TimelineEvent.objects.select_for_update().get(
                    pk=pk, player=player,
                )
            except TimelineEvent.DoesNotExist:
                return error_response(
                    code='timeline_event_not_found',
                    message='予定が見つかりませんでした 🪶',
                    status=404,
                )

            # 冪等：既に未完了なら何もせず 200
            if not event.is_completed:
                return Response({
                    'event': TimelineEventSerializer(event).data,
                    'exp_refund': 0,
                }, status=200)

            event.is_completed = False
            event.save(update_fields=['is_completed'])

            # ── 付与済み EXP を返却（complete → uncomplete → complete ループによる無限増殖を防ぐ）
            exp_refund = calc_timeline_exp(event)
            player_obj = PlayerProfile.objects.select_for_update().get(pk=player.pk)

            # 【FEAT-478 Phase 2b (2026-07-04)】NEW state proxy 経由で書込。
            # TimelineCompleteView と対称の write path として、current_exp / battle_charges /
            # bonus_coins をそれぞれ PlayerBattleState / PlayerEconomyState に書き換える。
            battle_state = player_obj.battle       # PlayerBattleState (proxy)
            economy      = player_obj.economy      # PlayerEconomyState (proxy)

            battle_state.current_exp = max(0, battle_state.current_exp - exp_refund)

            # 【FEAT-398 第 3 段階 / Pre-mortem #12】TimelineEvent 取り消し経路での
            # battle_charges 対称デクリメント (案 B フラグ管理)。
            # battle_charges_awarded=True なら charges -1 + フラグ False。
            # False なら無処理 (migration 前の旧データ or 上限 9 で加算されなかった)。
            battle_save_fields = ['current_exp']
            if event.battle_charges_awarded:
                battle_state.battle_charges = max(0, battle_state.battle_charges - 1)
                event.battle_charges_awarded = False
                event.save(update_fields=['battle_charges_awarded'])
                battle_save_fields.append('battle_charges')

            # 【FEAT-419】予定時刻ボーナスの対称デクリメント (FEAT-398 同パターン)。
            # 取り消し時に bonus 受領済 (=True) なら bonus_coins -5 + フラグ False。
            if event.on_time_bonus_awarded:
                economy.bonus_coins = max(0, economy.bonus_coins - 5)
                event.on_time_bonus_awarded = False
                event.save(update_fields=['on_time_bonus_awarded'])
                economy.save(update_fields=['bonus_coins'])

            # レベル巻き戻しは保守性が低いため current_exp のみ減算（HabitCountView の minus 経路と同方針）
            battle_state.save(update_fields=battle_save_fields)

        return Response({
            'event':      TimelineEventSerializer(event).data,
            'exp_refund': exp_refund,
        }, status=200)
