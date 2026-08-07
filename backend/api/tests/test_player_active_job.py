"""【FEAT-430 (2026-06-12)】「キャラ = ジョブ」固定化 v1.0 契約テスト。

v1.0 では active_character.job がジョブ解決の唯一の真実値となり、
PlayerProfile.active_job の PATCH 経路 (ActiveJobUpdateView) は無効化 (410 Gone)。
active_job field 自体は v1.1+ 熟練度システム (doc/design/job_mastery_v1_1.md) での
再活用に向けて維持する。

シナリオ:
  - シナリオ A: active_character.job (lucia=healer) が BattleStartView で採用される
  - シナリオ S1: PATCH /player/active-job/ は 410 Gone + feature_deactivated を返し、
                 active_job は変化しない (default のまま)
  - シナリオ S2: active_job に値が設定済みでも (旧データ等)、PATCH は同様に 410 Gone
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Character, Enemy, Job, PlayerProfile
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
class PlayerActiveJobContractTest(APITestCase):
    """FEAT-430: 「キャラ = ジョブ」固定化 + ActiveJobUpdateView 410 Gone の契約。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('player1', email='p1@example.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='Player1', battle_charges=3,
            battle_charges_date=timezone.localdate(),
        )
        # active_character に lucia を設定 (migration 0112 FEAT-391 で healer job 割り振り済)
        self.player.active_character = Character.objects.get(key='lucia')
        self.player.save(update_fields=['active_character'])
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # 戦闘テスト用 enemy（migration 0082 で seed 済）
        Enemy.objects.update_or_create(
            key='goblin',
            defaults={
                'name': 'ゴブリン', 'sprite_key': 'enemy_goblin',
                'base_hp': 60, 'base_atk': 8, 'base_spd': 10,
                'level_scaling': 1.0, 'reward_coins': 10, 'reward_exp': 20,
                'tier': 'zako',
            },
        )

    # ─────────────────────────────────────────────────────────────
    # シナリオ A: active_character.job (lucia=healer) が
    #              BattleStartView で採用される (唯一の真実値)
    # ─────────────────────────────────────────────────────────────
    def test_active_character_job_is_used_for_battle(self):
        """active_job は null のまま、BattleStartView は active_character.job (healer) を採用するはず。

        【FEAT-391 更新】lucia は cleric (旧 FEAT-299) → healer (FEAT-391 1:1 化) に変更。
        【FEAT-430】v1.0 では active_job を一切参照しない (唯一の真実値 = active_character.job)。
        """
        self.assertIsNone(self.player.active_job,
                          '新規 player の active_job は null のはず')

        res = self.client.post(reverse('battle-start'))
        self.assertEqual(res.status_code, 200, res.content)
        pj = res.data['player_job']
        self.assertEqual(pj['job_id'], 'healer',
                         'active_character (lucia) の job (healer) が採用される')
        # healer の modifier 値 (migration 0112 FEAT-391 確定値)
        self.assertAlmostEqual(pj['attack_power_modifier'], 0.6, places=2)
        self.assertEqual(pj['on_hit_effect'], 'heal')

    # ─────────────────────────────────────────────────────────────
    # シナリオ S1: PATCH /player/active-job/ は 410 Gone + feature_deactivated
    # ─────────────────────────────────────────────────────────────
    def test_patch_active_job_returns_410_gone(self):
        """PATCH /api/player/active-job/ は v1.0 で deactivate (410 Gone)。

        【FEAT-430】ジョブはキャラと共に決まる設計に変更したため、
        active_job の手動切替エンドポイントは無効化された (URL 自体は維持)。
        """
        res = self.client.patch(
            reverse('player-active-job'),
            data={'job_id': 'warrior'},
            format='json',
        )
        self.assertEqual(res.status_code, 410, res.content)
        # 【FEAT-475 Phase 3c (2026-07-04)】新形式 {'error': {'code', 'message'}}
        self.assertEqual(error_code(res), 'player_active_job_feature_deactivated')
        # サビ口調 + 🪶 マーカー (新形式では error.message にあり)
        self.assertIn('🪶', error_message(res))

        # PlayerProfile.active_job は変化しない (default の null のまま)
        self.player.refresh_from_db()
        self.assertIsNone(self.player.active_job)

    # ─────────────────────────────────────────────────────────────
    # シナリオ S2: active_job に値が設定済みでも PATCH は 410 Gone
    #              (旧データ / v1.1+ 移行前データに対する安全性確認)
    # ─────────────────────────────────────────────────────────────
    def test_patch_active_job_returns_410_gone_even_if_already_set(self):
        """active_job が既に設定されている場合でも PATCH は 410 Gone を返し、
        既存の active_job 値は変更されない。"""
        warrior = Job.objects.get(job_id='warrior')
        self.player.active_job = warrior
        self.player.save(update_fields=['active_job'])

        res = self.client.patch(
            reverse('player-active-job'),
            data={'job_id': None},
            format='json',
        )
        self.assertEqual(res.status_code, 410, res.content)
        # 【FEAT-475 Phase 3c (2026-07-04)】新形式 {'error': {'code', 'message'}}
        self.assertEqual(error_code(res), 'player_active_job_feature_deactivated')

        self.player.refresh_from_db()
        self.assertEqual(self.player.active_job_id, warrior.id,
                         '410 Gone のため既存 active_job は変更されないはず')
