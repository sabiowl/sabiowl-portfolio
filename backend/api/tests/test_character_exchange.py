"""【FEAT-427 (2026-06-11)】CharacterExchangeView (POST /api/characters/<pk>/exchange/) の契約テスト。

検証対象:
1. 1 枚 + 未所持 SSR 指定 → 成功、ticket→0、OwnedCharacter 作成
2. 0 枚 → 400 no_ticket
3. 存在しない character_id → 404
4. SR キャラ (price < 3000) 指定 → 400 not_ssr
5. 既所持 SSR → 400 already_owned
6. 並列リクエスト → select_for_update により 1 回のみ成功
"""
import threading

from django.contrib.auth import get_user_model
from django.db import connection
from django.test import TransactionTestCase, override_settings
from django.urls import reverse
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Character, OwnedCharacter, PlayerProfile
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


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class CharacterExchangeContractTest(APITestCase):
    """FEAT-427: キャラ交換券 1 枚消費 → 未所持 SSR キャラ獲得の契約。"""

    def setUp(self):
        self.user = User.objects.create_user('exchange_player', email='exchange@example.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='Player',
            character_exchange_tickets=1,
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # 【BUG-108 (2026-06-14)】SSR キャラ判定を is_starter=False に変更。
        # 旧 price>=3000 から is_starter=False に切替 (price 1500 統一後の新判定)。
        self.ssr_char = Character.objects.filter(is_starter=False).first()
        if self.ssr_char is None:
            self.ssr_char = Character.objects.create(
                key='exchange_ssr', name='交換用SSR', role='テスト',
                description='', image_path='character_exchange_ssr',
                price=1500, unlock_level=1, is_starter=False,
                order=99,
            )

        # 【BUG-108】starter キャラ (sol/aria) は SSR 交換対象外 (rejected tier)。
        # シナリオ 4 の「not_ssr 400」確認用。
        self.starter_char = Character.objects.filter(is_starter=True).first()
        if self.starter_char is None:
            self.starter_char = Character.objects.create(
                key='exchange_starter', name='交換用starter', role='テスト',
                description='', image_path='character_exchange_starter',
                price=0, unlock_level=1, is_starter=True,
                order=98,
            )

    def _exchange(self, character_id):
        return self.client.post(reverse('character-exchange', args=[character_id]))

    # ─────────────────────────────────────────────────────────────
    # シナリオ 1: 1 枚 + 未所持 SSR → 成功
    # ─────────────────────────────────────────────────────────────
    def test_exchange_with_ticket_and_unowned_ssr_succeeds(self):
        res = self._exchange(self.ssr_char.pk)
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)

        self.player.refresh_from_db()
        self.assertEqual(self.player.character_exchange_tickets, 0)
        self.assertTrue(
            OwnedCharacter.objects.filter(
                player=self.player, character=self.ssr_char,
            ).exists()
        )
        self.assertEqual(res.data['character_exchange_tickets'], 0)
        self.assertEqual(res.data['character']['id'], self.ssr_char.pk)

    # ─────────────────────────────────────────────────────────────
    # シナリオ 2: 0 枚 → 400 no_ticket
    # ─────────────────────────────────────────────────────────────
    def test_exchange_without_ticket_returns_400(self):
        self.player.character_exchange_tickets = 0
        self.player.save(update_fields=['character_exchange_tickets'])

        res = self._exchange(self.ssr_char.pk)
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        self.assertEqual(error_code(res), 'no_ticket')
        self.assertFalse(
            OwnedCharacter.objects.filter(
                player=self.player, character=self.ssr_char,
            ).exists()
        )

    # ─────────────────────────────────────────────────────────────
    # シナリオ 3: 存在しない character_id → 404
    # ─────────────────────────────────────────────────────────────
    def test_exchange_nonexistent_character_returns_404(self):
        res = self._exchange(999999)
        self.assertEqual(res.status_code, http_status.HTTP_404_NOT_FOUND)
        # 【FEAT-475 Phase 3c (2026-07-04)】新形式 {'error': {'code', 'message'}}
        self.assertEqual(error_code(res), 'character_exchange_not_found')

        # チケットは消費されない
        self.player.refresh_from_db()
        self.assertEqual(self.player.character_exchange_tickets, 1)

    # ─────────────────────────────────────────────────────────────
    # シナリオ 4: starter (is_starter=True) 指定 → 400 not_ssr (BUG-108)
    # ─────────────────────────────────────────────────────────────
    def test_exchange_starter_character_returns_400(self):
        """starter キャラ (sol/aria) は SSR 交換対象外。BUG-108 で判定基準を
        price >= 3000 → is_starter=False に変更したため、starter は rejected。"""
        res = self._exchange(self.starter_char.pk)
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        self.assertEqual(error_code(res), 'not_ssr')

        # チケットは消費されない
        self.player.refresh_from_db()
        self.assertEqual(self.player.character_exchange_tickets, 1)

    # ─────────────────────────────────────────────────────────────
    # シナリオ 5: 既所持 SSR → 400 already_owned
    # ─────────────────────────────────────────────────────────────
    def test_exchange_already_owned_returns_400(self):
        OwnedCharacter.objects.create(player=self.player, character=self.ssr_char)

        res = self._exchange(self.ssr_char.pk)
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        self.assertEqual(error_code(res), 'already_owned')

        # チケットは消費されない
        self.player.refresh_from_db()
        self.assertEqual(self.player.character_exchange_tickets, 1)


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class CharacterExchangeRaceTest(TransactionTestCase):
    """FEAT-427 シナリオ 6: 並列リクエスト → select_for_update により 1 回のみ成功。"""

    reset_sequences = True

    def setUp(self):
        self.user = User.objects.create_user('race_player', email='race@example.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='Player',
            character_exchange_tickets=1,
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)

        # 【BUG-108】SSR 判定を is_starter=False に変更 (race test も同じ基準)
        self.ssr_char = Character.objects.filter(is_starter=False).first()
        if self.ssr_char is None:
            self.ssr_char = Character.objects.create(
                key='race_ssr', name='並列用SSR', role='テスト',
                description='', image_path='character_race_ssr',
                price=1500, unlock_level=1, is_starter=False,
                order=97,
            )

    def test_concurrent_exchange_only_one_succeeds(self):
        from rest_framework.test import APIClient

        results = []

        def _do_request():
            client = APIClient()
            client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
            res = client.post(reverse('character-exchange', args=[self.ssr_char.pk]))
            results.append(res.status_code)
            connection.close()

        threads = [threading.Thread(target=_do_request) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(results.count(200), 1, f'1 回だけ成功するはず: {results}')
        self.assertEqual(results.count(400), 1, f'1 回は in_ticket 不足で 400 のはず: {results}')

        self.player.refresh_from_db()
        self.assertEqual(self.player.character_exchange_tickets, 0)
        self.assertEqual(
            OwnedCharacter.objects.filter(
                player=self.player, character=self.ssr_char,
            ).count(),
            1,
        )
