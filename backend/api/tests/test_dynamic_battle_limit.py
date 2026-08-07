"""【FEAT-429 (2026-06-12)】動的 1 日出陣上限 (DAILY_BATTLE_LIMIT + player.daily_battle_limit_bonus) の契約テスト。

check_daily_battle_limit(player) は (can_battle, current_count, dynamic_limit) の
3 要素タプルを返し、dynamic_limit = DAILY_BATTLE_LIMIT + (player.daily_battle_limit_bonus or 0)。

検証対象 (5 シナリオ):
1. bonus=0 で 10 回目まで出陣可、11 回目は 403 (既存挙動と等価)
2. bonus=3 で 13 回目まで出陣可、14 回目は 403 (動的 limit 経路)
3. bonus=5 (上限) で 15 回目まで出陣可、16 回目は 403
4. bonus 購入後の出陣可能数増加 (購入前 10 回で 403 → 購入後 11 回目まで出陣可)
5. 403 レスポンスの limit フィールドが動的値 (bonus=2 → limit=12)
"""
from django.contrib.auth import get_user_model
from django.test import override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.constants import DAILY_BATTLE_LIMIT
from api.models import Enemy, PlayerProfile
from ._error_assert import error_code, error_message  # 【FEAT-515】

User = get_user_model()

