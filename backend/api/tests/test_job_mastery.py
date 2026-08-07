"""【FEAT-511 Phase A (v1.1、2026-07-30)】ジョブ熟練度契約テスト 5 件。

BattleFinishView が PlayerJobMastery を正しく作成・更新することを縛る。
"""
import uuid

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.constants import (
    JOB_MASTERY_EXP_PER_BATTLE_WIN,
    JOB_MASTERY_MAX_LEVEL,
    JOB_MASTERY_TIER_MULTIPLIER,
    calc_job_mastery_exp_to_next,
)
from api.models import Battle, Character, Enemy, Job, PlayerJobMastery, PlayerProfile, WeaponMaster

User = get_user_model()

_OVERRIDE = {
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


@override_settings(REST_FRAMEWORK=_OVERRIDE)
class JobMasteryContractTest(APITestCase):
    """FEAT-511 Phase A: ジョブ熟練度の契約 5 件。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('mastery_tester', email='mastery@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='MasteryTest')

        # charges を出陣可能な状態に初期化
        battle_state = self.player.battle
        battle_state.battle_charges = 9
        battle_state.save(update_fields=['battle_charges'])

        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # enemy: zako
        self.goblin, _ = Enemy.objects.update_or_create(
            key='goblin',
            defaults={
                'name': 'ゴブリン', 'sprite_key': 'enemy_goblin',
                'base_hp': 60, 'base_atk': 8, 'base_spd': 10,
                'level_scaling': 1.0, 'reward_coins': 10, 'reward_exp': 6,
                'tier': 'zako',
            },
        )
        # enemy: boss (tier 倍率テスト用)
        self.boss_enemy, _ = Enemy.objects.update_or_create(
            key='test_boss',
            defaults={
                'name': 'テストボス', 'sprite_key': 'enemy_test_boss',
                'base_hp': 500, 'base_atk': 30, 'base_spd': 8,
                'level_scaling': 1.0, 'reward_coins': 50, 'reward_exp': 20,
                'tier': 'boss',
            },
        )

        # sol キャラ (warrior job) を active_character に設定
        self.sol = Character.objects.get(key='sol')
        self.warrior_job = self.sol.job
        self.player.active_character = self.sol
        self.player.save(update_fields=['active_character'])

        WeaponMaster.objects.update_or_create(
            key='starter_sword',
            defaults={'name': '見習いの剣', 'atk_bonus': 10},
        )

    def _make_battle(self, enemy=None):
        """Battle レコードを直接作成して返す。"""
        e = enemy or self.goblin
        battle = Battle.objects.create(
            player=self.player,
            enemy=e,
            token=uuid.uuid4().hex,
            enemy_hp_init=e.base_hp,
            enemy_atk_init=e.base_atk,
            started_at=timezone.now(),
            potions_planned=0,
        )
        return battle

    def _finish(self, token, result='win', enemy=None):
        e = enemy or self.goblin
        return self.client.post(
            reverse('battle-finish'),
            data={
                'token': token,
                'result': result,
                'duration_sec': 30,
                'damage_dealt': e.base_hp,
                'damage_taken': 10,
                'rounds': 5,
                'summary_text': '',
            },
            format='json',
        )

    # ──────────────────────────────────────────────────────────────
    # テスト 1: 初回勝利で PlayerJobMastery が作成される
    # ──────────────────────────────────────────────────────────────
    def test_first_battle_creates_mastery(self):
        """初回勝利 (zako) で PlayerJobMastery が 1 件作成、EXP = 5。"""
        battle = self._make_battle()
        res = self._finish(battle.token)

        self.assertEqual(res.status_code, 200, res.data)

        # レコード作成確認
        mastery = PlayerJobMastery.objects.get(player=self.player, job=self.warrior_job)
        self.assertEqual(mastery.level, 1)
        self.assertEqual(mastery.exp, JOB_MASTERY_EXP_PER_BATTLE_WIN)  # 5

        # レスポンスに job_mastery フィールドあり
        jm = res.data['job_mastery']
        self.assertIsNotNone(jm)
        self.assertEqual(jm['job_id'], self.warrior_job.job_id)  # string key e.g. 'warrior'
        self.assertEqual(jm['exp_gained'], JOB_MASTERY_EXP_PER_BATTLE_WIN)
        self.assertEqual(jm['level'], 1)
        self.assertFalse(jm['is_maxed'])

    # ──────────────────────────────────────────────────────────────
    # テスト 2: 1 戦で複数 Lv 同時上昇
    # ──────────────────────────────────────────────────────────────
    def test_multiple_level_ups_in_single_battle(self):
        """level=1、exp=25 の状態で zako 勝利 (5EXP) → level=3 (2 段 up) になること。

        計算:
          勝利後 total = 25 + 5 = 30
          Lv 1→2 閾値 = calc(1) = 10:  30 >= 10 → level=2, exp=20
          Lv 2→3 閾値 = calc(2) = 20:  20 >= 20 → level=3, exp=0
          Lv 3→4 閾値 = calc(3) = 34:  0 < 34  → 停止
        """
        # 事前に mastery を Lv 1 / exp=25 に設定
        mastery = PlayerJobMastery.objects.create(
            player=self.player, job=self.warrior_job, level=1, exp=25,
        )
        battle = self._make_battle()
        res = self._finish(battle.token)

        self.assertEqual(res.status_code, 200, res.data)
        mastery.refresh_from_db()
        self.assertEqual(mastery.level, 3)
        self.assertEqual(mastery.exp, 0)

        jm = res.data['job_mastery']
        self.assertTrue(jm['leveled_up_now'])
        self.assertFalse(jm['maxed_now'])

    # ──────────────────────────────────────────────────────────────
    # テスト 3: Max 到達時に is_maxed=True + first_maxed_at 記録
    # ──────────────────────────────────────────────────────────────
    def test_max_level_grants_is_maxed(self):
        """level=9、exp がちょうど Lv 10 到達分の EXP で勝利 → is_maxed=True。

        calc(9) = 9*9*2 + 9*4 + 4 = 202
        勝利前 exp が 202-5=197 → 勝利後 202 >= 202 → Max 到達
        """
        threshold = calc_job_mastery_exp_to_next(9)  # 202
        mastery = PlayerJobMastery.objects.create(
            player=self.player, job=self.warrior_job,
            level=9, exp=threshold - JOB_MASTERY_EXP_PER_BATTLE_WIN,
        )
        battle = self._make_battle()
        res = self._finish(battle.token)

        self.assertEqual(res.status_code, 200, res.data)
        mastery.refresh_from_db()
        self.assertEqual(mastery.level, JOB_MASTERY_MAX_LEVEL)
        self.assertTrue(mastery.is_maxed)
        self.assertIsNotNone(mastery.first_maxed_at)
        self.assertEqual(mastery.exp, 0)  # Max 到達時は EXP キャップ

        jm = res.data['job_mastery']
        self.assertTrue(jm['maxed_now'])
        self.assertEqual(jm['exp_to_next'], 0)

    # ──────────────────────────────────────────────────────────────
    # テスト 4: tier 倍率が正しく適用される (boss: ×2.5)
    # ──────────────────────────────────────────────────────────────
    def test_tier_multiplier_applied(self):
        """boss tier の勝利で exp_gained = int(5 × 2.5) = 12。

        Lv 5 (閾値=74) の状態から勝利 → 12 EXP 加算 < 74 → level-up なし → exp=12 のまま。
        """
        expected_exp = int(JOB_MASTERY_EXP_PER_BATTLE_WIN * JOB_MASTERY_TIER_MULTIPLIER['boss'])
        self.assertEqual(expected_exp, 12)  # int(5 × 2.5) = 12

        # Lv 5: calc_job_mastery_exp_to_next(5) = 25*2+20+4 = 74。
        # 12 < 74 のため level-up は発生しない。
        PlayerJobMastery.objects.create(
            player=self.player, job=self.warrior_job, level=5, exp=0,
        )

        battle = self._make_battle(enemy=self.boss_enemy)
        res = self._finish(battle.token, enemy=self.boss_enemy)

        self.assertEqual(res.status_code, 200, res.data)

        # response の exp_gained が 12
        jm = res.data['job_mastery']
        self.assertEqual(jm['exp_gained'], expected_exp)
        self.assertFalse(jm['leveled_up_now'])  # Lv 5 で 12 EXP は閾値未満

        # DB の mastery.exp も 12
        mastery = PlayerJobMastery.objects.get(player=self.player, job=self.warrior_job)
        self.assertEqual(mastery.exp, expected_exp)
        self.assertEqual(mastery.level, 5)  # level-up なし

    # ──────────────────────────────────────────────────────────────
    # テスト 5: active_character.job=None → 500 にならず job_mastery=null 返却
    # ──────────────────────────────────────────────────────────────
    def test_no_active_character_job_no_error(self):
        """active_character=None のプレイヤーで battle finish が 500 にならず、
        job_mastery=null を返すこと。
        """
        self.player.active_character = None
        self.player.save(update_fields=['active_character'])

        battle = self._make_battle()
        res = self._finish(battle.token)

        self.assertEqual(res.status_code, 200, res.data)
        self.assertIsNone(res.data['job_mastery'])
        self.assertEqual(PlayerJobMastery.objects.filter(player=self.player).count(), 0)
