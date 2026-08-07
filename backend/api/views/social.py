import logging

from rest_framework import status
from rest_framework.authentication import TokenAuthentication
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView

from ..permissions import IsAuthenticatedOrGuest  # 【2026-06-29】フレンド機能ゲスト開放

from django.db import transaction
from django.db.models import Count, Prefetch, Q
from django.utils import timezone  # NEW-06: タイムゾーン対応の日付取得

from ..constants import FriendStatus
# 【FEAT-446 (2026-06-20)】Message モデル / MessageSerializer は MessageView 廃止に伴い
# import から削除。モデル自体は residual data 保全のため残置 (FEAT-250 反省遵守)。
# 【FEAT-451 (2026-06-20)】Gift View が PlayerItem (xp_boost_1.5x) を作成するため import 追加。
from ..models import Friendship, Gift, HabitLog, PlayerItem, PlayerProfile, Habit
from ..serializers import FriendPlayerSerializer, FriendshipSerializer
from ..i18n_messages import gift_part_label, resolve_player_locale  # 【FEAT-517】
from ..services.push_service import create_localized_notification  # 【FEAT-517】
from ._error_helpers import error_response  # 【FEAT-475 Phase 3c】新形式統一
from .mixins import PlayerMixin

_logger = logging.getLogger(__name__)



class FriendSearchView(PlayerMixin, APIView):
    # 【2026-06-29】ゲストモード開放: フレンド機能はゲスト (user=null) の
    # PlayerProfile でも動作するため、IsAuthenticatedOrGuest に変更。
    # 悪用対策は既存の Throttle + 重複申請ガードで担保 (追加 Throttle は入れない)。
    permission_classes = [IsAuthenticatedOrGuest]
    throttle_classes   = [ScopedRateThrottle]
    throttle_scope     = 'friend_search'

    def get(self, request):
        player = self.get_player(request)
        friend_id = request.query_params.get('friend_id', '').strip()
        # 【FEAT-423 (2026-06-10)】後方互換: 旧形式 (XXXX-XXXX) でメモしている
        # ユーザーの入力も受容するため、`-` を除去してから検索する。
        friend_id = friend_id.replace('-', '')
        if not friend_id:
            return Response({'detail': 'friend_id is required.'}, status=status.HTTP_400_BAD_REQUEST)

        try:
            # 【BUG-100】FriendPlayerSerializer.active_character の単発取得
            target = (
                PlayerProfile.objects
                .select_related('active_character')
                .get(friend_id=friend_id)
            )
        except PlayerProfile.DoesNotExist:
            return Response({'detail': 'not_found'}, status=status.HTTP_404_NOT_FOUND)

        if target == player:
            return Response({'detail': 'self'}, status=status.HTTP_400_BAD_REQUEST)

        existing = Friendship.objects.filter(
            (Q(from_player=player) & Q(to_player=target)) |
            (Q(from_player=target) & Q(to_player=player))
        ).first()

        data = FriendPlayerSerializer(target).data
        data['relation'] = existing.status if existing else 'none'
        data['relation_from_me'] = (existing.from_player == player) if existing else False
        return Response(data)


def _friend_player_lite_dict(p):
    """【BUG-115 (2026-06-14)】incoming / sent_requests / search 用の軽量 player dict。

    手動構築の `player` dict に `active_character` を含めるための単一真実値ヘルパー。
    旧実装は手動 dict 内に active_character を欠落させており、Mobile 側で
    `FriendPlayer.fromJson` が `j['active_character']` を null と読み、avatar が
    fallback (zenon) に退行していた (BUG-114 副次として観測)。

    `FriendPlayerSerializer` 全フィールドは含めない (public_habits/best_streak/
    monthly_rate の SerializerMethodField が habits を fetch して N+1 化するため。
    incoming/sent では habits の prefetch なし、それらの field 値は Mobile で
    未参照なのでこちらの軽量経路で十分)。
    """
    char = p.active_character
    return {
        'id':        p.id,
        'name':      p.name,
        # 【FEAT-478 Phase 2b hotfix (2026-07-05、codebase_review 20260704 P1-新)】
        # p.level (旧 PlayerProfile.level) は Phase 2b 以降どこからも書き込まれない
        # 孤立フィールド。NEW state proxy 経由で最新レベルを取得する。
        'level':     p.battle.level,
        'friend_id': p.friend_id,
        'active_character': {
            'key':        char.key,
            'name':       char.name,
            'image_path': char.image_path,
        } if char else None,
    }