_TEST_RF_OVERRIDE = {
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


@override_settings(REST_FRAMEWORK=_TEST_RF_OVERRIDE)
class DynamicBattleLimitTest(APITestCase):
    """動的 daily_battle_limit (DAILY_BATTLE_LIMIT + daily_battle_limit_bonus) の 5 シナリオ。"""

    def setUp(self):
        self.user = User.objects.create_user('dyn_limit_user', email='dyn@t.com')
        today = timezone.localdate()
        self.player = PlayerProfile.objects.create(
            user=self.user, name='DynLimit',
            battle_charges=999,
            battle_charges_date=today,  # FEAT-406: 日次リセットで charges が 0 になるのを防ぐ
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        Enemy.objects.update_or_create(
            key='goblin',
            defaults={
                'name': 'ゴブリン', 'sprite_key': 'enemy_goblin',
                'base_hp': 60, 'base_atk': 8, 'base_spd': 10,
                'level_scaling': 1.0, 'reward_coins': 10, 'reward_exp': 20,
                'tier': 'zako',
            },
        )

    def _start_battle(self):
        return self.client.post(reverse('battle-start'))

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: bonus=0 で 10 回目まで出陣可、11 回目は 403 (既存挙動と等価)
    # ─────────────────────────────────────────────────────────────────
    def test_1_bonus_zero_allows_up_to_10_then_403(self):
        today = timezone.localdate()
        self.player.daily_battle_limit_bonus = 0
        self.player.daily_battle_count = DAILY_BATTLE_LIMIT - 1  # 9
        self.player.daily_battle_count_date = today
        self.player.save()

        # 10 回目 (count 9 → 10) は成功
        res = self._start_battle()
        self.assertEqual(res.status_code, 200, res.content)
        self.player.refresh_from_db()
        self.assertEqual(self.player.daily_battle_count, DAILY_BATTLE_LIMIT)

        # 11 回目は 403
        res = self._start_battle()
        self.assertEqual(res.status_code, 403, res.content)
        self.assertEqual(error_code(res), 'daily_battle_limit_reached')
        self.assertEqual(res.data['limit'], DAILY_BATTLE_LIMIT)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: bonus=3 で 13 回目まで出陣可、14 回目は 403 (動的 limit 経路)
    # ─────────────────────────────────────────────────────────────────
    def test_2_bonus_3_allows_up_to_13_then_403(self):
        today = timezone.localdate()
        self.player.daily_battle_limit_bonus = 3
        self.player.daily_battle_count = DAILY_BATTLE_LIMIT + 3 - 1  # 12
        self.player.daily_battle_count_date = today
        self.player.save()

        # 13 回目 (count 12 → 13) は成功 (dynamic_limit = 10 + 3 = 13)
        res = self._start_battle()
        self.assertEqual(res.status_code, 200, res.content)
        self.player.refresh_from_db()
        self.assertEqual(self.player.daily_battle_count, DAILY_BATTLE_LIMIT + 3)

        # 14 回目は 403
        res = self._start_battle()
        self.assertEqual(res.status_code, 403, res.content)
        self.assertEqual(error_code(res), 'daily_battle_limit_reached')
        self.assertEqual(res.data['limit'], DAILY_BATTLE_LIMIT + 3)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: bonus=5 (上限) で 15 回目まで出陣可、16 回目は 403
    # ─────────────────────────────────────────────────────────────────
    def test_3_bonus_max_5_allows_up_to_15_then_403(self):
        today = timezone.localdate()
        self.player.daily_battle_limit_bonus = 5
        self.player.daily_battle_count = DAILY_BATTLE_LIMIT + 5 - 1  # 14
        self.player.daily_battle_count_date = today
        self.player.save()

        # 15 回目 (count 14 → 15) は成功 (dynamic_limit = 10 + 5 = 15)
        res = self._start_battle()
        self.assertEqual(res.status_code, 200, res.content)
        self.player.refresh_from_db()
        self.assertEqual(self.player.daily_battle_count, DAILY_BATTLE_LIMIT + 5)

        # 16 回目は 403
        res = self._start_battle()
        self.assertEqual(res.status_code, 403, res.content)
        self.assertEqual(error_code(res), 'daily_battle_limit_reached')
        self.assertEqual(res.data['limit'], DAILY_BATTLE_LIMIT + 5)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 4: bonus 購入後の出陣可能数増加
    # (購入前 10 回で 403 → 購入後 11 回目まで出陣可)
    # ─────────────────────────────────────────────────────────────────
    def test_4_purchase_increases_available_battles(self):
        today = timezone.localdate()
        self.player.daily_battle_limit_bonus = 0
        self.player.daily_battle_count = DAILY_BATTLE_LIMIT  # 10 (上限到達済)
        self.player.daily_battle_count_date = today
        self.player.diamonds = 1000
        self.player.save()

        # 購入前: 11 回目 (= 上限+1) は 403
        res = self._start_battle()
        self.assertEqual(res.status_code, 403, res.content)
        self.assertEqual(res.data['limit'], DAILY_BATTLE_LIMIT)

        # daily_quest_slot_expand を購入 (1 回目 = 200💎、bonus 0→1)
        purchase_res = self.client.post(
            '/api/shop/purchase/',
            data={'item_id': 'daily_quest_slot_expand'},
            format='json',
        )
        self.assertEqual(purchase_res.status_code, 201, purchase_res.data)
        self.player.refresh_from_db()
        self.assertEqual(self.player.daily_battle_limit_bonus, 1)

        # 購入後: dynamic_limit = 11、daily_battle_count はまだ 10 → 出陣成功
        res = self._start_battle()
        self.assertEqual(res.status_code, 200, res.content)
        self.player.refresh_from_db()
        self.assertEqual(self.player.daily_battle_count, DAILY_BATTLE_LIMIT + 1)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 5: 403 レスポンスの limit フィールドが動的値 (bonus=2 → limit=12)
    # ─────────────────────────────────────────────────────────────────
    def test_5_403_response_limit_field_is_dynamic(self):
        today = timezone.localdate()
        self.player.daily_battle_limit_bonus = 2
        self.player.daily_battle_count = DAILY_BATTLE_LIMIT + 2  # 12 (上限到達済)
        self.player.daily_battle_count_date = today
        self.player.save()

        res = self._start_battle()
        self.assertEqual(res.status_code, 403, res.content)
        self.assertEqual(error_code(res), 'daily_battle_limit_reached')
        self.assertEqual(res.data['current_count'], DAILY_BATTLE_LIMIT + 2)
        self.assertEqual(res.data['limit'], DAILY_BATTLE_LIMIT + 2)
        self.assertEqual(res.data['limit'], 12)
