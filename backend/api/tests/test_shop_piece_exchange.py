"""【FEAT-497 (2026-08-04)】交換ピース消費経路の契約テスト。

## 何を守るか

`PlayerProfile.exchange_pieces` は重複ガチャの救済 (100 pieces) で **貯まる一方**
だった。消費経路がコード全体でゼロの dead currency で、v1.0 では Duplicate
ダイアログから選択肢ごと撤去していた。本 FEAT がその消費先を作る。

### 🔴 最も危険な失敗は「0 コインで買えてしまう」

piece entry は `price` も `diamond_price` も 0。ShopPurchaseView は

    diamond_price > 0        -> ダイヤ経路
    (それ以外)                -> コイン経路 (汎用購入で price を引く)

の順で分岐するので、**ピース分岐を diamond より前に置き忘れると
`price=0` の汎用コイン購入に落ちて、ピースを 1 つも持っていなくても
無限に買える**。しかも 201 が返るので例外もエラーも出ない。
S6 がこれを縛る。

### 次に危険なのは「消費したのに何も増えない」

上限に当たった場合にピースだけ減ると、ユーザーから見て消えたことになる。
S3 が「上限時は **ピースを減らさずに** 400」を縛る。
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.constants import GameBalance
from api.models import PlayerItem, PlayerProfile
from ._error_assert import error_code

User = get_user_model()


_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework.authtoken.authentication.TokenAuthentication',
        'api.authentication.GuestTokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
}


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class PieceExchangeTest(APITestCase):
    """交換ピースを通貨として消費する 3 entry の契約。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('piece_user', email='p@example.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='Piece', exchange_pieces=1000,
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    def _buy(self, item_id):
        return self.client.post(
            reverse('shop-purchase'), data={'item_id': item_id}, format='json',
        )

    # ─────────────────────────────────────────────────────────────────
    # S1: XP ブースト交換 (100 pieces -> PlayerItem +1)
    # ─────────────────────────────────────────────────────────────────
    def test_xp_boost_exchange_grants_item_and_spends_pieces(self):
        res = self._buy('piece_xp_boost')
        self.assertEqual(res.status_code, http_status.HTTP_201_CREATED, res.content)
        self.assertEqual(res.data['exchange_pieces'], 900)
        self.assertEqual(res.data['granted_item_id'], 'xp_boost_1.5x')
        self.assertEqual(res.data['owned_quantity'], 1)

        self.player.refresh_from_db()
        self.assertEqual(self.player.exchange_pieces, 900)
        item = PlayerItem.objects.get(player=self.player, item_id='xp_boost_1.5x')
        self.assertEqual(item.quantity, 1)

    def test_xp_boost_exchange_is_repeatable_and_accumulates(self):
        self._buy('piece_xp_boost')
        res = self._buy('piece_xp_boost')
        self.assertEqual(res.status_code, http_status.HTTP_201_CREATED)
        self.assertEqual(res.data['owned_quantity'], 2)
        self.player.refresh_from_db()
        self.assertEqual(self.player.exchange_pieces, 800)

    # ─────────────────────────────────────────────────────────────────
    # S2: 出陣チケット交換 (100 pieces -> battle_charges +5)
    # ─────────────────────────────────────────────────────────────────
    def test_battle_charge_exchange_adds_five_charges(self):
        battle = self.player.battle
        battle.battle_charges = 0
        battle.save(update_fields=['battle_charges'])

        res = self._buy('piece_battle_charge')
        self.assertEqual(res.status_code, http_status.HTTP_201_CREATED, res.content)
        self.assertEqual(res.data['battle_charges'], 5)
        self.assertEqual(res.data['exchange_pieces'], 900)

        battle.refresh_from_db()
        self.assertEqual(battle.battle_charges, 5)

    # ─────────────────────────────────────────────────────────────────
    # S3: 上限に当たる場合は **ピースを減らさずに** 断る
    # ─────────────────────────────────────────────────────────────────
    def test_battle_charge_at_cap_rejects_without_spending_pieces(self):
        battle = self.player.battle
        # 28 + 5 = 33 > 30。「5 枚買ったのに 2 枚しか増えない」を避けて購入自体を断る
        battle.battle_charges = GameBalance.BATTLE_CHARGES_MAX - 2
        battle.save(update_fields=['battle_charges'])

        res = self._buy('piece_battle_charge')
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        self.assertEqual(error_code(res), 'shop_piece_battle_charge_max')

        battle.refresh_from_db()
        self.player.refresh_from_db()
        self.assertEqual(battle.battle_charges, GameBalance.BATTLE_CHARGES_MAX - 2,
                         msg='上限拒否でチケットは変化しないはず')
        self.assertEqual(self.player.exchange_pieces, 1000,
                         msg='🔴 効果が付かなかったのにピースが減っている')

    # ─────────────────────────────────────────────────────────────────
    # S4: キャラ交換券 (500 pieces -> character_exchange_tickets +1)
    # ─────────────────────────────────────────────────────────────────
    def test_character_ticket_exchange_grants_ticket(self):
        res = self._buy('piece_character_ticket')
        self.assertEqual(res.status_code, http_status.HTTP_201_CREATED, res.content)
        self.assertEqual(res.data['character_exchange_tickets'], 1)
        self.assertEqual(res.data['exchange_pieces'], 500)

        self.player.refresh_from_db()
        self.assertEqual(self.player.economy.character_exchange_tickets, 1)
        self.assertEqual(self.player.exchange_pieces, 500)

    def test_character_ticket_costs_five_times_the_consumables(self):
        """レート (500 : 100) が意図せず変わっていないこと。

        100 pieces にすると重複 1 回で SSR 1 体になり、
        「21 日の習慣達成で 1 体」(FEAT-433) と釣り合わなくなる。
        """
        from api.views.shop import _CATALOG_BY_ID
        self.assertEqual(_CATALOG_BY_ID['piece_character_ticket']['piece_price'], 500)
        self.assertEqual(_CATALOG_BY_ID['piece_xp_boost']['piece_price'], 100)
        self.assertEqual(_CATALOG_BY_ID['piece_battle_charge']['piece_price'], 100)

    # ─────────────────────────────────────────────────────────────────
    # S5: ピース不足
    # ─────────────────────────────────────────────────────────────────
    def test_not_enough_pieces_rejects(self):
        self.player.exchange_pieces = 99
        self.player.save(update_fields=['exchange_pieces'])

        res = self._buy('piece_xp_boost')
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        self.assertEqual(error_code(res), 'shop_piece_not_enough')
        self.assertEqual(res.data['exchange_pieces'], 99)
        self.assertEqual(res.data['required'], 100)

        self.player.refresh_from_db()
        self.assertEqual(self.player.exchange_pieces, 99)
        self.assertFalse(
            PlayerItem.objects.filter(
                player=self.player, item_id='xp_boost_1.5x').exists(),
            msg='拒否されたのにアイテムが付与されている',
        )

    # ─────────────────────────────────────────────────────────────────
    # S6: 🔴 コイン経路に落ちて「0 コインで買える」ことがない
    # ─────────────────────────────────────────────────────────────────
    def test_piece_item_never_falls_through_to_free_coin_purchase(self):
        """ピース 0 枚で全 piece entry を叩いても 1 つも通らないこと。

        piece entry は price=0 / diamond_price=0 なので、ピース分岐を
        diamond 分岐より **前** に置き忘れると、コイン経路の汎用購入が
        `available_coins < 0` を満たしてしまい **タダで買えて 201 が返る**。
        例外もエラーも出ないので、これを落とせるのはこのテストだけ。
        """
        self.player.exchange_pieces = 0
        self.player.save(update_fields=['exchange_pieces'])

        for item_id in ('piece_xp_boost', 'piece_battle_charge',
                        'piece_character_ticket'):
            with self.subTest(item_id=item_id):
                res = self._buy(item_id)
                self.assertEqual(
                    res.status_code, http_status.HTTP_400_BAD_REQUEST,
                    msg=f'🔴 {item_id} がピース 0 枚で購入できてしまいました '
                        f'(status={res.status_code})。ピース分岐が '
                        f'diamond / coin 経路より後ろに落ちていないか確認してください',
                )

        self.player.refresh_from_db()
        self.assertEqual(self.player.exchange_pieces, 0)
        self.assertFalse(PlayerItem.objects.filter(player=self.player).exists())
        self.assertEqual(self.player.economy.character_exchange_tickets, 0)

    # ─────────────────────────────────────────────────────────────────
    # S7: カタログ露出 (Mobile が価格を描画できること)
    # ─────────────────────────────────────────────────────────────────
    def test_catalog_exposes_piece_price_and_category(self):
        res = self.client.get(reverse('shop-items'))
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)
        by_id = {it['id']: it for it in res.data['items']}

        for item_id, expected in (('piece_xp_boost', 100),
                                  ('piece_battle_charge', 100),
                                  ('piece_character_ticket', 500)):
            with self.subTest(item_id=item_id):
                self.assertIn(item_id, by_id, msg='カタログに出ていない')
                self.assertEqual(by_id[item_id]['piece_price'], expected)
                self.assertEqual(by_id[item_id]['category'], 'pieces')
                self.assertEqual(by_id[item_id]['price'], 0)
                self.assertEqual(by_id[item_id]['diamond_price'], 0)

    def test_piece_items_are_not_sellable(self):
        """price / diamond_price が 0 なので売却価格も 0 = 売れない。"""
        res = self.client.get(reverse('shop-items'))
        by_id = {it['id']: it for it in res.data['items']}
        for item_id in ('piece_xp_boost', 'piece_battle_charge',
                        'piece_character_ticket'):
            with self.subTest(item_id=item_id):
                self.assertEqual(by_id[item_id]['sell_price'], 0)
