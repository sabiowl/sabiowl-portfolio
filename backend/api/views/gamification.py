from rest_framework import status
from rest_framework.authentication import TokenAuthentication
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from django.db import transaction
from django.db.models import Q

from ..authentication import GuestTokenAuthentication  # FEAT-190
from ..models import Character, OwnedCharacter, PlayerProfile
from ..permissions import IsAuthenticatedOrGuest  # FEAT-187
from ..serializers import CharacterSerializer
from ..views.shop import compute_coins
from ._error_helpers import error_response  # 【FEAT-475 Phase 3c】新形式統一
from .mixins import PlayerMixin



class CharacterListView(PlayerMixin, APIView):
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def get(self, request):
        player     = self.get_player(request)
        owned_ids  = set(
            OwnedCharacter.objects.filter(player=player)
            .values_list('character_id', flat=True)
        )
        # 【2026-06-27】is_published フラグで段階公開を制御。
        # 表示対象 (3 条件 OR、distinct で重複排除):
        #   1) is_published=True               運営が公開設定済 (通常公開)
        #   2) is_starter=True                 オンボーディング保護 (sol/aria、admin 誤操作対策)
        #   3) id IN owned_ids                 所持済キャラは常時表示 (購入済資産の保護、
        #                                       仮に非公開化されても active 表示維持)
        characters = Character.objects.filter(
            Q(is_published=True) | Q(is_starter=True) | Q(id__in=owned_ids)
        ).distinct()
        active_id = player.active_character_id

        result = []
        for c in characters:
            result.append({
                **CharacterSerializer(c, context={"request": request}).data,
                'owned':  c.id in owned_ids,
                'active': c.id == active_id,
            })
        return Response(result)


class CharacterSelectView(PlayerMixin, APIView):
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def post(self, request, pk):
        player = self.get_player(request)
        try:
            character = Character.objects.get(pk=pk)
        except Character.DoesNotExist:
            # 【2026-07-06 review】サビ口調統一 (CharacterExchangeView と同パターン)
            return error_response(
                code='character_select_not_found',
                message='キャラクターが見つかりませんでした 🪶',
                status=404,
            )

        owned = OwnedCharacter.objects.filter(player=player, character=character).exists()
        if not owned:
            # 【2026-06-27】非公開キャラの無料付与 (starter ガード経由) を防止。
            # 既に所持済キャラ (owned=True) はそのまま active 切替可能 (購入済資産の保護)。
            if not character.is_published and not character.is_starter:
                return error_response(
                           code='not_published',
                           message='このキャラクターは現在非公開です 🪶',
                           status=status.HTTP_403_FORBIDDEN,
                       )
            if character.is_starter:
                OwnedCharacter.objects.create(player=player, character=character)
            else:
                return error_response(
                           code='not_owned',
                           message='まだお持ちでないキャラクターです 🪶',
                           status=403,
                       )

        player.active_character = character
        player.save(update_fields=['active_character'])
        return Response({
            'detail': '切り替えました 🪶',
            'active_character': CharacterSerializer(character, context={"request": request}).data,
        })


