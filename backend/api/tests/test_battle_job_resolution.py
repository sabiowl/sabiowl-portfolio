"""【FEAT-393 P2-1 + FEAT-430】BattleStartView の Job 解決契約テスト。

FEAT-393 P2-1 (2026-05-30):
  arch_review 20260530 §P2-1 で指摘された軽微 N+1 (最大 2 回 Job.objects.get()) を
  Job.objects.in_bulk() で 1 query 化したことの再発防止。

FEAT-430 (2026-06-12):
  「キャラ = ジョブ」固定化 v1.0。ジョブ解決は active_character.job のみを真実値とし、
  player.active_job (旧 FEAT-304 PartyEditDialog 上書き) は一切参照しない。
  active_job に値が設定されていても (v1.1+ 移行前データ等)、battle 側は無視して
  active_character.job → warrior フォールバックの 2 段で解決する。

テスト方針:
  CaptureQueriesContext で BattleStartView 実行中の SQL を補足し、
  Job テーブルへの query が厳密に 1 件 (in_bulk の SELECT 1 回) であることを縛る。
"""
from django.core.cache import cache
from django.db import connection
from django.test import override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Character, Enemy, Job, PlayerProfile
from django.contrib.auth import get_user_model

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
class BattleJobResolutionQueryCountTest(APITestCase):
    """BattleStartView の Job 解決 query 数を縛る契約テスト。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('battle_job_tester', email='bjt@example.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='JobQueryTest', battle_charges=3,
            battle_charges_date=timezone.localdate(),
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # 戦闘テスト用 enemy (冪等)
        Enemy.objects.update_or_create(
            key='goblin',
            defaults={
                'name': 'ゴブリン', 'sprite_key': 'enemy_goblin',
                'base_hp': 60, 'base_atk': 8, 'base_spd': 10,
                'level_scaling': 1.0, 'reward_coins': 10, 'reward_exp': 20,
                'tier': 'zako',
            },
        )

    # ─────────────────────────────────────────────────────────────────
    # メインシナリオ: active_character.job (beatrix=knight) のみで解決
    # → in_bulk() の 1 query のみ
    # ─────────────────────────────────────────────────────────────────
    def test_job_resolution_single_query_with_character_job(self):
        """active_character.job=beatrix(knight) のとき、
        Job 関連 query は in_bulk() の 1 件のみ。

        arch_review 20260530 §P2-1 で指摘された軽微 N+1 の再発防止。
        FEAT-393 P2-1 で in_bulk() 化したことで Job テーブルアクセスが
        1 query に抑制されることを縛る。
        """
        beatrix = Character.objects.get(key='beatrix')
        self.player.active_character = beatrix
        self.player.save(update_fields=['active_character'])

        # BUG-104 後 14 ジョブ存在確認 (in_bulk の前提)
        # FEAT-428 (13 ジョブ) → BUG-104 で black_mage 追加 → 計 14
        self.assertEqual(Job.objects.count(), 14,
                         'BUG-104 後 14 ジョブが存在するはず (in_bulk の前提)')

        # BattleStartView を実行し SQL を補足
        with CaptureQueriesContext(connection) as ctx:
            res = self.client.post(reverse('battle-start'))

        self.assertEqual(res.status_code, 200, res.content)

        # Job テーブルへの SELECT が 1 件のみ (in_bulk = 1 query)
        job_queries = [
            q for q in ctx.captured_queries
            if 'api_job' in q['sql'].lower()
        ]
        self.assertEqual(
            len(job_queries), 1,
            f'Job 関連 query は in_bulk() の 1 件のみのはず (got {len(job_queries)}):\n'
            + '\n'.join(f'  {q["sql"]}' for q in job_queries),
        )

    # ─────────────────────────────────────────────────────────────────
    # 補助シナリオ: active_job が設定済みでも 1 query (かつ無視される)
    # ─────────────────────────────────────────────────────────────────
    def test_job_resolution_single_query_when_active_job_set(self):
        """player.active_job が設定済みでも、Job query は in_bulk() の 1 件のみ。

        【FEAT-430】active_job は battle 解決から完全に外れたため、
        値が入っていても追加 query は発生しない。
        """
        beatrix = Character.objects.get(key='beatrix')
        warrior_job = Job.objects.get(job_id='warrior')
        self.player.active_character = beatrix
        self.player.active_job = warrior_job
        self.player.save(update_fields=['active_character', 'active_job'])

        with CaptureQueriesContext(connection) as ctx:
            res = self.client.post(reverse('battle-start'))

        self.assertEqual(res.status_code, 200, res.content)

        job_queries = [
            q for q in ctx.captured_queries
            if 'api_job' in q['sql'].lower()
        ]
        self.assertEqual(
            len(job_queries), 1,
            f'active_job 設定済みでも Job query は 1 件のみのはず (got {len(job_queries)})',
        )


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class BattleJobResolutionFixationTest(APITestCase):
    """【FEAT-430】「キャラ = ジョブ」固定化: active_character.job が唯一の真実値である契約。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('battle_fix_tester', email='bft@example.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='FixationTest', battle_charges=3,
            battle_charges_date=timezone.localdate(),
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        Enemy.objects.update_or_create(
            key='goblin',
            defaults={
                'name': 'ゴブリン', 'sprite_key': 'enemy_goblin',
                'base_hp': 60, 'base_atk': 8, 'base_spd': 10,
                'level_scaling': 1.0, 'reward_coins': 10, 'reward_exp': 20,
                'tier': 'zako',
            },
        )

    def test_active_character_job_always_wins_over_active_job(self):
        """player.active_job が設定されていても、active_character.job で解決される。

        sol (warrior) を active_character に + healer を active_job に設定した状態で
        battle-start を叩くと、player_job は active_character (sol) の job=warrior に
        なるはず (active_job=healer は無視される)。
        """
        sol = Character.objects.get(key='sol')  # warrior job (migration 0112)
        healer_job = Job.objects.get(job_id='healer')

        self.player.active_character = sol
        self.player.active_job = healer_job  # v1.1+ で再活性化される field、v1.0 は無視される
        self.player.save(update_fields=['active_character', 'active_job'])

        res = self.client.post(reverse('battle-start'))
        self.assertEqual(res.status_code, 200, res.content)
        pj = res.data['player_job']
        self.assertEqual(pj['job_id'], 'warrior',
                         'active_character (sol) の job (warrior) が採用されるはず')

    def test_no_active_character_falls_back_to_warrior(self):
        """active_character が未設定 (None) のとき、warrior フォールバックになる。"""
        self.assertIsNone(self.player.active_character)

        res = self.client.post(reverse('battle-start'))
        self.assertEqual(res.status_code, 200, res.content)
        pj = res.data['player_job']
        self.assertEqual(pj['job_id'], 'warrior',
                         'active_character 未設定時は warrior フォールバックのはず')
