"""【FEAT-389 (2026-05-30)】キャラ購入のダイヤ消費 + Monthly ガチャ排出契約テスト。

検証対象:
1. ダイヤ十分 → 購入成功、diamonds 減少、OwnedCharacter 作成
2. ダイヤ不足 → 400、購入未完了
3. 【BUG-133 (2026-06-17)】Lv 不足でも購入可能 (Lv チェック撤去後)
4. 二重購入 → 400
5. Monthly SSR character GachaReward が存在 (migration 0111)
"""
from django.contrib.auth import get_user_model
from django.test import override_settings
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Character, GachaReward, OwnedCharacter, PlayerProfile
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


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class CharacterPurchaseDiamondTest(APITestCase):
    """CharacterPurchaseView のダイヤ消費契約テスト。"""

    def setUp(self):
        self.user = User.objects.create_user(username='char_buyer', password='pw')
        self.player = PlayerProfile.objects.create(
            user=self.user,
            name='テスト',
            diamonds=8000,  # 残高 8000💎 (BUG-131 で価格 6000 に変更、購入可能な余裕分)
            level=10,
        )
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # cyan を使用 (BUG-131 で全 non-starter キャラの価格を 6000 に変更、migration 0144)
        try:
            self.cyan = Character.objects.get(key='cyan')
        except Character.DoesNotExist:
            # テスト DB で migration が未適用の場合、ダミーキャラを作成
            self.cyan = Character.objects.create(
                key='cyan', name='シアン', role='青魔導士',
                description='', image_path='character_cyan',
                price=6000, unlock_level=1, is_starter=False,
                display_order=3,
            )
        # migration 0161: is_published=True でないと CharacterPurchaseView が 403 を返す
        self.cyan.is_published = True
        self.cyan.save(update_fields=['is_published'])

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: ダイヤ十分 → 購入成功
    # ─────────────────────────────────────────────────────────────────
    def test_purchase_with_sufficient_diamonds(self):
        """ダイヤ十分なら購入成功、diamonds 減少、OwnedCharacter 作成。"""
        res = self.client.post(f'/api/characters/{self.cyan.pk}/purchase/')

        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)
        # ダイヤ減少確認
        self.assertEqual(res.data.get('diamonds'), 8000 - self.cyan.price)
        # OwnedCharacter 作成確認
        self.assertTrue(
            OwnedCharacter.objects.filter(
                player=self.player, character=self.cyan,
            ).exists()
        )
        # DB 上のダイヤも減少確認
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 8000 - self.cyan.price)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: ダイヤ不足 → 400
    # ─────────────────────────────────────────────────────────────────
    def test_purchase_with_insufficient_diamonds_returns_400(self):
        """ダイヤ不足なら 400、購入未完了。"""
        self.player.diamonds = 100  # cyan の 6000 未満 (BUG-131)
        self.player.save(update_fields=['diamonds'])

        res = self.client.post(f'/api/characters/{self.cyan.pk}/purchase/')

        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        # 【2026-07-06 review】文言をサビ口調に統一
        self.assertIn('ダイヤが少し足りません', error_message(res))
        self.assertEqual(error_code(res), 'not_enough_diamonds')
        self.assertFalse(
            OwnedCharacter.objects.filter(
                player=self.player, character=self.cyan,
            ).exists()
        )
        # ダイヤ残高は変わらない
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 100)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: 【BUG-133 (2026-06-17)】Lv 不足でも購入可能 (Lv チェック撤去)
    # ─────────────────────────────────────────────────────────────────
    def test_purchase_below_old_unlock_level_succeeds(self):
        """noir (旧 unlock_level=20) を Lv.10 で購入試行 → 200 (BUG-133 で Lv チェック撤去)。

        「キャラはレベルで開放する仕様ではない」(PM 判断) により、Character.unlock_level
        の値に関わらずダイヤ残高さえあれば購入可能となる契約を縛る。
        """
        try:
            noir = Character.objects.get(key='noir')
        except Character.DoesNotExist:
            noir = Character.objects.create(
                key='noir', name='ノワール', role='暗黒魔道士',
                description='', image_path='character_noir',
                price=6000, unlock_level=20, is_starter=False,
                display_order=7,
            )
        # migration 0161: is_published=True でないと CharacterPurchaseView が 403 を返す
        noir.is_published = True
        noir.save(update_fields=['is_published'])

        # setUp で player.level=10 < noir.unlock_level=20 だが、Lv チェック撤去で
        # 購入成功するはず。setUp の diamonds=8000 で noir.price=6000 をカバー。
        res = self.client.post(f'/api/characters/{noir.pk}/purchase/')
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)
        self.assertTrue(
            OwnedCharacter.objects.filter(
                player=self.player, character=noir,
            ).exists()
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 4: 二重購入 → 400
    # ─────────────────────────────────────────────────────────────────
    def test_duplicate_purchase_returns_400(self):
        """既に所持しているキャラを再購入 → 400。"""
        OwnedCharacter.objects.create(player=self.player, character=self.cyan)

        res = self.client.post(f'/api/characters/{self.cyan.pk}/purchase/')
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        # 【2026-07-06 review】文言をサビ口調に統一
        self.assertIn('すでにお持ちのキャラクター', error_message(res))
        self.assertEqual(error_code(res), 'already_owned')


class MonthlyGachaCharacterRewardTest(APITestCase):
    """migration 0111 で Monthly SSR character GachaReward が存在することを確認。

    【BUG-95 (2026-06-12)】migration 0131 で is_active=False に廃止 → 【BUG-97
    (2026-06-12)】migration 0132 で「マンスリーキャラ (SSR)」に改名 + 再活性化
    (is_active=True, weight=100)。entry 自体は残存 (master/seed data、DELETE
    せず UPDATE のみ) のため count=1 の確認は維持し、weight/is_active を更新。
    """

    def test_monthly_ssr_character_reward_exists(self):
        """Monthly SSR character (weight=100) が GachaReward に存在し、BUG-97 で is_active=True。"""
        rewards = GachaReward.objects.filter(
            ticket_type='monthly',
            rarity='SSR',
            reward_type='character',
        )
        self.assertEqual(
            rewards.count(), 1,
            msg='Monthly SSR character reward が 1 件存在するはず (migration 0111)',
        )
        self.assertEqual(rewards.first().weight, 100)
        self.assertEqual(rewards.first().is_active, True)
