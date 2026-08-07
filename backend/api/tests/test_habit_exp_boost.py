"""【FEAT-406 (2026-06-01)】習慣 EXP × 1.5 倍（EXP_PER_COUNT 20 → 30）の契約テスト。

設計:
  - 旧: Easy=20 / Normal=30 / Hard=40 / Legendary=100
  - 新: Easy=30 / Normal=45 / Hard=60 / Legendary=150
  - 変更は constants.py の EXP_PER_COUNT=30 のみ (DIFFICULTY_MULTIPLIER は変更なし)

テスト方針:
  - calc_exp_gain() を直接呼び、難易度別 EXP を確認 (unit テスト)
  - HabitCountView 経由で Easy 習慣 +1 → exp_gained=30 を E2E 確認
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.constants import GameBalance
from api.models import Habit, PlayerProfile
from api.services.exp_service import calc_exp_gain

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


class HabitExpBoostCalcTest(TestCase):
    """calc_exp_gain() の難易度別 EXP 確認 (unit テスト 4 件)。"""

    def setUp(self):
        u = User.objects.create_user('exp_boost_calc', email='ebc@t.com')
        self.player = PlayerProfile.objects.create(user=u, name='ExpBoost')

    def _habit(self, difficulty: str) -> Habit:
        return Habit(
            player=self.player,
            name=f'テスト習慣_{difficulty}',
            category='運動',
            difficulty=difficulty,
            frequency='daily',
            habit_type='count',
        )

    def test_easy_exp_is_30(self):
        """Easy: EXP_PER_COUNT (30) × 1.0 = 30。"""
        exp = calc_exp_gain(self._habit('easy'), self.player)
        self.assertEqual(exp, 30, f'Easy EXP = 30 (旧 20). EXP_PER_COUNT={GameBalance.EXP_PER_COUNT}')

    def test_normal_exp_is_45(self):
        """Normal: 30 × 1.5 = 45。"""
        exp = calc_exp_gain(self._habit('normal'), self.player)
        self.assertEqual(exp, 45, f'Normal EXP = 45 (旧 30). 30 × 1.5')

    def test_hard_exp_is_60(self):
        """Hard: 30 × 2.0 = 60。"""
        exp = calc_exp_gain(self._habit('hard'), self.player)
        self.assertEqual(exp, 60, f'Hard EXP = 60 (旧 40). 30 × 2.0')

    def test_legendary_exp_is_150(self):
        """Legendary: 30 × 5.0 = 150。"""
        exp = calc_exp_gain(self._habit('legendary'), self.player)
        self.assertEqual(exp, 150, f'Legendary EXP = 150 (旧 100). 30 × 5.0')

    def test_exp_per_count_constant_is_30(self):
        """GameBalance.EXP_PER_COUNT が 30 であることを定数チェック。

        誰かが constants.py を変更したら即検知。
        """
        self.assertEqual(GameBalance.EXP_PER_COUNT, 30,
                         'FEAT-406: EXP_PER_COUNT は 30 (旧 20 から × 1.5 に変更)')


@override_settings(REST_FRAMEWORK=_TEST_RF_OVERRIDE)
class HabitExpBoostE2ETest(APITestCase):
    """HabitCountView 経由で Easy 習慣 +1 → exp_gained=30 を E2E 確認。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('exp_boost_e2e', email='ebe@t.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='ExpBoostE2E',
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        self.habit = Habit.objects.create(
            player=self.player,
            name='Easy 習慣',
            category='運動',
            difficulty='easy',
            frequency='daily',
            habit_type='count',
        )

    def test_easy_habit_plus_gives_10_exp(self):
        """【FEAT-434 (2026-06-14)】Habit (count) の EXP は difficulty を参照しない。

        calc_habit_base_exp = 10 + (streak // 30) * 3。新規 habit は streak=0
        のため、difficulty='easy' でも exp_gain=10 (旧 calc_exp_gain ベースの 30 から変更)。
        """
        res = self.client.post(
            reverse('habit-count', args=[self.habit.pk]),
            data={'action': 'plus'}, format='json',
        )
        self.assertEqual(res.status_code, 200, res.content)
        # bonus EXP は stat lv に依存するため exp_gain (base のみ) を確認
        self.assertEqual(res.data.get('exp_gain'), 10,
                         'Habit (count) の base EXP = 10 (FEAT-434, streak=0)')
        # charges も 3 上限で +1
        self.player.refresh_from_db()
        self.assertEqual(self.player.battle_charges, 1,
                         '習慣 +1 で battle_charges=1 (3 達成で 1 戦)')
