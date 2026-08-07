"""【2026-07-09】 ShopItemsView が SHOP_CATALOG に entry がない所持武器
(starter_sword / mythril_sword / dragon_slayer 等) を所持品リストに含めることを保証。

【背景】
user 報告 2026-07-09: 「所持品リストに装備を持っていても表示されていない、
ショップで購入した武器のみ表示する仕様になっているかもしれない (ガチャ入手武器も
表示する想定)」。

【症状】
- SHOP_CATALOG に entry がある武器 (bronze/iron/steel/wood/iron series) は所持品モードで表示
- SHOP_CATALOG に entry がない武器 (starter_sword / mythril_sword / dragon_slayer)
  は所持していても非表示

【修正】
ShopItemsView.get() で SHOP_CATALOG loop の後に、SHOP_CATALOG に entry がない
所持武器を WeaponMaster から動的に注入する処理を追加 (BUG-99 xp_boost_1.5x と
同種のバグ、weapon 版)。

【契約テスト】
S1: dragon_slayer (Weekly SSR ガチャ排出) 所持 → items に含まれる
S2: mythril_sword (Daily SR ガチャ排出) 所持 → items に含まれる
S3: starter_sword (onboarding 配布) 所持 → items に含まれる
S4: 非所持 gacha 武器は items に含まれない (owned_quantity=0 は catalog にない = 出現しない)
S5: 注入 entry の sell_price は 0 (売却不可) — **BUG-143 (2026-08-07) で反転**
S6: 注入 entry の item_type='weapon' + weapon_key が set されている (Mobile 側判定用)

【BUG-143 (2026-08-07) 追記】
本 fix が「所持品リストに出す」ために注入した entry は、同時に **売却経路も
開通させていた** (sell_price に atk_bonus * 10 を載せていたため)。竜殺しの剣が
500 coin で不可逆に売却でき、ユーザー報告「売却できない想定であった」に至った。
S5 の検査の向きを反転し、売却不可 (0) を契約とする。
売却が実際に 400 で拒否されることは `test_shop_sell_gacha_weapon.py` が縛る。
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import PlayerProfile, PlayerWeapon, WeaponMaster

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
class ShopItemsGachaWeaponsTest(APITestCase):
    """【2026-07-09】ShopItemsView での gacha/starter 武器の所持品リスト表示契約。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('gacha_weapons_tester', email='gwt@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='GachaWeaponsViewer')
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # migration 0082 (starter_sword), 0093 (bronze/iron/steel/mythril/dragon_slayer)
        # で seed 済み前提。テスト DB に存在することを保証。
        self.starter = WeaponMaster.objects.get(key='starter_sword')
        self.mythril = WeaponMaster.objects.get(key='mythril_sword')
        self.dragon = WeaponMaster.objects.get(key='dragon_slayer')

    def _fetch_items(self):
        """/api/shop/items/ を叩き items list を返す。"""
        res = self.client.get(reverse('shop-items'))
        self.assertEqual(res.status_code, 200, res.content)
        return res.data['items']

    def _find_item(self, items, item_id):
        """items から item_id 一致の entry を返す (見つからなければ None)。"""
        for it in items:
            if it.get('id') == item_id:
                return it
        return None

    # ─────────────────────────────────────────────────────────────
    # S1: dragon_slayer (Weekly SSR ガチャ排出) 所持 → items に含まれる
    # ─────────────────────────────────────────────────────────────

    def test_s1_owned_dragon_slayer_appears_in_items(self):
        """竜殺しの剣 (SSR ガチャ) を所持している場合、所持品リストに表示される。"""
        PlayerWeapon.objects.create(
            player=self.player, weapon=self.dragon, is_equipped=False,
        )

        items = self._fetch_items()
        dragon_item = self._find_item(items, 'dragon_slayer')

        self.assertIsNotNone(
            dragon_item,
            'dragon_slayer を所持しているのに items list に含まれていない '
            '(user 報告バグの再燃)。ShopItemsView.get の gacha 武器注入経路が壊れている',
        )
        self.assertEqual(dragon_item['name'], self.dragon.name)
        self.assertEqual(dragon_item['owned_quantity'], 1)
        self.assertEqual(dragon_item['item_type'], 'weapon')
        self.assertEqual(dragon_item['weapon_key'], 'dragon_slayer')

    # ─────────────────────────────────────────────────────────────
    # S2: mythril_sword (Daily SR ガチャ排出) 所持 → items に含まれる
    # ─────────────────────────────────────────────────────────────

    def test_s2_owned_mythril_sword_appears_in_items(self):
        """ミスリルの剣 (SR ガチャ) を所持している場合、所持品リストに表示される。"""
        PlayerWeapon.objects.create(
            player=self.player, weapon=self.mythril, is_equipped=False,
        )

        items = self._fetch_items()
        mythril_item = self._find_item(items, 'mythril_sword')

        self.assertIsNotNone(mythril_item)
        self.assertEqual(mythril_item['owned_quantity'], 1)
        self.assertEqual(mythril_item['item_type'], 'weapon')

    # ─────────────────────────────────────────────────────────────
    # S3: starter_sword (onboarding 配布) 所持 → items に含まれる
    # ─────────────────────────────────────────────────────────────

    def test_s3_owned_starter_sword_appears_in_items(self):
        """見習いの剣 (onboarding 配布) を所持している場合、所持品リストに表示される。"""
        PlayerWeapon.objects.create(
            player=self.player, weapon=self.starter, is_equipped=True,
        )

        items = self._fetch_items()
        starter_item = self._find_item(items, 'starter_sword')

        self.assertIsNotNone(starter_item)
        self.assertEqual(starter_item['owned_quantity'], 1)

    # ─────────────────────────────────────────────────────────────
    # S4: 非所持の gacha/starter 武器は items に含まれない
    # ─────────────────────────────────────────────────────────────

    def test_s4_unowned_gacha_weapons_not_in_items(self):
        """dragon_slayer / mythril_sword / starter_sword を所持していない場合、
        items list に含まれない (owned_quantity=0 の catalog 外 entry は出現しない)。"""
        # PlayerWeapon を作成しない = 全 gacha/starter 武器を所持しない

        items = self._fetch_items()

        for key in ('dragon_slayer', 'mythril_sword', 'starter_sword'):
            self.assertIsNone(
                self._find_item(items, key),
                f'{key} を所持していないのに items list に含まれている '
                f'= 非所持 gacha 武器も表示されてしまうバグ',
            )

    # ─────────────────────────────────────────────────────────────
    # S5: 注入 entry の sell_price は 0 (売却不可)
    #
    # 【BUG-143 (2026-08-07) で反転】旧 S5 は `atk_bonus * 10` (dragon_slayer
    # なら 500 coin) を期待していた。ユーザー報告「売却できない想定であった」を
    # 受けて **catalog 外の武器 = 売却不可** に変更したため、検査の向きが逆になる。
    #
    # この 0 は Mobile 側の売却ボタン表示も兼ねている: shop_page.dart は
    # `sellPrice > 0` でボタンを出すため、**リリース済アプリでもボタンが消える**。
    # ここが 0 でなくなると、その保証が黙って外れる。
    # ─────────────────────────────────────────────────────────────

    def test_s5_gacha_weapon_is_not_sellable(self):
        """catalog 外武器 (starter / mythril / dragon_slayer) の sell_price は 0。

        coin で買い直す経路が無い武器を売らせない、という規則
        (`_calc_sell_price_coins` の docstring 参照)。
        """
        for weapon in (self.dragon, self.mythril, self.starter):
            PlayerWeapon.objects.filter(player=self.player).delete()
            PlayerWeapon.objects.create(
                player=self.player, weapon=weapon, is_equipped=False,
            )

            item = self._find_item(self._fetch_items(), weapon.key)

            self.assertIsNotNone(item, f'{weapon.key} が items list に出ていない')
            self.assertEqual(
                item['sell_price'], 0,
                f'{weapon.key} (atk_bonus={weapon.atk_bonus}) の sell_price が 0 でない。'
                f'0 でないと Mobile に売却ボタンが出て、買い直せない武器を'
                f'不可逆に失える (BUG-143)',
            )

    # ─────────────────────────────────────────────────────────────
    # S6: 注入 entry の item_type='weapon' + weapon_key set
    # ─────────────────────────────────────────────────────────────

    def test_s6_gacha_weapon_entry_has_weapon_item_type_and_key(self):
        """Mobile の shop_page が「所持品モードで装備タブに分類する」ため、
        item_type='weapon' + weapon_key が正しく set されていることを保証。"""
        PlayerWeapon.objects.create(
            player=self.player, weapon=self.dragon, is_equipped=False,
        )

        items = self._fetch_items()
        dragon_item = self._find_item(items, 'dragon_slayer')

        self.assertIsNotNone(dragon_item)
        self.assertEqual(dragon_item['item_type'], 'weapon',
                         'item_type=weapon でないと Mobile が「装備タブ」に分類しない')
        self.assertEqual(dragon_item['weapon_key'], 'dragon_slayer',
                         'weapon_key が set されていないと ShopSellView 経路で照会できない')
        self.assertEqual(dragon_item['category'], 'weapons',
                         'category=weapons でないと Mobile の tab フィルターに hit しない')