class FriendRequestView(PlayerMixin, APIView):
    # 【2026-06-29】ゲストモード開放: フレンド機能はゲスト (user=null) の
    # PlayerProfile でも動作するため、IsAuthenticatedOrGuest に変更。
    # 悪用対策は既存の Throttle + 重複申請ガードで担保 (追加 Throttle は入れない)。
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        player = self.get_player(request)
        # 【BUG-100】FriendPlayerSerializer.active_character の N+1 防御
        requests = (
            Friendship.objects
            .filter(to_player=player, status=FriendStatus.PENDING)
            .select_related('from_player', 'from_player__active_character')
        )
        data = []
        for fr in requests:
            data.append({
                'id':         fr.id,
                'created_at': fr.created_at,
                # 【BUG-115 (2026-06-14)】player dict に active_character を含める。
                # 旧実装は active_character 欠落で Mobile avatar が zenon fallback 化していた。
                'player': _friend_player_lite_dict(fr.from_player),
            })
        return Response(data)

    def post(self, request):
        player = self.get_player(request)
        friend_id = request.data.get('friend_id', '').strip()
        # 【FEAT-423 (2026-06-10)】後方互換: 旧形式 (XXXX-XXXX) でメモしている
        # ユーザーの入力も受容するため、`-` を除去してから検索する。
        friend_id = friend_id.replace('-', '')
        if not friend_id:
            return Response({'detail': 'friend_id is required.'}, status=status.HTTP_400_BAD_REQUEST)

        try:
            target = PlayerProfile.objects.get(friend_id=friend_id)
        except PlayerProfile.DoesNotExist:
            return Response({'detail': 'not_found'}, status=status.HTTP_404_NOT_FOUND)

        if target == player:
            return Response({'detail': 'self'}, status=status.HTTP_400_BAD_REQUEST)

        # NEW-02 / BUG-2026-03: 双方向 Friendship を transaction.atomic で囲む。
        # PostgreSQL の `SELECT ... FOR UPDATE` は行が存在しないとロックを取得しないため、
        # 旧実装は A→B / B→A の同時申請で両方が reverse=None を読み、結果として
        # 双方が pending のまま残り相互フレンドが成立しない問題があった。
        # 2 人の PlayerProfile を id 昇順でロックして rendezvous させ、
        # その後で reverse をチェックすることで必ずどちらか一方が ACCEPT 経路に合流する。
        with transaction.atomic():
            a_id, b_id = sorted([player.pk, target.pk])
            list(
                PlayerProfile.objects
                .select_for_update()
                .filter(pk__in=[a_id, b_id])
                .order_by('pk')
            )

            reverse = (
                Friendship.objects
                .select_for_update()
                .filter(from_player=target, to_player=player, status=FriendStatus.PENDING)
                .first()
            )
            if reverse:
                reverse.status = FriendStatus.ACCEPTED
                reverse.save(update_fields=['status'])
                reverse_id = reverse.id
                accepted_path = True
            else:
                fr, created = Friendship.objects.get_or_create(
                    from_player=player, to_player=target,
                )
                accepted_path = False

        # 通知送信は外側で（lock 短縮）。返却 ID も外で確定させる。
        if accepted_path:
            # BUG-08: 申請元（target）へフレンド成立通知を送信
            create_localized_notification(
                target,
                'friend_accepted',
                'friend_accepted',
                related_id=reverse_id,
                player_name=player.name,
            )
            return Response({'detail': 'accepted', 'id': reverse_id}, status=status.HTTP_200_OK)

        if not created:
            return Response({'detail': 'already_exists', 'status': fr.status}, status=status.HTTP_200_OK)
        create_localized_notification(
            target,
            'friend_request',
            'friend_request',
            related_id=fr.id,
            player_name=player.name,
        )
        return Response({'detail': 'sent', 'id': fr.id}, status=status.HTTP_201_CREATED)


