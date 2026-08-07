"""【FEAT-318 (2026-06-13 再活性化)】XP ブースト (xp_boost_1.5x) 在庫実装の契約テスト。

BUG-99 hotfix で SHOP_CATALOG に追加された `xp_boost_1.5x` (gacha_only, 所持品表示のみ)
を、実際に「使用 → 15min × N の間 EXP ×1.5」として機能させる。
【BUG-116 (2026-06-14)】効果時間を 24h → 15min/stock に変更 (PM 指示)。

検証対象:
1. apply_xp_boost_if_active(): 非アクティブ時は exp_gain 不変
2. apply_xp_boost_if_active(): アクティブ時は round(exp_gain * 1.5)
3. apply_xp_boost_if_active(): 期限切れは exp_gain 不変
4. UseXpBoostView: 在庫不足 → 400 insufficient_stock
5. UseXpBoostView: 使用成功 → 在庫 -consume_value、active_until = now + 15min * consume_value (UTC isoformat)
6. UseXpBoostView: 既にブースト中 → 409 already_active (延長されない)
7. 習慣達成 (HabitCountView) でブースト中なら exp_gain が ×1.5
8. バトル勝利 (BattleFinishView) でブースト中なら exp_gained が ×1.5
9. タイムライン完了 (TimelineCompleteView) でブースト中なら exp_gain が ×1.5
"""
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import (
    Battle, Enemy, Habit, PlayerItem, PlayerProfile, TimelineEvent,
)
from api.services.exp_service import apply_xp_boost_if_active, create_default_stats
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
    # 【FEAT-495 (2026-07-25)】reward_exp は bake 済実効値
    # (migration 0082 seed raw 20 → migration 0187 で 6 へ更新済)。
    # defaults は fallback (goblin 未 seed 時のみ使用)。
    return Enemy.objects.get_or_create(
        key='goblin',
        defaults=dict(
            name='ゴブリン', sprite_key='enemy_goblin',
            base_hp=60, base_atk=8, base_spd=10,
            level_scaling=0.5,
            reward_coins=5, reward_exp=6,
        ),
    )[0]


