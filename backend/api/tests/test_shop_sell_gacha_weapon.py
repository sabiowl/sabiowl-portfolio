"""【BUG-143 (2026-08-07)】ガチャ / onboarding 武器の売却拒否 契約テスト。

## 何が起きていたか

ユーザー報告 2026-08-07:
「ミスリルの剣や竜殺しの剣がショップで 0coin で売られている。
  ショップで売られていない想定であった。また、売却もできてしまう。
  売却できない想定であった。」

本ファイルは **後半 (売却)** を縛る。前半 (0 coin 表示) は Mobile 側の
購入モードフィルタの問題で、別途対応する。

## なぜ `_NON_SELLABLE_ITEM_TYPES` で防げていなかったか

FEAT-443 (2026-06-20) の `_NON_SELLABLE_ITEM_TYPES` は `gacha_only` を含むが、
ガチャ排出**武器**の item_type は `weapon` なので対象外。さらに致命的なのは
`ShopSellView` の構造で:

    is_weapon_path = (
        (catalog_item is not None and catalog_item.get('item_type') == 'weapon')
        or catalog_item is None          # ← catalog に無い = 武器とみなす
    )

**武器分岐は `_NON_SELLABLE_ITEM_TYPES` チェックより前に return する**ため、
あのガードは武器に対して構造上一度も適用されない。
唯一のゲートは `_calc_sell_price_coins` が 0 を返すかどうかである。

## 実害

竜殺しの剣 (ATK+50) が 500 coin で不可逆に売却できた。鋼の剣 (ATK+20) の
購入価格が 800 coin なので、交換レートとしても損。coin で買い直す経路が
存在しない武器なので、売ったら戻せない。

## 契約

S1-S3: catalog 外の武器 (dragon_slayer / mythril_sword / starter_sword) は
        売却を 400 `not_sellable` で拒否し、**PlayerWeapon が残る**
S4:     拒否時にコインが増えていない (副作用ゼロ)
S5:     catalog にある武器 (steel_sword 等) は従来どおり price//2 で売却できる
        = 本 fix が正常な売却まで壊していないこと
S6:     `_calc_sell_price_coins` の単体契約

実行方法:
    cd backend
    python manage.py test api.tests.test_shop_sell_gacha_weapon
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import PlayerProfile, PlayerWeapon, WeaponMaster
from api.views.shop import _CATALOG_BY_ID, _calc_sell_price_coins

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
class SellGachaWeaponRejectedTest(APITestCase):
    """catalog 外の武器は売却できない (BUG-143)。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('sell_guard_tester', email='sgt@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='SellGuardTester')
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # migration 0082 (starter_sword) / 0093 (bronze/iron/steel/mythril/dragon_slayer)
        self.starter = WeaponMaster.objects.get(key='starter_sword')
        self.mythril = WeaponMaster.objects.get(key='mythril_sword')
        self.dragon = WeaponMaster.objects.get(key='dragon_slayer')
        self.steel = WeaponMaster.objects.get(key='steel_sword')

    def _sell(self, item_id):
        return self.client.post(
            reverse('shop-sell'), {'item_id': item_id}, format='json',
        )

    def _coins(self):
        self.player.refresh_from_db()
        return self.player.economy.bonus_coins

    # ─────────────────────────────────────────────────────────────
    # S1-S3: catalog 外の武器は 400 で拒否され、所持したまま残る
    # ─────────────────────────────────────────────────────────────

    def test_s1_dragon_slayer_cannot_be_sold(self):
        """Weekly SSR。旧実装では 500 coin で売れてしまっていた。"""
        self._assert_not_sellable(self.dragon)

    def test_s2_mythril_sword_cannot_be_sold(self):
        """Daily SR。旧実装では 350 coin。"""
        self._assert_not_sellable(self.mythril)

    def test_s3_starter_sword_cannot_be_sold(self):
        """onboarding 配布。持ち替えれば売れてしまう状態だった。"""
        self._assert_not_sellable(self.starter)

    def _assert_not_sellable(self, weapon):
        # is_equipped=False にしないと `equipped_weapon` で弾かれ、
        # **本 fix とは別の理由で 400 になる**ので検査にならない。
        PlayerWeapon.objects.create(
            player=self.player, weapon=weapon, is_equipped=False,
        )

        res = self._sell(weapon.key)

        self.assertEqual(
            res.status_code, 400,
            f'{weapon.key} の売却が拒否されていない (status={res.status_code})。'
            f'coin で買い直せない武器を売らせてはいけない (BUG-143)',
        )
        self.assertEqual(
            res.data['error']['code'], 'not_sellable',
            f'{weapon.key} が別の理由で弾かれている: {res.data}。'
            f'`equipped_weapon` 等だと本 fix の検査になっていない',
        )
        self.assertTrue(
            PlayerWeapon.objects.filter(player=self.player, weapon=weapon).exists(),
            f'{weapon.key} が 400 を返したのに削除されている = 消失バグ',
        )

    # ─────────────────────────────────────────────────────────────
    # S4: 拒否時にコインが増えていない
    # ─────────────────────────────────────────────────────────────

    def test_s4_rejected_sell_grants_no_coins(self):
        """400 を返しつつコインだけ入る、という半端な失敗をしていないこと。"""
        PlayerWeapon.objects.create(
            player=self.player, weapon=self.dragon, is_equipped=False,
        )
        before = self._coins()

        self._sell('dragon_slayer')

        self.assertEqual(
            self._coins(), before,
            '売却拒否なのにコインが増えている (transaction が中途半端)',
        )

    # ─────────────────────────────────────────────────────────────
    # S5: catalog にある武器は従来どおり売れる (本 fix の巻き込み防止)
    # ─────────────────────────────────────────────────────────────

    def test_s5_catalog_weapon_still_sellable_at_half_price(self):
        """steel_sword (coin 800) は 400 coin で売れる。

        ここが落ちたら、BUG-143 の fix が**正常な売却まで巻き込んで壊した**合図。
        """
        PlayerWeapon.objects.create(
            player=self.player, weapon=self.steel, is_equipped=False,
        )
        catalog_price = _CATALOG_BY_ID['steel_sword']['price']
        before = self._coins()

        res = self._sell('steel_sword')

        self.assertEqual(res.status_code, 200, res.data)
        self.assertEqual(res.data['coins_gained'], catalog_price // 2)
        self.assertEqual(self._coins(), before + catalog_price // 2)
        self.assertFalse(
            PlayerWeapon.objects.filter(player=self.player, weapon=self.steel).exists(),
            '売却成功したのに PlayerWeapon が残っている',
        )

    # ─────────────────────────────────────────────────────────────
    # S6: `_calc_sell_price_coins` の単体契約
    # ─────────────────────────────────────────────────────────────

    def test_s6_calc_sell_price_rules(self):
        """「coin 購入価格を持つものだけが売れる」という単一規則。"""
        # catalog の coin price → 半額
        self.assertEqual(
            _calc_sell_price_coins({'price': 800}), 400,
        )
        # catalog 外 (= 引数 None) → 0
        self.assertEqual(
            _calc_sell_price_coins(None), 0,
            'catalog 外の武器は売却不可 (BUG-143)。ここが 0 でなくなると '
            'ShopItemsView が注入する sell_price も 0 でなくなり、'
            'Mobile の売却ボタンが復活する',
        )
        # diamond 専売 → 0 (currency mismatch、既存挙動)
        self.assertEqual(
            _calc_sell_price_coins({'price': 0, 'diamond_price': 120}), 0,
        )
