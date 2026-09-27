"""【FEAT-495 (2026-07-25)】バトル EXP 契約テスト。

FEAT-406 で導入された × 0.3 削減は migration 0187 で Enemy.reward_exp に bake-in 済。
以降 finish.py は enemy.reward_exp をそのまま exp_gained として返す:

  - win  → exp_gained = enemy.reward_exp (DB 実効値)
  - lose → exp_gained = 0 (変わらず)

fixture の reward_exp は bake 済実効値を使用 (旧 raw 値 × 0.3 相当)。
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

import datetime

from api.constants import GameBalance
from api.models import Enemy, PlayerProfile, WeaponMaster

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
class BattleExpReductionTest(APITestCase):
    """バトル EXP 契約テスト (FEAT-495 bake-in 済)。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('exp_reduction_user', email='expr@t.com')
        # charges=3 で出陣可能
        self.player = PlayerProfile.objects.create(
            user=self.user, name='ExpReductionTest',
            battle_charges=3,
            battle_charges_date=datetime.date.today(),
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # テスト用 enemy (bake 済 reward_exp=6 = migration 0187 適用後の goblin 値)
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
                'reward_exp':    6,
                'tier':          'zako',
            },
        )
        WeaponMaster.objects.update_or_create(
            key='starter_sword',
            defaults={'name': '見習いの剣', 'atk_bonus': 10},
        )

    def _start_and_finish(self, result='win'):
        start_res = self.client.post(reverse('battle-start'))
        self.assertEqual(start_res.status_code, 200, start_res.content)
        token = start_res.data['token']

        finish_res = self.client.post(
            reverse('battle-finish'),
            data={
                'token':        token,
                'result':       result,
                'duration_sec': 30,
                'damage_dealt': 60,
                'damage_taken': 20,
                'rounds':       5,
                'summary_text': '…',
            },
            format='json',
        )
        return finish_res

    # ─────────────────────────────────────────────────────────────────────
    # シナリオ 1: win → EXP = enemy.reward_exp (DB 実効値)
    # ─────────────────────────────────────────────────────────────────────
    def test_1_win_exp_equals_reward_exp(self):
        """goblin.reward_exp=6 で win → exp_gained = 6 (DB 値そのまま)。"""
        res = self._start_and_finish(result='win')
        self.assertEqual(res.status_code, 200, res.content)

        self.assertEqual(res.data['exp_gained'], 6,
                         'バトル EXP = enemy.reward_exp (FEAT-495 bake-in 済)')
        # coins は変更なし
        self.assertEqual(res.data['coins_gained'], 10,
                         'coins は変更なし (経済主役)')

    # ─────────────────────────────────────────────────────────────────────
    # 【FEAT-537 (2026-08-29)】バトル勝利のレベルアップで配分 pt が 10 入る
    # ─────────────────────────────────────────────────────────────────────
    def test_win_on_level_up_boundary_grants_allocatable_points(self):
        """🔴 境界をまたぐ勝利で `allocatable_points` が 10 増える。

        ユーザー実機報告「レベルアップしたのにステータスポイントが 10 ポイント
        付与されなかった」の経路。旧実装は **リテラル 3** が直書きされており、
        習慣経路 (10) との差は「EXP の出どころ」ではなく
        **「閾値をまたいだ瞬間の経路」** で決まっていた。

        ⚠️ 「たまたま通る」を避けるため `current_exp = max_exp - 1` にして
        境界を直接踏む (Pre-mortem #7)。
        """
        battle = self.player.battle
        battle.current_exp = battle.max_exp - 1
        battle.allocatable_points = 0
        battle.save(update_fields=['current_exp', 'allocatable_points'])
        level_before = battle.level

        res = self._start_and_finish(result='win')
        self.assertEqual(res.status_code, 200, res.content)

        after = PlayerProfile.objects.get(pk=self.player.pk).battle
        self.assertEqual(after.level, level_before + 1, 'レベルが上がっていない')
        self.assertEqual(
            after.allocatable_points, GameBalance.ALLOCATABLE_POINTS_PER_LEVEL,
            '🔴 バトル勝利のレベルアップで 10pt 入っていない '
            '(旧実装はリテラル 3 だった)',
        )

    def test_lose_does_not_grant_allocatable_points(self):
        """🔴 敗北では pt が入らない (Pre-mortem #8)。

        `finish.py` の加算は `if result == 'win':` の中にあり、
        `save(update_fields=...)` も win / lose で分岐している。
        統一のついでに敗北経路へ漏れ出していないことを縛る。
        """
        battle = self.player.battle
        battle.current_exp = battle.max_exp - 1
        battle.allocatable_points = 0
        battle.save(update_fields=['current_exp', 'allocatable_points'])
        level_before = battle.level

        res = self._start_and_finish(result='lose')
        self.assertEqual(res.status_code, 200, res.content)

        after = PlayerProfile.objects.get(pk=self.player.pk).battle
        self.assertEqual(after.level, level_before, '敗北でレベルが上がっている')
        self.assertEqual(after.allocatable_points, 0, '敗北で pt が入っている')

    # ─────────────────────────────────────────────────────────────────────
    # シナリオ 2: lose → EXP 0 (変わらず)
    # ─────────────────────────────────────────────────────────────────────
    def test_2_lose_exp_is_zero(self):
        """lose → exp_gained=0, coins_gained=0 (変化なし)。"""
        res = self._start_and_finish(result='lose')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertEqual(res.data['exp_gained'], 0, 'lose は EXP 0 のまま')
        self.assertEqual(res.data['coins_gained'], 0, 'lose は coins 0 のまま')

    # ─────────────────────────────────────────────────────────────────────
    # シナリオ 3: reward_exp=1 でも exp_gained=1 (DB 値そのまま返却)
    # ─────────────────────────────────────────────────────────────────────
    def test_3_min_reward_exp_passes_through(self):
        """reward_exp=1 の敵で win → exp_gained=1 (DB 値そのまま、フロア処理なし)。

        FEAT-495 で `max(1, ...)` 削除、reward_exp が信頼できる前提。
        seed data で 0 を投入しない限り 0 にはならない。
        """
        Enemy.objects.update_or_create(
            key='tiny_slime',
            defaults={
                'name': '極小スライム', 'sprite_key': 'enemy_slime',
                'base_hp': 10, 'base_atk': 1, 'base_spd': 5,
                'level_scaling': 0.5, 'reward_coins': 1, 'reward_exp': 1,
                'tier': 'zako', 'unlock_level': 0,
            },
        )
        # charges を再設定 (前のテストで消費済みの可能性)
        self.player.refresh_from_db()
        self.player.battle_charges = 3
        self.player.save()

        start_res = self.client.post(
            reverse('battle-start'),
            data={'enemy_key': 'tiny_slime'},
            format='json',
        )
        self.assertEqual(start_res.status_code, 200, start_res.content)
        token = start_res.data['token']

        finish_res = self.client.post(
            reverse('battle-finish'),
            data={
                'token': token, 'result': 'win',
                'duration_sec': 10, 'damage_dealt': 10,
                'damage_taken': 1, 'rounds': 2, 'summary_text': '…',
            },
            format='json',
        )
        self.assertEqual(finish_res.status_code, 200, finish_res.content)
        self.assertEqual(finish_res.data['exp_gained'], 1,
                         'reward_exp=1 → exp_gained=1 (DB 値そのまま)')
