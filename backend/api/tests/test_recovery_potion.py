"""【FEAT-298】回復薬システムの契約テスト。

指示書 §1.3 で定義した 4 シナリオ（Shop 購入 / 99 上限 / BattleStart 検証 /
BattleFinish 消費）を縛る。

設計ノート (`doc/design/battle_system.md`) と整合:
  - PlayerItem.item_id = 'recovery_potion' で保存
  - max_stock=99（経済バランス保護）
  - potions_planned / potions_used で事前申告と実消費を分離記録
  - select_for_update のレンデブー順序: PlayerProfile → Battle → PlayerItem
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
import datetime

from django.test import override_settings
from django.urls import reverse
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import (
    Battle,
    Enemy,
    PlayerItem,
    PlayerProfile,
    WeaponMaster,
)
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
class RecoveryPotionContractTest(APITestCase):
    """FEAT-298: 回復薬 Backend 契約 5 件。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('player1', email='p1@example.com')
        # 十分なダイヤ（30 💎/個 × 99 まで購入可能）+ charges=3（バトル開始可）。
        self.player = PlayerProfile.objects.create(
            user=self.user,
            name='Player1',
            diamonds=10000,
            battle_charges=3,
            battle_charges_date=datetime.date.today(),
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # seed: テスト独立性のため update_or_create で期待値を強制。
        self.enemy, _ = Enemy.objects.update_or_create(
            key='goblin',
            defaults={
                'name':          'ゴブリン',
                'sprite_key':    'enemy_goblin',
                'base_hp':       60,
                'base_atk':      8,
                'base_spd':      10,
                'level_scaling': 1.0,
                'reward_coins':  10,
                'reward_exp':    20,
                'tier':          'zako',
            },
        )
        WeaponMaster.objects.update_or_create(
            key='starter_sword',
            defaults={'name': '見習いの剣', 'atk_bonus': 10},
        )

    # ─────────────────────────────────────────────────────────────
    # シナリオ 1: Shop で回復薬購入 → PlayerItem.quantity += 1
    # ─────────────────────────────────────────────────────────────
    def test_shop_purchase_recovery_potion_increments_player_item(self):
        before = PlayerItem.objects.filter(
            player=self.player, item_id='recovery_potion',
        ).first()
        self.assertIsNone(before, '前提: 初期所持 0 個')

        res = self.client.post(
            reverse('shop-purchase'),
            data={'item_id': 'recovery_potion'},
            format='json',
        )
        self.assertEqual(res.status_code, http_status.HTTP_201_CREATED, res.content)
        self.assertEqual(res.data['item_id'], 'recovery_potion')
        self.assertEqual(res.data['owned_quantity'], 1)

        item = PlayerItem.objects.get(player=self.player, item_id='recovery_potion')
        self.assertEqual(item.quantity, 1)

        # ダイヤが 30 消費されている
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 10000 - 30)

    # ─────────────────────────────────────────────────────────────
    # シナリオ 2: 99 個所持時に購入要求 → 400 + サビ口調 + ダイヤ未消費
    # ─────────────────────────────────────────────────────────────
    def test_shop_purchase_recovery_potion_at_max_stock_rejects(self):
        PlayerItem.objects.create(
            player=self.player, item_id='recovery_potion', quantity=99,
        )
        diamonds_before = self.player.diamonds

        res = self.client.post(
            reverse('shop-purchase'),
            data={'item_id': 'recovery_potion'},
            format='json',
        )
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        # サビ口調確認: 🪶 マーカー + 紳士的トーン（〜になれません）
        self.assertIn('🪶', error_message(res))

        # quantity 据え置き + ダイヤ未消費（無駄遣い防止）
        item = PlayerItem.objects.get(player=self.player, item_id='recovery_potion')
        self.assertEqual(item.quantity, 99)
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, diamonds_before)

    # ─────────────────────────────────────────────────────────────
    # シナリオ 3: BattleStart で potions_to_use=3（所持 3 個）→ planned 保存
    # ─────────────────────────────────────────────────────────────
    def test_battle_start_with_potions_to_use_records_planned(self):
        PlayerItem.objects.create(
            player=self.player, item_id='recovery_potion', quantity=3,
        )

        res = self.client.post(
            reverse('battle-start'),
            data={'potions_to_use': 3},
            format='json',
        )
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.content)

        battle = Battle.objects.get(token=res.data['token'])
        self.assertEqual(battle.potions_planned, 3)
        # まだ消費はされていない（finish で消費）
        item = PlayerItem.objects.get(player=self.player, item_id='recovery_potion')
        self.assertEqual(item.quantity, 3)

    # ─────────────────────────────────────────────────────────────
    # シナリオ 4: BattleStart で potions_to_use=5（範囲外）→ 400
    # ─────────────────────────────────────────────────────────────
    def test_battle_start_with_potions_to_use_out_of_range_rejects(self):
        # 範囲外（5 > _MAX_POTIONS_PER_BATTLE=3）
        res = self.client.post(
            reverse('battle-start'),
            data={'potions_to_use': 5},
            format='json',
        )
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        self.assertEqual(error_code(res), 'potions_to_use_out_of_range')
        self.assertIn('🪶', error_message(res))
        # Battle レコード未作成（charge も未消費）
        self.assertEqual(Battle.objects.filter(player=self.player).count(), 0)

    # ─────────────────────────────────────────────────────────────
    # シナリオ 4-b: BattleStart で潜在所持数を超える要求 → 400
    # ─────────────────────────────────────────────────────────────
    def test_battle_start_with_potions_exceeding_owned_rejects(self):
        # 1 個所持、3 個使う宣言 → 400「所持数を超えています」
        PlayerItem.objects.create(
            player=self.player, item_id='recovery_potion', quantity=1,
        )

        res = self.client.post(
            reverse('battle-start'),
            data={'potions_to_use': 3},
            format='json',
        )
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        self.assertEqual(error_code(res), 'not_enough_potions')
        self.assertIn('🪶', error_message(res))
        self.assertEqual(res.data['owned'], 1)
        self.assertEqual(res.data['requested'], 3)
        # Battle 未作成
        self.assertEqual(Battle.objects.filter(player=self.player).count(), 0)

    # ─────────────────────────────────────────────────────────────
    # シナリオ 5: BattleFinish で potions_used=2 → PlayerItem -= 2 + 履歴保存
    # ─────────────────────────────────────────────────────────────
    def test_battle_finish_with_potions_used_decrements_player_item(self):
        PlayerItem.objects.create(
            player=self.player, item_id='recovery_potion', quantity=3,
        )

        # start: potions_to_use=3 を申告
        start_res = self.client.post(
            reverse('battle-start'),
            data={'potions_to_use': 3},
            format='json',
        )
        self.assertEqual(start_res.status_code, http_status.HTTP_200_OK)
        token = start_res.data['token']

        # finish: 2 個実消費（申告 3 のうち 2 個使用）
        finish_res = self.client.post(
            reverse('battle-finish'),
            data={
                'token':        token,
                'result':       'win',
                'duration_sec': 30,
                'damage_dealt': 60,
                'damage_taken': 20,
                'rounds':       5,
                'potions_used': 2,
                'summary_text': 'サビ 通常攻撃 → ゴブリン -15HP',
            },
            format='json',
        )
        self.assertEqual(finish_res.status_code, http_status.HTTP_200_OK,
                         finish_res.content)

        # PlayerItem.quantity が 3 - 2 = 1 に減っている
        item = PlayerItem.objects.get(player=self.player, item_id='recovery_potion')
        self.assertEqual(item.quantity, 1)

        # Battle.potions_used が履歴として保存されている
        battle = Battle.objects.get(token=token)
        self.assertEqual(battle.potions_planned, 3)
        self.assertEqual(battle.potions_used, 2)

    # ─────────────────────────────────────────────────────────────
    # シナリオ 5-b: potions_used が planned を超える → 400
    # ─────────────────────────────────────────────────────────────
    def test_battle_finish_with_potions_used_exceeds_planned_rejects(self):
        PlayerItem.objects.create(
            player=self.player, item_id='recovery_potion', quantity=3,
        )

        # start: potions_to_use=1 で申告
        start_res = self.client.post(
            reverse('battle-start'),
            data={'potions_to_use': 1},
            format='json',
        )
        token = start_res.data['token']

        # finish: 3 個使用したと主張（チート）→ planned(1) 超過で 400
        finish_res = self.client.post(
            reverse('battle-finish'),
            data={
                'token':        token,
                'result':       'win',
                'duration_sec': 30,
                'damage_dealt': 60,
                'damage_taken': 20,
                'rounds':       5,
                'potions_used': 3,
                'summary_text': '...',
            },
            format='json',
        )
        self.assertEqual(finish_res.status_code, http_status.HTTP_400_BAD_REQUEST)
        self.assertEqual(error_code(finish_res), 'potions_used_exceeds_planned')
        self.assertIn('🪶', error_message(finish_res))

        # PlayerItem.quantity は減っていない（atomic で rollback）
        item = PlayerItem.objects.get(player=self.player, item_id='recovery_potion')
        self.assertEqual(item.quantity, 3)
        # Battle は finish されていない
        battle = Battle.objects.get(token=token)
        self.assertIsNone(battle.finished_at)