class CharacterPurchaseView(PlayerMixin, APIView):
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def post(self, request, pk):
        player = self.get_player(request)
        try:
            character = Character.objects.get(pk=pk)
        except Character.DoesNotExist:
            # 【2026-07-06 review】サビ口調統一 (CharacterExchangeView と同パターン)
            return error_response(
                code='character_purchase_not_found',
                message='キャラクターが見つかりませんでした 🪶',
                status=404,
            )

        # 【2026-06-27】非公開キャラの直接購入を防止 (段階公開機能のガード)。
        # Mobile 側で UI から消えていても、API への直接 POST は防げないため Backend
        # でも明示的にガード (race + 信頼境界)。starter は本フラグに関わらず購入可能
        # にする必要はない (starter は無料付与経路、購入対象外)。
        if not character.is_published:
            return error_response(
                       code='not_published',
                       message='このキャラクターは現在非公開です 🪶',
                       status=status.HTTP_403_FORBIDDEN,
                   )

        # 【BUG-133 (2026-06-17)】Lv チェック撤去。「キャラはレベルで開放する仕様
        # ではない」(PM 判断) により、ダイヤ価格のみが入手障壁。Character.unlock_level
        # field は互換性のため残置 (新仕様で参照されない、UI 側も削除済)。

        with transaction.atomic():
            player = PlayerProfile.objects.select_for_update().get(pk=player.pk)
            locked_eco = player.economy

            if OwnedCharacter.objects.filter(player=player, character=character).exists():
                return error_response(
                           code='already_owned',
                           message='すでにお持ちのキャラクターです 🪶',
                           status=400,
                       )

            # 【FEAT-389 (2026-05-30)】コイン → ダイヤ消費に変更。
            if locked_eco.diamonds < character.price:
                return error_response(
                           code='not_enough_diamonds',
                           message=f'ダイヤが少し足りません。現在 {locked_eco.diamonds}💎、必要 {character.price}💎 です 🪶',
                           status=400,
                       )

            locked_eco.diamonds -= character.price
            locked_eco.save(update_fields=['diamonds'])
            OwnedCharacter.objects.create(player=player, character=character)

        return Response({
            'detail':    f'{character.name} を迎えました 🪶',
            'diamonds':  locked_eco.diamonds,
            'character': CharacterSerializer(character, context={"request": request}).data,
        })


class CharacterExchangeView(PlayerMixin, APIView):
    """POST /api/characters/<int:pk>/exchange/

    【FEAT-427 (2026-06-11)】マンスリー天井で配布される character_exchange_tickets
    を 1 枚消費して、未所持の SSR キャラクターを獲得する。
    【BUG-108 (2026-06-14)】SSR 判定基準を price >= 3000 → is_starter=False に変更。
    BUG-107 で全 non-starter 価格を 1500 に統一した結果、price 基準が機能しなく
    なったため、starter かどうかで判定する (non-starter = 全て SSR 扱い)。
    """
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def post(self, request, pk):
        player = self.get_player(request)

        try:
            character = Character.objects.get(pk=pk)
        except Character.DoesNotExist:
            return error_response(
                code='character_exchange_not_found',
                message='キャラクターが見つかりませんでした 🪶',
                status=404,
            )

        # 【2026-06-27】非公開キャラの交換券消費も防止 (段階公開機能のガード)。
        # exchange は SSR 確定チケット消費経路。非公開キャラと交換するとチケットだけ
        # 消費されて何も得られない事故を防ぐ。
        if not character.is_published:
            return error_response(
                       code='not_published',
                       message='このキャラクターは現在非公開です 🪶',
                       status=status.HTTP_403_FORBIDDEN,
                   )

        # 【BUG-108】starter (sol/aria) は交換対象外 (= 全 non-starter が SSR 扱い)。
        if character.is_starter:
            return error_response(
                       code='not_ssr',
                       message='SSR キャラのみ交換可能です 🪶',
                       status=status.HTTP_400_BAD_REQUEST,
                   )

        with transaction.atomic():
            player = PlayerProfile.objects.select_for_update().get(pk=player.pk)
            locked_eco = player.economy

            if locked_eco.character_exchange_tickets < 1:
                return error_response(
                           code='no_ticket',
                           message='キャラ交換券が不足しています 🪶',
                           status=status.HTTP_400_BAD_REQUEST,
                       )

            if OwnedCharacter.objects.filter(player=player, character=character).exists():
                return error_response(
                           code='already_owned',
                           message='すでにお持ちのキャラです 🪶',
                           status=status.HTTP_400_BAD_REQUEST,
                       )

            locked_eco.character_exchange_tickets -= 1
            locked_eco.save(update_fields=['character_exchange_tickets'])
            OwnedCharacter.objects.create(player=player, character=character)

        return Response({
            'detail': f'{character.name} を獲得しました 🪶',
            'character_exchange_tickets': locked_eco.character_exchange_tickets,
            'character': CharacterSerializer(character, context={"request": request}).data,
        })