class FriendRequestActionView(PlayerMixin, APIView):
    # 【2026-06-29】ゲストモード開放: フレンド機能はゲスト (user=null) の
    # PlayerProfile でも動作するため、IsAuthenticatedOrGuest に変更。
    # 悪用対策は既存の Throttle + 重複申請ガードで担保 (追加 Throttle は入れない)。
    permission_classes = [IsAuthenticatedOrGuest]

    def post(self, request, pk, action):
        if action not in ('accept', 'decline'):
            return Response({'detail': 'invalid_action'}, status=status.HTTP_400_BAD_REQUEST)

        player = self.get_player(request)

        # NEW-03: accept / decline を atomic + select_for_update で囲み、
        # 同一申請への並列 accept/decline で「accept 通知が残ったまま行が消える」
        # 等の不整合を防ぐ。
        with transaction.atomic():
            try:
                fr = (
                    Friendship.objects
                    .select_for_update()
                    .get(pk=pk, to_player=player, status=FriendStatus.PENDING)
                )
            except Friendship.DoesNotExist:
                return Response({'detail': 'not_found'}, status=status.HTTP_404_NOT_FOUND)

            if action == 'accept':
                fr.status = FriendStatus.ACCEPTED
                fr.save(update_fields=['status'])
                return Response({'detail': 'accepted'})
            else:
                # decline
                fr.delete()
                return Response({'detail': 'declined'})


class FriendListView(PlayerMixin, APIView):
    # 【2026-06-29】ゲストモード開放: フレンド機能はゲスト (user=null) の
    # PlayerProfile でも動作するため、IsAuthenticatedOrGuest に変更。
    # 悪用対策は既存の Throttle + 重複申請ガードで担保 (追加 Throttle は入れない)。
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        player = self.get_player(request)
        today  = timezone.localdate()
        active_habits_qs = Habit.objects.filter(is_active=True)
        friendships = list(
            Friendship.objects.filter(
                Q(from_player=player) | Q(to_player=player),
                status=FriendStatus.ACCEPTED,
            ).select_related(
                'from_player', 'from_player__active_character',
                'to_player',   'to_player__active_character',
            ).prefetch_related(
                # BUG-06: FriendPlayerSerializer の N+1 を解消
                # 【BUG-100】active_character は select_related で同時取得 (N+1 防御)
                Prefetch('from_player__habits', queryset=active_habits_qs, to_attr='active_habits_list'),
                Prefetch('to_player__habits',   queryset=active_habits_qs, to_attr='active_habits_list'),
            )
        )

        # CI-1: get_monthly_rate の N+1 を解消 — 今月の HabitLog をバッチ取得
        friend_profiles = [
            fr.to_player if fr.from_player_id == player.id else fr.from_player
            for fr in friendships
        ]
        all_habit_ids = [
            h.id
            for profile in friend_profiles
            for h in getattr(profile, 'active_habits_list', [])
        ]
        if all_habit_ids:
            rows = (
                HabitLog.objects
                .filter(
                    habit_id__in=all_habit_ids,
                    date__year=today.year,
                    date__month=today.month,
                    count__gt=0,
                )
                .values('habit_id')
                .annotate(log_count=Count('id'))
            )
            monthly_log_count_map = {r['habit_id']: r['log_count'] for r in rows}
        else:
            monthly_log_count_map = {}
        serializer_ctx = {'monthly_log_count_map': monthly_log_count_map}

        # 【BUG-100】FriendPlayerSerializer.active_character の N+1 防御
        sent = (
            Friendship.objects
            .filter(from_player=player, status=FriendStatus.PENDING)
            .select_related('to_player', 'to_player__active_character')
        )

        accepted_data = []
        for fr in friendships:
            other = fr.to_player if fr.from_player == player else fr.from_player
            accepted_data.append({
                'friendship_id': fr.id,
                'player': FriendPlayerSerializer(other, context=serializer_ctx).data,
            })

        sent_data = []
        for fr in sent:
            sent_data.append({
                'friendship_id': fr.id,
                # 【BUG-115 (2026-06-14)】player dict に active_character を含める
                # (BUG-114 副次の avatar fallback 化バグの本格 fix)。
                'player': _friend_player_lite_dict(fr.to_player),
            })

        return Response({
            'friends':       accepted_data,
            'sent_requests': sent_data,
        })

    def delete(self, request, pk):
        player = self.get_player(request)
        fr = Friendship.objects.filter(
            Q(from_player=player) | Q(to_player=player),
            pk=pk,
        ).first()
        if fr is None:
            return Response({'detail': 'not_found'}, status=status.HTTP_404_NOT_FOUND)
        fr.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


