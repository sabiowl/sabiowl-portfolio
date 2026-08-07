"""【FEAT-326 Phase 1】 EquipWeaponView + PlayerProfileSerializer.equipped_weapon
契約テスト 5 件。

カバー:
    1. 武器装備変更で equipped_weapon フィールドが新武器を返す
    2. 所持していない武器を装備しようとして 404 (weapon_not_owned)
    3. 装備変更で他の PlayerWeapon の is_equipped が False になる (1 人 1 武器)
    4. PlayerProfileSerializer.equipped_weapon が atk_bonus 含めて返す
       (Flutter 側 damage 計算でクライアント参照する経路の契約)
    5. 武器未所持 (極端ケース) で equipped_weapon=null フォールバック
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import PlayerProfile, PlayerWeapon, WeaponMaster
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
class EquipWeaponContractTest(APITestCase):
    """FEAT-326 武器装備変更 + 装備中武器シリアライザの契約 5 件。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('weapon_tester', email='wt@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='Tester')
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # migration 0082 で starter_sword、0093 で 5 種が seed 済み
        self.starter = WeaponMaster.objects.get(key='starter_sword')
        self.bronze = WeaponMaster.objects.get(key='bronze_sword')
        self.iron = WeaponMaster.objects.get(key='iron_sword')

        # 初期状態: starter_sword を所持 + 装備
        self.starter_pw = PlayerWeapon.objects.create(
            player=self.player, weapon=self.starter, is_equipped=True,
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: 装備変更で equipped_weapon が新武器を返す
    # ─────────────────────────────────────────────────────────────────

    def test_equip_weapon_returns_new_equipped(self):
        """所持している iron_sword に装備変更 → equipped_weapon が iron_sword を返す。"""
        # 事前準備: iron_sword を購入済の状態にする
        PlayerWeapon.objects.create(
            player=self.player, weapon=self.iron, is_equipped=False,
        )

        res = self.client.patch(
            reverse('player-equip-weapon'),
            data={'weapon_id': self.iron.id},
            format='json',
        )
        self.assertEqual(res.status_code, 200, res.content)
        body = res.data
        self.assertIn('equipped_weapon', body)
        ew = body['equipped_weapon']
        self.assertEqual(ew['id'],        self.iron.id)
        self.assertEqual(ew['key'],       'iron_sword')
        self.assertEqual(ew['name'],      '鉄の剣')
        self.assertEqual(ew['atk_bonus'], 10)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: 所持していない武器を装備しようとして 404
    # ─────────────────────────────────────────────────────────────────

    def test_equip_unowned_weapon_returns_404(self):
        """bronze_sword を購入していない状態で装備変更しようとすると 404。"""
        res = self.client.patch(
            reverse('player-equip-weapon'),
            data={'weapon_id': self.bronze.id},
            format='json',
        )
        self.assertEqual(res.status_code, 404, res.content)
        self.assertEqual(error_code(res), 'weapon_not_owned')

        # DB 側でも変更されていない (starter のまま装備)
        self.starter_pw.refresh_from_db()
        self.assertTrue(self.starter_pw.is_equipped)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: 装備変更で他の PlayerWeapon.is_equipped が False になる
    # ─────────────────────────────────────────────────────────────────

    def test_equip_weapon_clears_other_is_equipped(self):
        """iron_sword に装備変更 → starter_sword の is_equipped が False になる
        (1 人 1 武器の不変条件、UniqueConstraint 違反防止)。"""
        iron_pw = PlayerWeapon.objects.create(
            player=self.player, weapon=self.iron, is_equipped=False,
        )

        res = self.client.patch(
            reverse('player-equip-weapon'),
            data={'weapon_id': self.iron.id},
            format='json',
        )
        self.assertEqual(res.status_code, 200)

        # iron は equipped、starter は non-equipped
        iron_pw.refresh_from_db()
        self.starter_pw.refresh_from_db()
        self.assertTrue(iron_pw.is_equipped, 'iron_sword should now be equipped')
        self.assertFalse(self.starter_pw.is_equipped, 'starter_sword should no longer be equipped')

        # 装備中の PlayerWeapon は常に 1 件のみ (1 人 1 武器契約)
        equipped_count = PlayerWeapon.objects.filter(
            player=self.player, is_equipped=True,
        ).count()
        self.assertEqual(equipped_count, 1)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 4: PlayerProfileSerializer.equipped_weapon が atk_bonus 含めて返す
    # ─────────────────────────────────────────────────────────────────

    def test_player_serializer_returns_equipped_weapon_with_atk_bonus(self):
        """GET /api/player/ レスポンスに equipped_weapon.atk_bonus が含まれる
        (Flutter 側 BattleOrchestrator の damage 計算で参照する経路の契約)。"""
        res = self.client.get(reverse('player'))
        self.assertEqual(res.status_code, 200, res.content)
        self.assertIn('equipped_weapon', res.data)
        ew = res.data['equipped_weapon']
        self.assertIsNotNone(ew, 'starter_sword が equipped 状態のため non-null')
        self.assertEqual(ew['key'],       'starter_sword')
        self.assertEqual(ew['atk_bonus'], 10)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 5: 武器未所持で equipped_weapon=null フォールバック
    # ─────────────────────────────────────────────────────────────────

    def test_unowned_player_returns_null_equipped_weapon(self):
        """極端ケース: PlayerWeapon が 0 件 (オンボーディング異常終了等) でも
        500 にならず equipped_weapon=null を返す (Flutter 側で starter フォールバック)。"""
        # starter_sword を剥がす
        self.starter_pw.delete()

        res = self.client.get(reverse('player'))
        self.assertEqual(res.status_code, 200, res.content)
        self.assertIn('equipped_weapon', res.data)
        self.assertIsNone(res.data['equipped_weapon'],
                          'PlayerWeapon 0 件時は null フォールバック')
