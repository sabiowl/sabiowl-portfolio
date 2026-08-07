"""【FEAT-428 (2026-06-12)】5 ジョブ + 5 キャラ追加 (migration 0128) の契約テスト。

カバー:
  1. migration 0128 後、新規 5 ジョブ (job_id) が存在する
  2. 新規 5 キャラが正しい job 紐付けで存在する (1:1)
  3. 新規 SSR キャラ (is_starter=False、BUG-108 で price>=3000 から変更) が
     _pick_random_character_id の候補プールに含まれる
  4. 既存 8 ジョブのパラメータが変化していない (副作用なし)
  5. PlayerProfile.active_job に新規ジョブを設定 → BattleStartView が正しい
     player_job を返す (統合テスト)
"""
from django.contrib.auth import get_user_model
from django.test import override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Character, Enemy, Job, PlayerProfile
from api.views.gacha import _pick_random_character_id

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

# 既存 8 ジョブの期待値 (migration 0112 FEAT-391 の seed 値、FEAT-428 で変化しないはず)
_EXISTING_8_JOBS = {
    'warrior':   dict(atb_speed_modifier=0.9, attack_power_modifier=1.3, on_hit_effect='none', ult_cost=2),
    'blue_mage': dict(atb_speed_modifier=1.0, attack_power_modifier=1.1, on_hit_effect='burn', ult_cost=2),
    'assassin':  dict(atb_speed_modifier=1.4, attack_power_modifier=1.0, on_hit_effect='none', ult_cost=3),
    'healer':    dict(atb_speed_modifier=1.0, attack_power_modifier=0.6, on_hit_effect='heal', ult_cost=3),
    'knight':    dict(atb_speed_modifier=0.7, attack_power_modifier=1.1, on_hit_effect='none', ult_cost=2),
    'archer':    dict(atb_speed_modifier=1.2, attack_power_modifier=1.0, on_hit_effect='none', ult_cost=3),
    'monk':      dict(atb_speed_modifier=1.3, attack_power_modifier=0.9, on_hit_effect='none', ult_cost=4),
    'dark_mage': dict(atb_speed_modifier=0.8, attack_power_modifier=1.5, on_hit_effect='burn', ult_cost=1),
}