class FriendProfileView(PlayerMixin, APIView):
    # 【2026-06-29】ゲストモード開放: フレンド機能はゲスト (user=null) の
    # PlayerProfile でも動作するため、IsAuthenticatedOrGuest に変更。
    # 悪用対策は既存の Throttle + 重複申請ガードで担保 (追加 Throttle は入れない)。
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request, player_id):
        player = self.get_player(request)
        try:
            target = PlayerProfile.objects.get(pk=player_id)
        except PlayerProfile.DoesNotExist:
            return Response({'detail': 'not_found'}, status=status.HTTP_404_NOT_FOUND)

        is_friend = Friendship.objects.filter(
            Q(from_player=player, to_player=target) |
            Q(from_player=target, to_player=player),
            status=FriendStatus.ACCEPTED,
        ).exists()

        if not is_friend:
            return Response({'detail': 'not_friend'}, status=status.HTTP_403_FORBIDDEN)

        fr = Friendship.objects.filter(
            Q(from_player=player, to_player=target) |
            Q(from_player=target, to_player=player),
            status=FriendStatus.ACCEPTED,
        ).first()

        data = FriendPlayerSerializer(target).data
        data['friendship_id'] = fr.id if fr else None
        # 【2026-07-02】per-friend 1/day gift 制限に伴い、UI ボタン非活性判定用フラグ。
        # sender=player × receiver=target のペアで今日 Gift が 1 件以上あれば True。
        # Mobile 側で friend_profile_page.dart の「XP ブーストを贈る」ボタンを
        # 非活性化し、誤タップと重複送信 API リクエストを抑止する。
        today = timezone.localdate()
        data['has_gifted_today'] = Gift.objects.filter(
            sender=player, receiver=target, sent_at__date=today,
        ).exists()
        return Response(data)


