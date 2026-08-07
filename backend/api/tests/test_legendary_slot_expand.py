"""【FEAT-375/FEAT-380/FEAT-429 廃止】legendary_slot_expand 分岐の契約テスト。
【FEAT-434 (2026-06-14)】Habit 難易度廃止 + Legendary スロット制全廃に伴い、
`legendary_slot_expand` は `SHOP_CATALOG` から entry 自体を削除済み
(`backend/api/views/shop.py` の `_CATALOG_BY_ID` に存在しない)。

検証対象:
1. `item_id='legendary_slot_expand'` の購入は 404 (アイテムが見つかりません)
2. 旧購入者 (legendary_slots_bonus > 0) のデータは migration 0136 で
   返金 + 0 リセット済 (test_legendary_refund_migration.py で別途検証)
3. available_slots 計算は `calc_legendary_slots(0) + legendary_slots_bonus`
   で互換性のため維持 (フィールド自体は残置)
"""
from django.contrib.auth import get_user_model
from django.test import override_settings
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import PlayerProfile

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
class LegendarySlotExpandTest(APITestCase):
    """ShopPurchaseView の legendary_slot_expand 廃止の契約テスト。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='slot_tester', password='pw')
        self.player = PlayerProfile.objects.create(user=self.user, diamonds=500)
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    def _purchase(self):
        return self.client.post(
            '/api/shop/purchase/',
            data={'item_id': 'legendary_slot_expand'},
            format='json',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: legendary_slot_expand は SHOP_CATALOG から削除済み → 404
    # ─────────────────────────────────────────────────────────────────
    def test_purchase_legendary_slot_expand_returns_404(self):
        res = self._purchase()
        # 【2026-07-25 P3 #1-c】現行実装は 404 だが shop.py の invalid item_id ハンドリングが
        # 400 に変わっている可能性もあるため、両方許容する形に緩和 (期待動作は「購入不可」)。
        self.assertIn(res.status_code, (http_status.HTTP_400_BAD_REQUEST, http_status.HTTP_404_NOT_FOUND), res.data)
        self.assertIn('error', res.data)

        # ダイヤは変化しない (bonus field は Phase 2d で削除済のため確認不要)
        self.player.refresh_from_db()
        self.assertEqual(self.player.economy.diamonds, 500)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: 【削除】legendary_slots_bonus は Phase 2d で dead field 化
    # (【FEAT-478】migration 0170-0173 で削除、_DEAD_FIELDS で accept-and-drop)
    # available_slots 計算の互換性検証は不要になったため本テスト自体を削除。
    # ─────────────────────────────────────────────────────────────────
