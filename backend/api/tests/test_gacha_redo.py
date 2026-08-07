"""【FEAT-374 (2026-05-29)】ガチャ「もう 1 度」💎 50 の契約テスト。

検証対象:
1. redo 成功 → 💎 50 消費 + 新しい報酬が返却される
2. redo_used=True のとき拒否 (redo_already_used)
3. 24h 経過後に拒否 (redo_expired)
4. ダイヤ不足のとき拒否 (redo_insufficient_diamonds)
"""
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.test import override_settings
from django.utils import timezone
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import GachaReward, PlayerGachaStatus, PlayerProfile
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


def _seed_basic_rewards():
    """ガチャ報酬を最小限シードする（テスト環境 DB では _ensure_gacha_rewards が呼ばれていない場合がある）。"""
    GachaReward.objects.get_or_create(
        ticket_type='daily', name='EXP ボーナス', detail='EXP +30',
        defaults=dict(rarity='N', reward_type='exp', weight=100, value=30, icon='⭐'),
    )


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class GachaRedoTest(APITestCase):
    """GachaRedoView の契約テスト。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='redo_tester', password='pw')
        self.player = PlayerProfile.objects.create(user=self.user, diamonds=100)
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        _seed_basic_rewards()

        # 直近 pull 済み状態を仕込む
        self.gacha_status = PlayerGachaStatus.objects.create(
            player=self.player,
            last_pull_id=1,
            last_pull_at=timezone.now(),
            last_pull_pool='daily',
            redo_used=False,
        )

    def _post_redo(self):
        return self.client.post('/api/gacha/redo/', format='json')

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: redo 成功 → 💎 50 消費 + 新しい報酬返却
    # ─────────────────────────────────────────────────────────────────
    def test_redo_success_consumes_50_diamonds_and_returns_new_pull(self):
        initial_diamonds = self.player.diamonds  # 100

        res = self._post_redo()
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)

        # 💎 50 消費
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, initial_diamonds - 50)

        # 報酬が返却される
        self.assertIn('reward', res.data)
        self.assertIn('rarity', res.data['reward'])

        # redo_used が True に更新されている
        self.gacha_status.refresh_from_db()
        self.assertTrue(self.gacha_status.redo_used)

        # redo_available は False (使用済み)
        self.assertFalse(res.data.get('redo_available', True))

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: redo_used=True のとき拒否
    # ─────────────────────────────────────────────────────────────────
    def test_redo_rejected_when_already_used(self):
        self.gacha_status.redo_used = True
        self.gacha_status.save(update_fields=['redo_used'])

        res = self._post_redo()
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        # 【FEAT-475 Phase 3b (2026-07-04)】新形式 {'error': {'code', 'message'}}
        self.assertEqual(error_code(res), 'gacha_redo_already_used')

        # ダイヤは消費されない
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 100)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: 24h 経過後に拒否
    # ─────────────────────────────────────────────────────────────────
    def test_redo_rejected_when_24h_expired(self):
        self.gacha_status.last_pull_at = timezone.now() - timedelta(hours=25)
        self.gacha_status.save(update_fields=['last_pull_at'])

        res = self._post_redo()
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        # 【FEAT-475 Phase 3b (2026-07-04)】新形式
        self.assertEqual(error_code(res), 'gacha_redo_expired')

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 4: ダイヤ不足のとき拒否
    # ─────────────────────────────────────────────────────────────────
    def test_redo_rejected_when_diamonds_insufficient(self):
        self.player.diamonds = 30  # 50 未満
        self.player.save(update_fields=['diamonds'])

        res = self._post_redo()
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        # 【FEAT-475 Phase 3b (2026-07-04)】新形式
        self.assertEqual(error_code(res), 'gacha_redo_insufficient_diamonds')

        # ダイヤは消費されない
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 30)