class ApplyXpBoostHelperTest(TestCase):
    """シナリオ 1-3: apply_xp_boost_if_active() の unit テスト。"""

    def setUp(self):
        u = User.objects.create_user('xp_boost_helper', email='xbh@t.com')
        self.player = PlayerProfile.objects.create(user=u, name='XpBoostHelper')

    def test_inactive_boost_returns_unchanged(self):
        self.player.xp_boost_active_until = None
        self.assertEqual(apply_xp_boost_if_active(self.player, 30), 30)

    def test_active_boost_applies_1_5x_with_round(self):
        self.player.xp_boost_active_until = timezone.now() + timedelta(hours=1)
        # round(30 * 1.5) = 45, round(45 * 1.5) = 68 (端数 round)
        self.assertEqual(apply_xp_boost_if_active(self.player, 30), 45)
        self.assertEqual(apply_xp_boost_if_active(self.player, 45), 68)

    def test_expired_boost_returns_unchanged(self):
        self.player.xp_boost_active_until = timezone.now() - timedelta(hours=1)
        self.assertEqual(apply_xp_boost_if_active(self.player, 30), 30)


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class UseXpBoostViewTest(APITestCase):
    """シナリオ 4-6: POST /api/items/use-xp-boost/ の契約テスト。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='use_xp_boost_test', password='pw')
        self.player = PlayerProfile.objects.create(user=self.user)
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    def _use(self, **kwargs):
        return self.client.post('/api/items/use-xp-boost/', data=kwargs, format='json')

    def test_insufficient_stock_returns_400(self):
        res = self._use()
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST, res.data)
        self.assertEqual(error_code(res), 'insufficient_stock')

        self.player.refresh_from_db()
        self.assertIsNone(self.player.xp_boost_active_until)

    def test_success_activates_boost_and_consumes_stock(self):
        PlayerItem.objects.create(player=self.player, item_id='xp_boost_1.5x', quantity=2)

        before = timezone.now()
        res = self._use()
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)

        self.assertEqual(res.data['remaining_quantity'], 1)
        # 【BUG-116 (2026-06-14)】効果時間を 24h → 15min/stock に変更。
        self.assertEqual(res.data['boosted_duration_minutes'], 15)

        # active_until は UTC isoformat (Pre-mortem #2)
        active_until = timezone.datetime.fromisoformat(res.data['active_until'])
        self.assertIsNotNone(active_until.tzinfo)
        expected = before + timedelta(minutes=15)
        self.assertAlmostEqual(active_until.timestamp(), expected.timestamp(), delta=5)

        self.player.refresh_from_db()
        self.assertIsNotNone(self.player.xp_boost_active_until)
        item = PlayerItem.objects.get(player=self.player, item_id='xp_boost_1.5x')
        self.assertEqual(item.quantity, 1)

    def test_consume_value_2_gives_30min_and_consumes_2(self):
        """【BUG-116 (2026-06-14)】効果時間を 24h → 15min/stock に変更。
        consume_value=2 → 15 × 2 = 30 分 (旧 48 時間)。"""
        PlayerItem.objects.create(player=self.player, item_id='xp_boost_1.5x', quantity=3)

        res = self._use(consume_value=2)
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)
        self.assertEqual(res.data['boosted_duration_minutes'], 30)
        self.assertEqual(res.data['remaining_quantity'], 1)

    def test_already_active_returns_409_without_extension(self):
        PlayerItem.objects.create(player=self.player, item_id='xp_boost_1.5x', quantity=5)

        original_until = timezone.now() + timedelta(hours=10)
        self.player.xp_boost_active_until = original_until
        self.player.save(update_fields=['xp_boost_active_until'])

        res = self._use()
        self.assertEqual(res.status_code, http_status.HTTP_409_CONFLICT, res.data)
        self.assertEqual(error_code(res), 'already_active')

        # 延長されない (Pre-mortem #1)
        self.player.refresh_from_db()
        self.assertAlmostEqual(
            self.player.xp_boost_active_until.timestamp(), original_until.timestamp(), delta=1,
        )
        # 在庫も消費されない
        item = PlayerItem.objects.get(player=self.player, item_id='xp_boost_1.5x')
        self.assertEqual(item.quantity, 5)


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class XpBoostExpPathsTest(APITestCase):
    """シナリオ 7-9: 習慣・バトル・タイムライン経路で boost が ×1.5 される確認。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='xp_boost_paths_test', password='pw')
        self.player = PlayerProfile.objects.create(
            user=self.user, level=20, max_exp=10000, mode='training',
        )
        create_default_stats(self.player)
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    def _activate_boost(self):
        self.player.xp_boost_active_until = timezone.now() + timedelta(hours=1)
        self.player.save(update_fields=['xp_boost_active_until'])

    def test_habit_completion_exp_boosted(self):
        habit = Habit.objects.create(
            player=self.player, name='テスト習慣', category='運動',
            difficulty='easy', habit_type='count',
            frequency='daily', reset_cycle='daily',
        )
        self._activate_boost()

        res = self.client.post(f'/api/habits/{habit.pk}/count/', {'action': 'plus'}, format='json')
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)

        # streak=0 → base=10 (FEAT-434 streak ベース EXP) → ブースト時 round(10 * 1.5) = 15
        self.assertEqual(res.data['exp_gain'], 15)

    def test_battle_victory_exp_boosted(self):
        enemy = _ensure_goblin_exists()
        self.player.battle_charges      = 3
        self.player.battle_charges_date = timezone.localdate()
        self.player.save(update_fields=['battle_charges', 'battle_charges_date'])
        self._activate_boost()

        start_res = self.client.post('/api/battle/start/', {'enemy_key': 'goblin'}, format='json')
        self.assertEqual(start_res.status_code, http_status.HTTP_200_OK, start_res.data)
        token = start_res.data['token']

        finish_res = self.client.post('/api/battle/finish/', {
            'token': token, 'result': 'win', 'duration_sec': 30,
            'damage_dealt': 10, 'damage_taken': 5, 'rounds': 3, 'potions_used': 0,
        }, format='json')
        self.assertEqual(finish_res.status_code, http_status.HTTP_200_OK, finish_res.data)

        # 【FEAT-495 (2026-07-25)】base = enemy.reward_exp (bake 済実効値)
        # → boosted round(base * 1.5)
        base = enemy.reward_exp
        self.assertEqual(finish_res.data['exp_gained'], round(base * 1.5))

    def test_timeline_completion_exp_boosted(self):
        event = TimelineEvent.objects.create(
            player=self.player, title='テスト予定', category='運動',
            date=timezone.localdate(),
        )
        self._activate_boost()

        res = self.client.post(f'/api/timeline/{event.pk}/complete/', {}, format='json')
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)

        # '運動' カテゴリの base = 20 (_TIMELINE_EXP_MAP) → ブースト時 round(20 * 1.5) = 30
        self.assertEqual(res.data['exp_gain'], 30)
