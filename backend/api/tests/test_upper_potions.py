"""【FEAT-376 (2026-05-29)】上位回復薬 💊+ と攻撃の薬 ⚔️ の Backend 契約テスト。

【FEAT-432 (2026-06-13)】防御の薬 🛡️ 追加に伴い「3 ポーション → 4 ポーション」契約に更新。

検証対象:
1. 上位回復薬 (recovery_potion_plus) 購入 → 💎 60 消費
2. 攻撃の薬 (attack_potion) 購入 → 💎 80 消費
3. バトル開始時: 上位回復薬 → 通常回復薬の順で自動消費 (上位優先)
4. バトル開始時: attack_potion_to_use / defense_potion_to_use がレスポンスに反映されてバトル完了
5. 新ポーション 2 種の max_stock=10 チェック
6. 既存 recovery_potion は変更なし (後方互換 max_stock=99)
"""
from datetime import date as date_type

from django.contrib.auth import get_user_model
from django.test import override_settings
from django.utils import timezone
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Battle, Enemy, PlayerItem, PlayerProfile

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


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class UpperPotionShopTest(APITestCase):
    """新ポーション 2 種のショップ購入テスト。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='potion_shop_test', password='pw')
        self.player = PlayerProfile.objects.create(user=self.user, diamonds=200)
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    def _purchase(self, item_id):
        return self.client.post(
            '/api/shop/purchase/',
            data={'item_id': item_id},
            format='json',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: 上位回復薬購入 → 💎 60 消費
    # ─────────────────────────────────────────────────────────────────
    def test_recovery_potion_plus_purchase_consumes_60_diamonds(self):
        res = self._purchase('recovery_potion_plus')
        self.assertEqual(res.status_code, http_status.HTTP_201_CREATED, res.data)

        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 200 - 60)

        item = PlayerItem.objects.get(player=self.player, item_id='recovery_potion_plus')
        self.assertEqual(item.quantity, 1)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: 攻撃の薬購入 → 💎 80 消費
    # ─────────────────────────────────────────────────────────────────
    def test_attack_potion_purchase_consumes_80_diamonds(self):
        res = self._purchase('attack_potion')
        self.assertEqual(res.status_code, http_status.HTTP_201_CREATED, res.data)

        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 200 - 80)

        item = PlayerItem.objects.get(player=self.player, item_id='attack_potion')
        self.assertEqual(item.quantity, 1)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 5: 新ポーション 2 種の max_stock=10
    # ─────────────────────────────────────────────────────────────────
    def test_max_stock_10_for_new_potions(self):
        # max_stock=10 を超えると 400
        PlayerItem.objects.create(
            player=self.player, item_id='recovery_potion_plus', quantity=10,
        )
        res = self._purchase('recovery_potion_plus')
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 6: 既存 recovery_potion は変更なし (max_stock=99)
    # ─────────────────────────────────────────────────────────────────
    def test_existing_recovery_potion_unchanged(self):
        # max_stock=99 → 99 個所持でも購入可能なはず (100 になるが上限 99 なので 400)
        PlayerItem.objects.create(
            player=self.player, item_id='recovery_potion', quantity=99,
        )
        res = self._purchase('recovery_potion')
        # max_stock=99 に到達しているため 400
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        # 但し 98 個から購入は成功するはず
        PlayerItem.objects.filter(
            player=self.player, item_id='recovery_potion',
        ).update(quantity=98)
        res2 = self._purchase('recovery_potion')
        self.assertEqual(res2.status_code, http_status.HTTP_201_CREATED)


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class UpperPotionBattleTest(APITestCase):
    """新ポーション 2 種のバトル消費テスト。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='potion_battle_test', password='pw')
        # 【FEAT-432】reset_battle_charges_if_new_day は battle_charges_date != today
        # (= null 含む) で battle_charges を 0 にリセットする (FEAT-406)。
        # 明示的に today を渡しリセットを回避する。
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
    # シナリオ 3: BattleStart で上位 + 通常 + 攻撃 + 防御の 4 種を指定可能
    # 【FEAT-432】3 ポーション → 4 ポーション契約に拡張。
    # ─────────────────────────────────────────────────────────────────
    def test_battle_start_accepts_recovery_plus_and_attack_potion(self):
        # 上位回復薬 1 個、攻撃の薬 1 個、防御の薬 1 個を所持
        PlayerItem.objects.create(
            player=self.player, item_id='recovery_potion_plus', quantity=1,
        )
        PlayerItem.objects.create(
            player=self.player, item_id='attack_potion', quantity=1,
        )
        PlayerItem.objects.create(
            player=self.player, item_id='defense_potion', quantity=1,
        )

        res = self._start(
            recovery_potion_plus_to_use=1,
            attack_potion_to_use=1,
            defense_potion_to_use=1,
        )
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)

        # Battle が potions_planned=3 (plus 1 + attack 1 + defense 1) で作成されている
        battle = Battle.objects.filter(player=self.player).order_by('-id').first()
        self.assertEqual(battle.potions_planned, 3)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 4: BattleFinish で attack_potion 消費 → inventory decrement
    # ─────────────────────────────────────────────────────────────────
    def test_battle_attack_potion_consumed_on_finish(self):
        PlayerItem.objects.create(
            player=self.player, item_id='attack_potion', quantity=2,
        )

        start_res = self._start(attack_potion_to_use=2)
        self.assertEqual(start_res.status_code, http_status.HTTP_200_OK)
        token = start_res.data['token']

        finish_res = self._finish(token, attack_potion_used=2)
        self.assertEqual(finish_res.status_code, http_status.HTTP_200_OK, finish_res.data)

        # inventory が 2 → 0 に decrement されている
        item = PlayerItem.objects.get(player=self.player, item_id='attack_potion')
        self.assertEqual(item.quantity, 0)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 4': BattleFinish で defense_potion 消費 → inventory decrement
    # 【FEAT-432】attack_potion と完全対称。
    # ─────────────────────────────────────────────────────────────────
    def test_battle_defense_potion_consumed_on_finish(self):
        PlayerItem.objects.create(
            player=self.player, item_id='defense_potion', quantity=2,
        )

        start_res = self._start(defense_potion_to_use=2)
        self.assertEqual(start_res.status_code, http_status.HTTP_200_OK)
        token = start_res.data['token']

        finish_res = self._finish(token, defense_potion_used=2)
        self.assertEqual(finish_res.status_code, http_status.HTTP_200_OK, finish_res.data)

        # inventory が 2 → 0 に decrement されている
        item = PlayerItem.objects.get(player=self.player, item_id='defense_potion')
        self.assertEqual(item.quantity, 0)