# 新規 5 ジョブ → キャラの 1:1 マッピング (migration 0128)
_NEW_JOB_CHARACTER_MAP = {
    'magic_swordsman': 'kyle',
    'bard':            'fia',
    'necromancer':     'irene',
    'gunner':          'luna',
    'alchemist':       'aurum',
}


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class Feat428FiveJobFiveCharacterTest(APITestCase):
    """FEAT-428: 5 ジョブ + 5 キャラ追加 (migration 0128) の契約テスト。"""

    def setUp(self):
        self.user = User.objects.create_user('feat428_player', email='feat428@example.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='Player428', battle_charges=3,
            battle_charges_date=timezone.localdate(),
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # 戦闘テスト用 enemy seed（migration 0082 で投入済だが冪等にしておく）
        Enemy.objects.update_or_create(
            key='goblin',
            defaults={
                'name': 'ゴブリン', 'sprite_key': 'enemy_goblin',
                'base_hp': 60, 'base_atk': 8, 'base_spd': 10,
                'level_scaling': 1.0, 'reward_coins': 10, 'reward_exp': 20,
                'tier': 'zako',
            },
        )
        # migration 0161: 新規 SSR キャラは is_published=False、ガチャプールに含まれるよう True に設定
        Character.objects.filter(key__in=_NEW_JOB_CHARACTER_MAP.values()).update(is_published=True)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: 新規 5 ジョブ存在確認
    # ─────────────────────────────────────────────────────────────────
    def test_5_new_jobs_exist(self):
        """migration 0128 (FEAT-428) で新規 5 ジョブが seed されている。"""
        expected_ids = set(_NEW_JOB_CHARACTER_MAP.keys())
        actual_ids = set(
            Job.objects.filter(job_id__in=expected_ids).values_list('job_id', flat=True)
        )
        self.assertEqual(
            actual_ids, expected_ids,
            f'新規 5 ジョブ全て seed されているはず\n期待: {sorted(expected_ids)}\n実値: {sorted(actual_ids)}',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: 新規 5 キャラ存在 + job 1:1 紐付け確認
    # ─────────────────────────────────────────────────────────────────
    def test_5_new_characters_with_job_linkage(self):
        """新規 5 キャラ (kyle/fia/irene/luna/aurum) が対応するジョブに 1:1 紐付け。"""
        for job_id, char_key in _NEW_JOB_CHARACTER_MAP.items():
            ch = Character.objects.filter(key=char_key).select_related('job').first()
            self.assertIsNotNone(ch, f'Character "{char_key}" が存在しない')
            self.assertIsNotNone(ch.job, f'Character "{char_key}" に job が割り振られていない')
            self.assertEqual(
                ch.job.job_id, job_id,
                f'Character "{char_key}" の job 不一致: 期待={job_id} 実値={ch.job.job_id}',
            )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: 新規 SSR キャラが _pick_random_character_id の候補プールに含まれる
    # ─────────────────────────────────────────────────────────────────
    def test_new_ssr_characters_in_gacha_pool(self):
        """新規 5 キャラ (is_starter=False、SSR 扱い) が SSR ガチャの候補プールに含まれる。

        `_pick_random_character_id` を多数回呼び出し、新規キャラの id が
        少なくとも 1 度は選出されることを確認する (候補プールに含まれている証明)。

        【BUG-108 (2026-06-14)】判定基準を price >= 3000 → is_starter=False に変更
        (BUG-107 で全 non-starter 価格を 1500 に統一したため)。
        """
        new_char_ids = set(
            Character.objects.filter(key__in=_NEW_JOB_CHARACTER_MAP.values())
            .values_list('id', flat=True)
        )
        self.assertEqual(len(new_char_ids), 5, '新規 5 キャラが Character マスターに存在するはず')

        # 新規キャラは is_starter=False (SSR 扱い) であることを確認 (BUG-108)
        for is_starter in Character.objects.filter(id__in=new_char_ids).values_list('is_starter', flat=True):
            self.assertFalse(is_starter, '新規キャラは non-starter (SSR 扱い) のはず')

        picked_ids = set()
        for _ in range(100):
            picked = _pick_random_character_id(self.player, 'SSR')
            self.assertIsNotNone(picked, 'SSR 候補が 0 件になってはいけない')
            picked_ids.add(picked)

        self.assertTrue(
            new_char_ids & picked_ids,
            f'新規 SSR キャラが 100 回の抽選で 1 度も選ばれなかった\n'
            f'新規キャラ id: {new_char_ids}\n抽選結果 id 集合: {picked_ids}',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 4: 既存 8 ジョブのパラメータが不変
    # ─────────────────────────────────────────────────────────────────
    def test_existing_8_jobs_unchanged(self):
        """既存 8 ジョブ (migration 0112 seed) のパラメータが FEAT-428 で変化していない。"""
        for job_id, expected in _EXISTING_8_JOBS.items():
            job = Job.objects.get(job_id=job_id)
            self.assertAlmostEqual(
                job.atb_speed_modifier, expected['atb_speed_modifier'], places=2,
                msg=f'{job_id}.atb_speed_modifier が変化している',
            )
            self.assertAlmostEqual(
                job.attack_power_modifier, expected['attack_power_modifier'], places=2,
                msg=f'{job_id}.attack_power_modifier が変化している',
            )
            self.assertEqual(
                job.on_hit_effect, expected['on_hit_effect'],
                f'{job_id}.on_hit_effect が変化している',
            )
            self.assertEqual(
                job.ult_cost, expected['ult_cost'],
                f'{job_id}.ult_cost が変化している',
            )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 5: active_character (新規キャラ) の job が BattleStartView に反映される
    # 【FEAT-430 (2026-06-12)】「キャラ = ジョブ」固定化に伴い、active_job 経路は廃止。
    # active_character.job のみが反映されることを確認する (active_job は無視)。
    # ─────────────────────────────────────────────────────────────────
    def test_battle_start_reflects_new_active_character_job(self):
        """active_character に新規キャラ (luna=gunner) を設定すると、
        BattleStartView レスポンスの player_job に反映される。

        active_job (旧経路) も設定するが、v1.0 では無視されることを確認する。
        """
        luna = Character.objects.get(key='luna')  # job=gunner (migration 0128)
        healer = Job.objects.get(job_id='healer')
        self.player.active_character = luna
        self.player.active_job = healer  # v1.0 では無視される
        # 【FEAT-406】battle_charges_date が null だと reset_battle_charges_if_new_day
        # で battle_charges=0 に巻き戻されるため、本日付 (JST) を明示する。
        # reset 側は timezone.localdate() (JST) で比較するため、timezone.now().date()
        # (UTC) ではなく localdate() を使うこと。
        self.player.battle_charges_date = timezone.localdate()
        self.player.save(update_fields=['active_character', 'active_job', 'battle_charges_date'])

        res = self.client.post(reverse('battle-start'))
        self.assertEqual(res.status_code, 200, res.content)

        pj = res.data['player_job']
        self.assertEqual(pj['job_id'], 'gunner')
        self.assertEqual(pj['job_name'], 'ガンナー')
        self.assertAlmostEqual(pj['atb_speed_modifier'], 1.3, places=2)
        self.assertAlmostEqual(pj['attack_power_modifier'], 1.1, places=2)
        self.assertEqual(pj['on_hit_effect'], 'none')
        self.assertEqual(pj['ult_cost'], 2)
