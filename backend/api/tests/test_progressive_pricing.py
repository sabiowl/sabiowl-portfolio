"""【FEAT-429 (2026-06-12)】Shop 累進価格 (daily_quest_slot_expand) の契約テスト。

価格は購入回数 (purchase_count, 0-indexed) を元に
calc_progressive_price(purchase_count) = (purchase_count + 1) * SHOP_PROGRESSIVE_PRICE_BASE
で算出する (200 / 400 / 600 / 800 / 1000)。purchase_count >= SHOP_PROGRESSIVE_MAX_COUNT (5) で
それ以上の購入は 400 拒否。

【FEAT-434 (2026-06-14)】Habit 難易度廃止 + Legendary スロット制全廃に伴い、
`legendary_slot_expand` は SHOP_CATALOG から entry 自体を削除済み。旧シナリオ
1-4・8 (legendary_slot_expand の累進価格) は撤廃し、daily_quest_slot_expand
(旧シナリオ 5-7 + 新規追加の動的価格不足シナリオ) のみ検証する。

検証対象 (4 シナリオ):
1. クエスト枠 1 回目購入 = 200💎 (daily_battle_limit_purchase_count 0→1)
2. クエスト枠 5 回目購入 = 1000💎 (purchase_count 4→5)
3. クエスト枠 6 回目購入は 400 拒否
4. ダイヤ不足時の 400 (動的価格に対する正確な計算)
"""
from django.contrib.auth import get_user_model
from django.test import override_settings
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.constants import SHOP_PROGRESSIVE_MAX_COUNT, calc_progressive_price
from api.models import PlayerProfile
from ._error_assert import error_code, error_message  # 【FEAT-515】

User = get_user_model()

_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'api.authentication.ExpiringTokenAuthentication',
        'api.authentication.GuestTokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
}


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class ProgressivePricingTest(APITestCase):
    """ShopPurchaseView の累進価格分岐 (daily_quest_slot_expand) の契約テスト。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='pricing_tester', password='pw')
        self.player = PlayerProfile.objects.create(user=self.user, diamonds=10000)
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    def _purchase(self, item_id):
        return self.client.post(
            '/api/shop/purchase/',
            data={'item_id': item_id},
            format='json',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: クエスト枠 1 回目購入 = 200💎 (daily_battle_limit_purchase_count 0→1)
    # ─────────────────────────────────────────────────────────────────
    def test_1_quest_slot_first_purchase_costs_200(self):
        self.assertEqual(self.player.daily_battle_limit_purchase_count, 0)
        initial_diamonds = self.player.diamonds

        res = self._purchase('daily_quest_slot_expand')
        self.assertEqual(res.status_code, http_status.HTTP_201_CREATED, res.data)

        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, initial_diamonds - 200)
        self.assertEqual(self.player.daily_battle_limit_purchase_count, 1)
        self.assertEqual(self.player.daily_battle_limit_bonus, 1)
        self.assertEqual(res.data['next_price'], 400)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: クエスト枠 5 回目購入 = 1000💎 (purchase_count 4→5)
    # ─────────────────────────────────────────────────────────────────
    def test_2_quest_slot_fifth_purchase_costs_1000(self):
        self.player.daily_battle_limit_purchase_count = 4
        self.player.daily_battle_limit_bonus          = 4
        self.player.save(update_fields=[
            'daily_battle_limit_purchase_count', 'daily_battle_limit_bonus',
        ])
        initial_diamonds = self.player.diamonds

        res = self._purchase('daily_quest_slot_expand')
        self.assertEqual(res.status_code, http_status.HTTP_201_CREATED, res.data)

        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, initial_diamonds - 1000)
        self.assertEqual(self.player.daily_battle_limit_purchase_count, 5)
        self.assertEqual(self.player.daily_battle_limit_bonus, 5)
        self.assertIsNone(res.data['next_price'])

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: クエスト枠 6 回目購入は 400 拒否
    # ─────────────────────────────────────────────────────────────────
    def test_3_quest_slot_sixth_purchase_rejected(self):
        self.player.daily_battle_limit_purchase_count = SHOP_PROGRESSIVE_MAX_COUNT
        self.player.daily_battle_limit_bonus          = SHOP_PROGRESSIVE_MAX_COUNT
        self.player.save(update_fields=[
            'daily_battle_limit_purchase_count', 'daily_battle_limit_bonus',
        ])
        initial_diamonds = self.player.diamonds

        res = self._purchase('daily_quest_slot_expand')
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        self.assertIn('これ以上枠を拡張できません', error_message(res))
        self.assertEqual(res.data['purchase_count'], SHOP_PROGRESSIVE_MAX_COUNT)

        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, initial_diamonds)
        self.assertEqual(self.player.daily_battle_limit_purchase_count, SHOP_PROGRESSIVE_MAX_COUNT)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 4: ダイヤ不足時の 400 (動的価格に対する正確な計算)
    # ─────────────────────────────────────────────────────────────────
    def test_4_insufficient_diamonds_for_dynamic_price(self):
        # purchase_count=2 → 次回価格 = calc_progressive_price(2) = 600
        self.player.daily_battle_limit_purchase_count = 2
        self.player.daily_battle_limit_bonus          = 2
        # ダイヤ 600 未満 (599) に設定 → 600 必要だが不足
        self.player.diamonds = 599
        self.player.save(update_fields=[
            'daily_battle_limit_purchase_count', 'daily_battle_limit_bonus', 'diamonds',
        ])

        res = self._purchase('daily_quest_slot_expand')
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        self.assertIn('ダイヤが足りない', error_message(res))
        # エラーメッセージに動的価格 600 が含まれる (静的価格 200 ではない)
        self.assertIn('600', error_message(res))
        self.assertEqual(calc_progressive_price(2), 600)

        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 599)
        self.assertEqual(self.player.daily_battle_limit_purchase_count, 2)
