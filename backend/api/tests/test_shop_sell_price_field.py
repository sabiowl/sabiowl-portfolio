"""【codebase_review 20260704 P3-#8 (2026-07-05)】ShopItemsView `sell_price` 単一真実値契約。

Mobile 側の `item.price ~/ 2` 独自計算を撤廃し、Backend `_calc_sell_price_coins`
の返却値のみを参照する統一設計にした際の regression guard。

契約:
- /api/shop/items/ レスポンスの各 item に `sell_price` field が必ず含まれる
- コイン価格アイテム (price > 0) → `sell_price = price // 2`
- ダイヤ価格アイテム (diamond_price > 0, price=0) → `sell_price = 0` (売却不可)
- 売却不可 item_type (gacha_only / slot_expansion / streak_protection /
  consumable / battle_consumable) → 対応する `_calc_sell_price_coins` の結果

将来 SHOP_CATALOG に新規アイテムを追加する際、`_calc_sell_price_coins` の
分岐に該当しないと `sell_price` が 0 になり Mobile が「売却不可」表示になる
安全側フォールバック。
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import PlayerProfile

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
class ShopSellPriceFieldContractTest(APITestCase):
    """【codebase_review 20260704 P3-#8】ShopItemsView に sell_price が付与される契約。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(
            'shop_seller', email='ss@example.com',
        )
        self.player = PlayerProfile.objects.create(
            user=self.user, name='SellTester',
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    def test_all_items_have_sell_price_field(self):
        """/api/shop/items/ の全 item に `sell_price` field が存在する。"""
        res = self.client.get(reverse('shop-items'))
        self.assertEqual(res.status_code, 200, res.content)
        items = res.data['items']
        self.assertGreater(len(items), 0, '前提: SHOP_CATALOG に entry がある')

        for item in items:
            self.assertIn(
                'sell_price', item,
                f'item id={item.get("id")} に sell_price 欠落 = Backend regression。'
                f'Mobile の item.sellPrice が default 0 (売却不可 fallback) になる。',
            )
            self.assertIsInstance(
                item['sell_price'], int,
                f'sell_price は int であるべき (item={item.get("id")})',
            )
            self.assertGreaterEqual(
                item['sell_price'], 0,
                f'sell_price は 0 以上 (item={item.get("id")})',
            )

    def test_coin_priced_item_returns_half_sell_price(self):
        """コイン価格アイテム (ticket_daily, price=100) は `sell_price = price // 2`。"""
        res = self.client.get(reverse('shop-items'))
        items = {it['id']: it for it in res.data['items']}
        # ticket_daily は SHOP_CATALOG に確定で入っている (SEC-12 / BUG-113)。
        # 存在しない場合は前提破綻なので skip でなく assert 失敗させる。
        self.assertIn(
            'ticket_daily', items,
            '前提: ticket_daily は SHOP_CATALOG に存在するべき (SEC-12)',
        )
        ticket_daily = items['ticket_daily']
        self.assertEqual(
            ticket_daily['sell_price'], ticket_daily['price'] // 2,
            'コイン価格アイテムの sell_price は price // 2 になるべき (Backend '
            '_calc_sell_price_coins 契約)。異なる場合は Mobile item.price ~/ 2 の '
            '独自計算に回帰した可能性 (P3-#8 の drift 再発シグナル)。',
        )

    def test_diamond_priced_item_returns_zero_sell_price(self):
        """ダイヤ価格アイテム (recovery_potion, diamond_price=30, price=0) は
        `sell_price = 0` (売却不可)。Mobile は `sellPrice > 0` で売却可否判定。
        """
        res = self.client.get(reverse('shop-items'))
        items = {it['id']: it for it in res.data['items']}
        self.assertIn(
            'recovery_potion', items,
            '前提: recovery_potion は SHOP_CATALOG に存在するべき (FEAT-298)',
        )
        recovery = items['recovery_potion']
        self.assertEqual(
            recovery['price'], 0,
            '前提: recovery_potion は price=0 (ダイヤ購入のみ)',
        )
        self.assertGreater(
            recovery['diamond_price'], 0,
            '前提: recovery_potion は diamond_price > 0',
        )
        self.assertEqual(
            recovery['sell_price'], 0,
            'ダイヤ価格アイテムは sell_price = 0 (売却不可)。0 以外なら '
            'Backend _calc_sell_price_coins の diamond 判定漏れ (currency mismatch)。',
        )
