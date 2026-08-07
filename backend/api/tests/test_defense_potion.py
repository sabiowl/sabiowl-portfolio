"""【FEAT-432 (2026-06-13)】防御の薬 🛡️ の Backend 契約テスト。

攻撃の薬 (FEAT-376, test_upper_potions.py) と完全対称設計。

検証対象:
1. SHOP_CATALOG に defense_potion が存在し、price=80・max_stock=10
2. 防御の薬購入 → 💎 80 消費 + PlayerItem +1
3. バトル開始時 defense_potion_to_use=3 を指定 → Battle.potions_planned に反映
4. バトル終了時 defense_potion_used=3 → inventory -=3
5. 所持数不足の defense_potion_used 指定 → 400 + inventory 不変
"""
from django.contrib.auth import get_user_model
from django.test import override_settings
from django.utils import timezone
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Battle, Enemy, PlayerItem, PlayerProfile
from api.views.shop import SHOP_CATALOG
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


def _ensure_goblin_exists():
    """テスト用ゴブリンが存在することを確認 (migration 0082 依存)。"""
    return Enemy.objects.get_or_create(
        key='goblin',
        defaults=dict(
            name='ゴブリン', sprite_key='enemy_goblin',
            base_hp=60, base_atk=8, base_spd=10,
            level_scaling=0.5,
            reward_coins=5, reward_exp=10,
        ),
    )[0]


class DefensePotionCatalogTest(APITestCase):
    """シナリオ 1: SHOP_CATALOG エントリ確認。"""

    def test_defense_potion_catalog_entry(self):
        entry = next(
            (item for item in SHOP_CATALOG if item['id'] == 'defense_potion'),
            None,
        )
        self.assertIsNotNone(entry)
        self.assertEqual(entry['diamond_price'], 80)
        self.assertEqual(entry['max_stock'], 10)
        self.assertEqual(entry['item_type'], 'battle_consumable')
        self.assertEqual(entry['potion_subtype'], 'defense')


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class DefensePotionShopTest(APITestCase):
    """シナリオ 2 + 5(上限): ショップ購入テスト。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='defense_potion_shop_test', password='pw')
        self.player = PlayerProfile.objects.create(user=self.user, diamonds=200)
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    def _purchase(self, item_id):
        return self.client.post(
            '/api/shop/purchase/',
            data={'item_id': item_id},
            format='json',
        )

    def test_defense_potion_purchase_consumes_80_diamonds(self):
        res = self._purchase('defense_potion')
        self.assertEqual(res.status_code, http_status.HTTP_201_CREATED, res.data)

        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 200 - 80)

        item = PlayerItem.objects.get(player=self.player, item_id='defense_potion')
        self.assertEqual(item.quantity, 1)

    def test_defense_potion_max_stock_10(self):
        PlayerItem.objects.create(
            player=self.player, item_id='defense_potion', quantity=10,
        )
        res = self._purchase('defense_potion')
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class DefensePotionBattleTest(APITestCase):
    """シナリオ 3 + 4 + 5(不足): バトル消費テスト。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='defense_potion_battle_test', password='pw')
        # 【FEAT-432】reset_battle_charges_if_new_day は battle_charges_date != today
        # (= null 含む) で battle_charges を 0 にリセットする (FEAT-406)。
        # 明示的に today を渡しリセットを回避する (test_upper_potions.py の既存問題と同種、
        # 本 FEAT のスコープ外のため当ファイルのみで対処)。
        self.player = PlayerProfile.objects.create(
            user=self.user, battle_charges=3, battle_charges_date=timezone.localdate(),
        )
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        self.enemy  = _ensure_goblin_exists()

    def _start(self, **kwargs):
        return self.client.post(
            '/api/battle/start/',
            data={'enemy_key': 'goblin', **kwargs},
            format='json',
        )

    def _finish(self, token: str, **kwargs):
        return self.client.post(
            '/api/battle/finish/',
            data={
                'token':        token,
                'result':       'win',
                'duration_sec': 30,
                'damage_dealt': 10,
                'damage_taken': 5,
                'rounds':       3,
                'potions_used': 0,
                **kwargs,
            },
            format='json',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: BattleStart で defense_potion_to_use を指定可能
    # ─────────────────────────────────────────────────────────────────
    def test_battle_start_accepts_defense_potion(self):
        PlayerItem.objects.create(
            player=self.player, item_id='defense_potion', quantity=3,
        )

        res = self._start(defense_potion_to_use=3)
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)

        battle = Battle.objects.filter(player=self.player).order_by('-id').first()
        self.assertEqual(battle.potions_planned, 3)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 4: BattleFinish で defense_potion 消費 → inventory decrement
    # ─────────────────────────────────────────────────────────────────
    def test_battle_defense_potion_consumed_on_finish(self):
        PlayerItem.objects.create(
            player=self.player, item_id='defense_potion', quantity=3,
        )

        start_res = self._start(defense_potion_to_use=3)
        self.assertEqual(start_res.status_code, http_status.HTTP_200_OK)
        token = start_res.data['token']

        finish_res = self._finish(token, defense_potion_used=3)
        self.assertEqual(finish_res.status_code, http_status.HTTP_200_OK, finish_res.data)

        item = PlayerItem.objects.get(player=self.player, item_id='defense_potion')
        self.assertEqual(item.quantity, 0)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 5: 所持数不足の defense_potion_to_use → 400 + inventory 不変
    # ─────────────────────────────────────────────────────────────────
    def test_battle_start_rejects_insufficient_defense_potion(self):
        PlayerItem.objects.create(
            player=self.player, item_id='defense_potion', quantity=1,
        )

        res = self._start(defense_potion_to_use=2)
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST, res.data)
        self.assertEqual(error_code(res), 'not_enough_defense_potion')

        item = PlayerItem.objects.get(player=self.player, item_id='defense_potion')
        self.assertEqual(item.quantity, 1)
