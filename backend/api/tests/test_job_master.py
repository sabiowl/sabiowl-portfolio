"""【FEAT-391 (2026-05-30)】ジョブシステム 8 ジョブ拡張の Backend 契約テスト。

FEAT-299 (5 ジョブ) → FEAT-391 (8 ジョブ) → FEAT-428 (13 ジョブ) 全面更新。

カバー:
  1. 13 ジョブ存在 + 1:1 キャラマッピング確認
  2. 各キャラに 1:1 でジョブが割り振られている (重複なし)
  3. 闇魔導士の高火力低 ATB バランス確認 (design contract)
  4. モンクの高速連撃型確認 (design contract)
  5. berserker 廃止確認
  6. BattleStartView レスポンスに player_job が含まれる (beatrix=knight)
  7. active_character なし時の warrior フォールバック (既存挙動互換)
"""
import datetime

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.db.models import Count
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Character, Enemy, Job, PlayerProfile

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
class JobMasterContractTest(APITestCase):
    """FEAT-391: 8 ジョブ拡張 + キャラ 1:1 化の契約テスト。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('player1', email='p1@example.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='Player1', battle_charges=3,
            battle_charges_date=datetime.date.today(),
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

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: 13 ジョブ存在 + ID セット確認
    # ─────────────────────────────────────────────────────────────────
    def test_13_jobs_seeded_with_correct_ids(self):
        """migration 0112 (FEAT-391, 8 ジョブ) + 0128 (FEAT-428, +5 ジョブ)
        + 0138 (BUG-104, +1 ジョブ black_mage) で 14 ジョブが正しい ID で seed されている。"""
        expected_ids = {
            'warrior', 'assassin', 'blue_mage', 'healer',
            'knight', 'archer', 'monk', 'dark_mage',
            'magic_swordsman', 'bard', 'necromancer', 'gunner', 'alchemist',
            'black_mage',     # 【BUG-104 (2026-06-14)】新ジョブ追加 (migration 0138)
        }
        actual_ids = set(Job.objects.values_list('job_id', flat=True))
        self.assertEqual(
            actual_ids, expected_ids,
            f'14 ジョブ全て seed されているはず\n期待: {sorted(expected_ids)}\n実値: {sorted(actual_ids)}',
        )
        self.assertEqual(
            Job.objects.count(), 14,
            f'Job テーブルに 14 件のみのはず (実値: {Job.objects.count()} 件)',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: キャラ→ジョブ 1:1 マッピング確認
    # ─────────────────────────────────────────────────────────────────
    def test_1to1_character_job_mapping(self):
        """各キャラに 1:1 でジョブが割り振られている (重複なし、Pre-mortem #2 解消)。"""
        expected_map = {
            'sol':     'warrior',
            'aria':    'assassin',
            'cyan':    'blue_mage',     # 【BUG-103 (2026-06-14)】旧 'rune' → 'cyan' rename (migration 0137)
            'rune':    'black_mage',    # 【BUG-104 (2026-06-14)】新キャラ「ルーン (黒魔導士)」追加 (migration 0138)
            'lucia':   'healer',
            'beatrix': 'knight',
            'faye':    'archer',
            'zenon':   'monk',
            'noir':    'dark_mage',
            # 【FEAT-428】新規 5 キャラ
            'kyle':    'magic_swordsman',
            'fia':     'bard',
            'irene':   'necromancer',
            'luna':    'gunner',
            'aurum':   'alchemist',
        }
        chars = {c.key: c for c in Character.objects.filter(
            key__in=expected_map.keys(),
        ).select_related('job')}

        self.assertEqual(
            len(chars), len(expected_map),
            f'8 キャラ全て存在するはず\n見つかった key: {sorted(chars.keys())}',
        )
        for char_key, expected_job_id in expected_map.items():
            ch = chars[char_key]
            self.assertIsNotNone(
                ch.job,
                f'Character "{char_key}" に job が割り振られていない',
            )
            self.assertEqual(
                ch.job.job_id, expected_job_id,
                f'Character "{char_key}" の job 不一致: '
                f'期待={expected_job_id} 実値={ch.job.job_id}',
            )

        # 重複チェック: 各ジョブは 1 キャラにのみ割り振られている
        job_counts = (
            Character.objects.filter(job__isnull=False, key__in=expected_map.keys())
            .values('job__job_id').annotate(count=Count('id'))
        )
        for jc in job_counts:
            self.assertEqual(
                jc['count'], 1,
                f'Job "{jc["job__job_id"]}" は {jc["count"]} キャラに割り振られている (1 を期待)',
            )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: 闇魔導士のバランス契約 (高火力 + 必殺即発動)
    # ─────────────────────────────────────────────────────────────────
    def test_dark_mage_high_attack_low_atb(self):
        """闇魔導士: 一撃高火力 + 必殺即発動の設計確認 (バランス契約テスト)。

        attack_power_modifier=1.5 (8 ジョブ中最高) + ult_cost=1 (最少) + burn の組み合わせ。
        """
        dm = Job.objects.get(job_id='dark_mage')
        self.assertAlmostEqual(dm.attack_power_modifier, 1.5, places=2,
                               msg='闇魔導士の attack_power_modifier は 1.5 (最高)')
        self.assertEqual(dm.ult_cost, 1,
                         msg='闇魔導士の ult_cost は 1 (最少 = 即発動)')
        self.assertEqual(dm.on_hit_effect, 'burn',
                         msg='闇魔導士は burn 追加効果')
        self.assertAlmostEqual(dm.atb_speed_modifier, 0.8, places=2,
                               msg='闇魔導士の ATB は遅め (0.8)')

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 4: モンクのバランス契約 (高速 + 連撃)
    # ─────────────────────────────────────────────────────────────────
    def test_monk_fastest_high_ult_cost(self):
        """モンク: 高速連撃型の設計確認 (バランス契約テスト)。

        atb_speed_modifier=1.3 (assassin と並んで上位) + ult_cost=4 (最多)。
        """
        monk = Job.objects.get(job_id='monk')
        self.assertAlmostEqual(monk.atb_speed_modifier, 1.3, places=2,
                               msg='モンクの atb_speed_modifier は 1.3 (高速)')
        self.assertEqual(monk.ult_cost, 4,
                         msg='モンクの ult_cost は 4 (最多 = 連撃型)')

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 5: berserker 廃止確認
    # ─────────────────────────────────────────────────────────────────
    def test_no_berserker_after_migration(self):
        """berserker は migration 0112 (FEAT-391) 後に存在しない (warrior に統合)。"""
        self.assertFalse(
            Job.objects.filter(job_id='berserker').exists(),
            'berserker は廃止済み、warrior に統合されているはず',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 6: BattleStartView レスポンスに player_job が含まれる
    # ─────────────────────────────────────────────────────────────────
    def test_battle_start_response_includes_player_job(self):
        """active_character が beatrix (knight) の場合、
        レスポンスの player_job に正しい modifier 値が含まれる。

        【FEAT-391 更新】beatrix は warrior (旧 FEAT-299) → knight (FEAT-391 1:1 化) に変更。
        """
        # beatrix を active_character に設定
        beatrix = Character.objects.get(key='beatrix')
        self.player.active_character = beatrix
        self.player.save(update_fields=['active_character'])

        res = self.client.post(reverse('battle-start'))
        self.assertEqual(res.status_code, 200, res.content)

        self.assertIn('player_job', res.data,
                      'BattleStartView レスポンスに player_job がないと '
                      'Flutter Combatant が modifier を受け取れない')
        pj = res.data['player_job']
        # 【FEAT-391】beatrix は knight (ナイト) に 1:1 マッピング
        self.assertEqual(pj['job_id'], 'knight')
        self.assertEqual(pj['job_name'], 'ナイト')
        self.assertAlmostEqual(pj['atb_speed_modifier'],    0.7, places=2,
                               msg='ナイトの ATB は 0.7 (重装で遅い)')
        self.assertAlmostEqual(pj['attack_power_modifier'], 1.1, places=2,
                               msg='ナイトの攻撃力は 1.1 (中位)')
        self.assertEqual(pj['on_hit_effect'], 'none')
        self.assertEqual(pj['ult_cost'], 2)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 7: active_character なし時の warrior フォールバック (既存挙動互換)
    # ─────────────────────────────────────────────────────────────────
    def test_battle_start_response_falls_back_to_warrior_when_no_active_character(self):
        """active_character が未設定 / job=null の場合、warrior フォールバックが効く。

        _serialize_job(None) は modifier=1.0 + ult_cost=3 を返す（既存挙動互換、
        Backend 計算式変更なしのため FEAT-391 でも不変）。
        """
        # active_character なし
        self.player.active_character = None
        self.player.save(update_fields=['active_character'])

        res = self.client.post(reverse('battle-start'))
        self.assertEqual(res.status_code, 200, res.content)
        pj = res.data['player_job']
        # フォールバック = _serialize_job(None) の仕様 (modifier=1.0、warrior job_id)
        # 注: actual warrior の値 (atb=0.9, atk=1.3) ではなく null フォールバック (1.0)。
        self.assertEqual(pj['job_id'], 'warrior')
        self.assertAlmostEqual(pj['atb_speed_modifier'],    1.0, places=2,
                               msg='null フォールバックは既存挙動互換 (1.0) を返すはず')
        self.assertAlmostEqual(pj['attack_power_modifier'], 1.0, places=2)
        self.assertEqual(pj['on_hit_effect'], 'none')
        self.assertEqual(pj['ult_cost'], 3)
