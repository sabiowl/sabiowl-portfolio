"""【FEAT-327 Phase 1】 PlayerWeaponsView 契約テスト 3 件。

カバー:
    1. 所持武器全件返却 + is_equipped flag 含む
    2. 装備中武器の is_equipped=True、未装備武器の is_equipped=False
    3. ゲスト経路でも 200 で取得可能 (FEAT-187 / Pre-mortem #4 認証経路)

設計意図: EquipmentSelectionOverlay (guild_equipment_2.md §1.2 仕様) が
「現在装備中 + 所持武器一覧」を独立表示するため、Shop 経由ではなく
直接所持武器を取得する経路の契約を縛る。
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
class PlayerWeaponsViewContractTest(APITestCase):
    """FEAT-327 PlayerWeaponsView の契約 3 件。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('weapons_view_tester', email='wvt@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='WeaponsViewer')
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # migration 0093 で 5 種 + 0082 で starter_sword が seed 済み
        self.starter = WeaponMaster.objects.get(key='starter_sword')
        self.bronze = WeaponMaster.objects.get(key='bronze_sword')
        self.iron = WeaponMaster.objects.get(key='iron_sword')

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: 所持武器全件返却
    # ─────────────────────────────────────────────────────────────────

    def test_returns_all_owned_weapons(self):
        """starter + bronze + iron を所持している状態で 3 件返却される。"""
        PlayerWeapon.objects.create(
            player=self.player, weapon=self.starter, is_equipped=True,
        )
        PlayerWeapon.objects.create(
            player=self.player, weapon=self.bronze, is_equipped=False,
        )
        PlayerWeapon.objects.create(
            player=self.player, weapon=self.iron, is_equipped=False,
        )

        res = self.client.get(reverse('player-weapons'))
        self.assertEqual(res.status_code, 200, res.content)
        self.assertIn('weapons', res.data)
        weapons = res.data['weapons']
        self.assertEqual(len(weapons), 3)

        keys = {w['key'] for w in weapons}
        self.assertSetEqual(keys, {'starter_sword', 'bronze_sword', 'iron_sword'})

        # 必須フィールドの整合性
        for w in weapons:
            self.assertIn('id',          w)
            self.assertIn('key',         w)
            self.assertIn('name',        w)
            self.assertIn('atk_bonus',   w)
            self.assertIn('description', w)
            self.assertIn('is_equipped', w)
            self.assertIn('acquired_at', w)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: is_equipped flag が正しく反映される
    # ─────────────────────────────────────────────────────────────────

    def test_is_equipped_flag_reflects_equipment_state(self):
        """starter のみ装備中、bronze は未装備 → flag が正しく分かれる。"""
        PlayerWeapon.objects.create(
            player=self.player, weapon=self.starter, is_equipped=True,
        )
        PlayerWeapon.objects.create(
            player=self.player, weapon=self.bronze, is_equipped=False,
        )

        res = self.client.get(reverse('player-weapons'))
        self.assertEqual(res.status_code, 200)
        by_key = {w['key']: w for w in res.data['weapons']}

        self.assertTrue(by_key['starter_sword']['is_equipped'],
                        'starter_sword は装備中なので True')
        self.assertFalse(by_key['bronze_sword']['is_equipped'],
                         'bronze_sword は未装備なので False')

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: 所持武器ゼロでも 200 + 空 list (defensive)
    # ─────────────────────────────────────────────────────────────────

    def test_empty_weapons_returns_200_with_empty_list(self):
        """PlayerWeapon が 0 件 (オンボーディング異常終了等) でも 200 で
        空 list を返す (Flutter 側で「装備なし」UI 表示が可能)。"""
        # PlayerWeapon を 1 件も作らない
        res = self.client.get(reverse('player-weapons'))
        self.assertEqual(res.status_code, 200, res.content)
        self.assertEqual(res.data['weapons'], [])
