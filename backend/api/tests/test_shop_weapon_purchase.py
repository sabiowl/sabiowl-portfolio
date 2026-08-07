"""【FEAT-326 Phase 2】 Shop 武器購入の契約テスト 3 件。

カバー:
    1. bronze_sword 購入 → PlayerWeapon 作成 + コイン消費 (-100)
    2. 既所持武器を購入しようとして 400 (重複購入禁止、Pre-mortem #1)
    3. コイン不足で 400 + PlayerWeapon 作成されない
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Habit, PlayerProfile, PlayerWeapon, WeaponMaster
from ._error_assert import error_code, error_message  # 【FEAT-515】

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


def _give_coins(player: PlayerProfile, amount: int) -> None:
    """`compute_coins()` で見えるコインを `amount` だけ付与する。

    `compute_coins = sum(habit.total_exp // 10) + bonus_coins - coins_spent`
    なので `bonus_coins += amount` で確実に増やせる。
    """
    player.bonus_coins += amount
    player.save(update_fields=['bonus_coins'])


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class ShopWeaponPurchaseContractTest(APITestCase):
    """FEAT-326 武器購入の契約 3 件。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('shop_tester', email='st@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='ShopTester')
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        # migration 0093 で seed 済み (5 種 + starter は 0082)
        self.bronze = WeaponMaster.objects.get(key='bronze_sword')

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: bronze_sword 購入 → PlayerWeapon 作成 + コイン -100
    # ─────────────────────────────────────────────────────────────────

    def test_purchase_bronze_sword_creates_player_weapon(self):
        _give_coins(self.player, 200)  # 100 残るように 200 付与
        res = self.client.post(
            reverse('shop-purchase'),
            data={'item_id': 'bronze_sword'},
            format='json',
        )
        self.assertEqual(res.status_code, 201, res.content)
        self.assertEqual(res.data['coins'], 100, '購入後コインは 200 - 100 = 100')
        self.assertEqual(res.data['owned_quantity'], 1)

        # PlayerWeapon が作成され、is_equipped=False (購入と装備は別経路)
        pw = PlayerWeapon.objects.filter(
            player=self.player, weapon=self.bronze,
        ).first()
        self.assertIsNotNone(pw, 'PlayerWeapon が作成されているはず')
        self.assertFalse(pw.is_equipped, '購入時点では未装備')

        # coins_spent も更新済
        self.player.refresh_from_db()
        self.assertEqual(self.player.coins_spent, 100)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: 既所持武器を購入しようとして 400 (Pre-mortem #1)
    # ─────────────────────────────────────────────────────────────────

    def test_purchase_already_owned_weapon_returns_400(self):
        # 事前準備: bronze_sword を既に所持している状態
        PlayerWeapon.objects.create(
            player=self.player, weapon=self.bronze, is_equipped=False,
        )
        _give_coins(self.player, 200)

        res = self.client.post(
            reverse('shop-purchase'),
            data={'item_id': 'bronze_sword'},
            format='json',
        )
        self.assertEqual(res.status_code, 400, res.content)
        # 【FEAT-475 Phase 3b (2026-07-04)】新形式 {'error': {'code', 'message'}}
        # 【2026-08-07】shop_purchase_already_owned から訂正。武器経路と汎用経路で
        # code が入れ替わっていた (views/shop.py のコメント参照)。
        self.assertEqual(error_code(res), 'shop_weapon_already_owned')

        # コインは消費されていない (重複購入で無駄にしない)
        self.player.refresh_from_db()
        self.assertEqual(self.player.coins_spent, 0)

        # PlayerWeapon は 1 件のまま (UniqueConstraint 違反も発生しない)
        count = PlayerWeapon.objects.filter(
            player=self.player, weapon=self.bronze,
        ).count()
        self.assertEqual(count, 1)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: コイン不足で 400 + PlayerWeapon 作成されない
    # ─────────────────────────────────────────────────────────────────

    def test_purchase_with_insufficient_coins_returns_400(self):
        # コイン 50 (bronze 100 円なので不足)
        _give_coins(self.player, 50)

        res = self.client.post(
            reverse('shop-purchase'),
            data={'item_id': 'bronze_sword'},
            format='json',
        )
        self.assertEqual(res.status_code, 400, res.content)
        # 【FEAT-475 Phase 3b (2026-07-04)】新形式
        # 【2026-08-07】shop_purchase_insufficient_coins から訂正 (上記と同じ入れ替わり)。
        self.assertEqual(error_code(res), 'shop_weapon_insufficient_coins')

        # PlayerWeapon 作成されていない
        exists = PlayerWeapon.objects.filter(
            player=self.player, weapon=self.bronze,
        ).exists()
        self.assertFalse(exists, 'コイン不足時に PlayerWeapon を作ってはいけない')

        # coins_spent も増えていない
        self.player.refresh_from_db()
        self.assertEqual(self.player.coins_spent, 0)

    # ─────────────────────────────────────────────────────────────────
    # 【FEAT-327 Fix-1】 シナリオ 4: 購入後 ShopItemsView GET で owned_quantity=1 返却
    # ─────────────────────────────────────────────────────────────────

    def test_purchased_weapon_appears_in_shop_owned_quantity(self):
        """購入後に GET /api/shop/ を叩くと、購入した武器の owned_quantity=1 が返る。

        FEAT-326 Phase 2 実装時に PlayerItem 経由の owned_quantity 計算しか
        していなかったため、weapon を購入しても shop の「持ち物モード」に
        永遠に表示されない 100% 実装バグだった (FEAT-327 §1.1)。本テストで
        構造的に再発防止。"""
        _give_coins(self.player, 500)

        # 購入前: owned_quantity=0 が返る
        res_before = self.client.get(reverse('shop-items'))
        self.assertEqual(res_before.status_code, 200)
        bronze_before = next(
            it for it in res_before.data['items'] if it['id'] == 'bronze_sword'
        )
        self.assertEqual(bronze_before['owned_quantity'], 0,
                         '購入前は owned_quantity=0')

        # bronze_sword 購入
        res_buy = self.client.post(
            reverse('shop-purchase'),
            data={'item_id': 'bronze_sword'},
            format='json',
        )
        self.assertEqual(res_buy.status_code, 201)

        # 購入後: owned_quantity=1 が返る (FEAT-327 Fix-1 で修正)
        res_after = self.client.get(reverse('shop-items'))
        self.assertEqual(res_after.status_code, 200)
        bronze_after = next(
            it for it in res_after.data['items'] if it['id'] == 'bronze_sword'
        )
        self.assertEqual(
            bronze_after['owned_quantity'], 1,
            'FEAT-327 Fix-1: weapon 購入後は ShopItemsView で owned_quantity=1 が '
            '返るはず (PlayerWeapon 索引化が機能していない可能性)',
        )

        # iron_sword (未購入) は引き続き 0
        iron_after = next(
            it for it in res_after.data['items'] if it['id'] == 'iron_sword'
        )
        self.assertEqual(iron_after['owned_quantity'], 0,
                         '未購入の武器は引き続き owned_quantity=0')