class GiftView(PlayerMixin, APIView):
    """【FEAT-451 → 2026-07-02 拡張 → FEAT-490 (2026-07-09) 拡張】フレンドへのプレゼントを
    「XP ブースト単品」から「XP ブースト + コイン + バトルチャージ」の 3 種セットに拡張。

    旧仕様 (〜FEAT-450):
      - body: {'diamonds': 1〜3}
      - sender.diamonds -= N → receiver.diamonds += N (zero-sum ダイヤ transfer)
      - 1日1フレンドにつき1個

    中間仕様 (FEAT-451、2026-06-20〜2026-07-01):
      - body: {} / sender コストなし / receiver.PlayerItem(xp_boost_1.5x) +1
      - 1日1個 total (sender 視点で全フレンド合計 1 個まで)

    中間仕様 (2026-07-02〜FEAT-490):
      - body: {} / sender コストなし / receiver.PlayerItem(xp_boost_1.5x) +1
      - 1日1個 per-friend (sender × receiver ペアで 1 個 / 日)
        → 全フレンドに毎日 1 個ずつ贈れるようになった

    【新仕様 (FEAT-490、2026-07-09〜)】3 種セット化:
      - **XP ブースト 15 min**: 現行通り、cap なし = 全 sender 分もらえる
        (「静かな贈与」の中心、friend 数分の応援を素直に受け取れる)
      - **コイン +20 固定**: 受け取り側で **1 日 3 senders まで** cap
        (heavy user が friend 数だけ passive income を得るのを防ぐ、
        設計時試算: 3 senders × 20 = 60 coins/日 = habit 6 件分相当)
      - **バトルチャージ +1**: 受け取り側で **1 日 3 senders まで** cap +
        既存 storage cap 30 (Habit / Timeline / Checklist と shared)
        (Gift だけで main loop を crowd out しない、
        設計時試算: 3 charges = 1 戦分、daily 10 戦の 10% に抑制)

    【Gift モデル schema】FEAT-490 で `coins_awarded` + `charges_awarded` の 2 field 追加。
    diamonds=0 は継続して sentinel、residual data 保全。cap 到達で 0 が記録される
    (何が実付与されたかを audit 可能に)。

    【設計哲学: sender コスト・見返りゼロの意図 (2026-07-08 codebase_review §3 要素 A 対応)】

    本 view は sender の diamonds / coins / EXP / stat / いかなる資源も変動させず、
    receiver にのみ (FEAT-490 で XP ブースト + コイン + バトルチャージ) を与える
    「純粋な無償贈呈」設計を意図的に採用している。CLAUDE.md の「利己的利他」原則を
    **社会機能** (Gift) では **敢えて破る** ことで、以下の 2 つのプロダクト効果を狙う:

    1. **Sabi の「静穏原則 = 静かな聖域」の実装**:
       - 「贈る = 見返りを得る手段」化すると Gift が経済最適化ゲームに転化し、
         「贈る行為そのものが目的」というサビの世界観 (静かな肯定、比較・誇示禁止)
         と衝突する
       - 現行仕様は「相手を思いやる瞬間を邪魔しないための無償」= サビの声で贈る、
         を構造化した結果

    2. **利己的利他は個人ループ側で完結させる分業設計**:
       - 「利己的利他」= 習慣達成で自分の EXP + 6 stat が増える (CATEGORY_STAT_MAP)
         の個人ループでは構造的に美しく実装されている
       - 社会ループ側 (Gift) にも見返りを持たせると、両ループの動機が混線し、
         「Gift を送るために習慣達成する」逆転が起きうる (Duolingo 系の Friends
         Streaks が抱える誘因反転問題)
       - 個人ループ = 利己的利他 / 社会ループ = 純粋利他 に **敢えて分業** する
         ことで、それぞれの動機を純化する

    次にこのファイルを読む人 (人間 / AI) へ: sender コストゼロは「見落とし」
    ではなく **PM 意思決定の結果** です。将来 gift 見返りロジックを追加する
    提案が上がった場合、上記 2 効果とのトレードオフを必ず再評価すること。
    追加する場合の実装接続点は `CATEGORY_STAT_MAP` の貢献力軸 (+1〜2 EXP)
    が最も自然だが、v1.0 では追加しない。
    """
    authentication_classes = [TokenAuthentication]
    # 【2026-06-29】ゲストモード開放: フレンド機能はゲスト (user=null) の
    # PlayerProfile でも動作するため、IsAuthenticatedOrGuest に変更。
    # 悪用対策は既存の Throttle + 重複申請ガードで担保 (追加 Throttle は入れない)。
    permission_classes = [IsAuthenticatedOrGuest]

    def post(self, request, player_id):
        sender = self.get_player(request)

        if sender.id == player_id:
            return error_response(
                code='social_gift_cannot_send_to_self',
                message='自分には贈れません 🪶',
                status=status.HTTP_400_BAD_REQUEST,
            )

        is_friend = Friendship.objects.filter(
            Q(from_player_id=sender.id, to_player_id=player_id) |
            Q(from_player_id=player_id, to_player_id=sender.id),
            status=FriendStatus.ACCEPTED,
        ).exists()
        if not is_friend:
            return error_response(
                code='social_gift_not_friend',
                message='フレンドにのみ贈れます 🪶',
                status=status.HTTP_403_FORBIDDEN,
            )

        try:
            receiver = PlayerProfile.objects.get(id=player_id)
        except PlayerProfile.DoesNotExist:
            return error_response(
                code='social_gift_receiver_not_found',
                message='プレイヤーが見つかりませんでした 🪶',
                status=status.HTTP_404_NOT_FOUND,
            )

        today = timezone.localdate()

        with transaction.atomic():
            # 【FEAT-451】sender ロックは race 防止 (同時 2 端末からの 2 重送信防止) のため必要。
            # コスト消費はないが、daily 制限チェックの atomicity を担保する。
            sender = PlayerProfile.objects.select_for_update().get(pk=sender.pk)

            # 【2026-07-02】daily 制限を per-sender → per-friend/day に変更。
            # 従来 FEAT-451: sender が今日 1 個でも贈っていれば拒否 (total 1/day)
            # 新: sender × receiver ペアで今日贈っていれば拒否 (per-friend 1/day)
            # これで全フレンドに毎日 1 個ずつ贈れる仕様に。
            if Gift.objects.filter(
                sender=sender, receiver_id=player_id, sent_at__date=today,
            ).exists():
                return error_response(
                    code='social_gift_already_sent_today',
                    message='このフレンドへは、今日もう贈っていますよ。また明日お試しください 🪶',
                    status=status.HTTP_400_BAD_REQUEST,
                )

            # 【FEAT-451】receiver の PlayerItem (xp_boost_1.5x) を +1。
            # 既存 stock があれば quantity += 1、なければ新規作成 (xp_boost は max_stock 無制限)。
            # CLAUDE.md レンデブー順序: PlayerProfile (sender, receiver) → PlayerItem の pk 昇順。
            # receiver も select_for_update で受信側の同時操作 (例: 自身が UseXpBoostView 実行中) と
            # 整合性確保 (実害は低いが規律遵守)。
            receiver_locked = PlayerProfile.objects.select_for_update().get(pk=receiver.pk)
            player_item, created = PlayerItem.objects.select_for_update().get_or_create(
                player=receiver_locked,
                item_id='xp_boost_1.5x',
                defaults={'quantity': 1},
            )
            if not created:
                player_item.quantity += 1
                player_item.save(update_fields=['quantity'])

            # 【FEAT-490 (2026-07-09)】コイン + バトルチャージの 3 種セット化。
            # cap 判定: 受け取り側 (receiver) が今日 **異なる sender から** 何回
            # coins/charges を受け取ったか。1 日 3 senders 上限、超過分は capped
            # (0 記録 = XP boost のみ付与、贈与自体は成立)。
            #
            # 「送信元 sender の distinct 数」で cap する理由: 同じ sender からの
            # 重複はそもそも per-sender 1/day で塞がれている (上の
            # `social_gift_already_sent_today` エラー)。よって Gift.objects.filter(
            # receiver=X, sent_at__date=today, coins_awarded__gt=0
            # ).count() = 「今日 coins を受け取った sender 数」となり、
            # そのまま cap カウンタとして機能する。
            _GIFT_COINS_PER_GRANT   = 20   # 1 回あたりのコイン付与量 (FEAT-490)
            _GIFT_CHARGES_PER_GRANT = 1    # 1 回あたりのバトルチャージ付与量 (FEAT-490)
            _GIFT_DAILY_SENDER_CAP  = 3    # 受け取り側の 1 日 sender 数上限 (FEAT-490)
            _BATTLE_CHARGES_MAX     = 30   # storage cap、Habit / Timeline と shared

            already_received_coin_senders = Gift.objects.filter(
                receiver=receiver_locked, sent_at__date=today,
                coins_awarded__gt=0,
            ).count()
            grant_coins_and_charges = already_received_coin_senders < _GIFT_DAILY_SENDER_CAP

            coins_awarded_now   = 0
            charges_awarded_now = 0
            if grant_coins_and_charges:
                # コイン付与: raw storage は `PlayerEconomyState.bonus_coins`。
                # `compute_coins(player) = habit_earned + bonus_coins - coins_spent` の
                # 中で `bonus_coins` が「習慣以外の全 coin 収入源」を集約する field。
                # battle 報酬 (battle/finish.py:328) と同じ経路に載せる。
                receiver_locked.economy.bonus_coins += _GIFT_COINS_PER_GRANT
                receiver_locked.economy.save(update_fields=['bonus_coins'])
                coins_awarded_now = _GIFT_COINS_PER_GRANT

                # バトルチャージ付与 (storage cap 30 に遵守、超過分は silent skip
                # = habit_count_service.py:533 / timeline.py:327 と同一パターン)
                if receiver_locked.battle.battle_charges < _BATTLE_CHARGES_MAX:
                    receiver_locked.battle.battle_charges += _GIFT_CHARGES_PER_GRANT
                    receiver_locked.battle.save(update_fields=['battle_charges'])
                    charges_awarded_now = _GIFT_CHARGES_PER_GRANT
                # else: 30 到達 → charge は 0 記録 (audit)、coins は grant 継続

            # 【FEAT-451】Gift schema 拡張、diamonds=0 で「新型 gift」sentinel を継続。
            # 【FEAT-490】coins_awarded / charges_awarded で実付与量を記録
            # (cap 到達で 0、audit / analytics に活用可)。
            Gift.objects.create(
                sender=sender, receiver=receiver_locked, diamonds=0,
                coins_awarded=coins_awarded_now,
                charges_awarded=charges_awarded_now,
            )

            # 【FEAT-490 → gameplay_review 20260709 §A-1 対応 (2026-07-09)】
            # 通知本文に **実際に届いた内訳** を反映する。
            # 送信側 (friend_profile_page.dart / friend_gift_popup_listener.dart) は
            # parts.join(' + ') で内訳付き SnackBar を表示済だが、受信側は
            # 「応援が届きましたよ」の汎用文言のみで、コイン / チャージが実際に
            # 入ったか通知だけでは判別不能だった。
            # cap 到達 (受信側の 3 senders/日 or storage 30) を通過した項目のみ
            # 本文に列挙、cap 到達時は「XP ブースト」だけの短い文面になる。
            # 【FEAT-517】受信者の言語で項目名を組み立てる (送信者ではない)。
            _loc = resolve_player_locale(receiver_locked)
            gift_parts = [gift_part_label('xp_boost', _loc)]
            if coins_awarded_now > 0:
                gift_parts.append(
                    gift_part_label('coins', _loc, amount=coins_awarded_now))
            if charges_awarded_now > 0:
                gift_parts.append(
                    gift_part_label('battle_charges', _loc, amount=charges_awarded_now))
            create_localized_notification(
                receiver_locked,
                'gift',
                'gift_received',
                sender_name=sender.name,
                gift_parts=' + '.join(gift_parts),
            )

        return Response({
            # 【FEAT-451】gifted_today: Mobile UI で 1日 1 個制限の達成状態を反映
            'gifted_today':            True,
            'receiver_xp_boost_stock': player_item.quantity,
            # 【FEAT-490】3 種セット化に伴う内訳 (Mobile UI 表示用)。
            #   coins_awarded=0 / charges_awarded=0 は「cap 到達で XP boost のみ付与」を意味。
            'coins_awarded':           coins_awarded_now,
            'charges_awarded':         charges_awarded_now,
        })


# 【FEAT-446 (2026-06-20)】MessageView 削除: フレンド間メッセージ機能を廃止。
# 廃止理由: 余計なトラブルの未然防止 + 悪用防止 (誹謗中傷 / なりすまし / スパム送信等)。
# 旧 GET/POST /api/messages/<player_id>/ エンドポイントを撤去、urls.py の path 登録も削除済。
# Message モデル本体は residual data 保全のため残置 (FEAT-250 反省: 破壊的データ削除は
# migration ではなく management command で実施する原則)。将来必要なら admin or
# management command で archive する設計。Notification.TYPE_CHOICES からも 'message'
# を削除 (新規発火経路ゼロのため)、既存通知レコードは residual で残置。

# 【FEAT-407 (2026-06-01)】PrivacySettingsView 削除: Flutter caller ゼロ確認済。
# FEAT-396 で Flutter 公開設定 UI が撤廃されたため Backend API も不要。
# grep -rn "privacy/|PrivacySettings" mobile/lib → ゼロ件 (2026-06-01 確認)
