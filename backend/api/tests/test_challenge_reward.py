"""【FEAT-466 (2026-06-24)】月次カテゴリチャレンジ報酬 lazy 配布 (3 段階累積開放) の契約テスト。

FEAT-465 (Ver1.0) の単一目標方式テスト (R1-R4) を撤回し、3 段階
Bronze/Silver/Gold 累積開放方式に対応した R5-R12 に置換する
(指示書 §6-1)。`challenge_reward_service.grant_pending_rewards` を中心に、
tier 別冪等性 + 累積配布 + PostHog tier プロパティを縛る。
"""
from datetime import timedelta
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone

from api.models import Challenge, ChallengeParticipation, PlayerProfile
from api.services.challenge_reward_service import grant_pending_rewards

User = get_user_model()


class GrantPendingRewardsTieredTest(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(username='t', password='p')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='T', level=1, current_exp=0, max_exp=100,
        )
        # 終了済 (実行時の `timezone.localdate()` より確実に前になるよう相対日付で定義)
        today = timezone.localdate()
        self.tiered_challenge = Challenge.objects.create(
            title='6 月運動チャレンジ', description='desc', category='運動',
            is_tiered=True,
            target_count_bronze=100, target_count_silver=250, target_count_gold=500,
            reward_exp_bronze=100, reward_exp_silver=300, reward_exp_gold=1000,
            start_date=today - timedelta(days=35), end_date=today - timedelta(days=5),
        )
        self.flat_challenge = Challenge.objects.create(
            title='6 月学習チャレンジ (非累積)', description='desc', category='学習',
            is_tiered=False,
            target_count_gold=300, reward_exp_gold=1000,
            start_date=today - timedelta(days=35), end_date=today - timedelta(days=5),
        )
        self.contribution_date = today - timedelta(days=10)

    # R5: 累積 tier + 1 回貢献 + 全 tier 達成 → 全 3 tier 配布 + 合計 1400 XP
    @patch('api.services.challenge_reward_service.capture_for_player')
    def test_R5_all_tiers_achieved_grants_all_three(self, mock_capture):
        self.tiered_challenge.current_count = 600  # gold(500) 超過
        self.tiered_challenge.save(update_fields=['current_count'])
        participation = ChallengeParticipation.objects.create(
            player=self.player, challenge=self.tiered_challenge,
            contribution_count=23, last_contribution_date=self.contribution_date,
        )

        results = grant_pending_rewards(self.player)

        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['granted_tiers'], ['bronze', 'silver', 'gold'])
        self.assertEqual(results[0]['total_reward_exp'], 1400)
        self.assertTrue(results[0]['achieved_any'])

        participation.refresh_from_db()
        self.assertTrue(participation.bronze_granted)
        self.assertTrue(participation.silver_granted)
        self.assertTrue(participation.gold_granted)
        self.assertIsNotNone(participation.bronze_granted_at)
        self.assertIsNotNone(participation.silver_granted_at)
        self.assertIsNotNone(participation.gold_granted_at)

        self.player.refresh_from_db()
        # Lv1 (max_exp=100) → +1400 EXP の累積レベルアップを確認 (詳細な式は
        # R9 単純ケースで別途確認、ここでは EXP が反映されレベルが進んだことのみ縛る)
        self.assertGreater(self.player.level, 1)

        # PostHog: tier ごとに 3 イベント (bronze/silver/gold) が送信される
        tiers_sent = [call.args[2]['tier'] for call in mock_capture.call_args_list
                      if call.args[1] == 'challenge_reward_granted']
        self.assertEqual(tiers_sent, ['bronze', 'silver', 'gold'])

    # R6: 累積 tier + 1 回貢献 + Silver まで達成 → Bronze + Silver 配布 + 合計 400 XP
    def test_R6_silver_achieved_grants_bronze_and_silver(self):
        self.tiered_challenge.current_count = 260  # silver(250) 以上、gold(500) 未満
        self.tiered_challenge.save(update_fields=['current_count'])
        participation = ChallengeParticipation.objects.create(
            player=self.player, challenge=self.tiered_challenge,
            contribution_count=10, last_contribution_date=self.contribution_date,
        )

        results = grant_pending_rewards(self.player)

        self.assertEqual(results[0]['granted_tiers'], ['bronze', 'silver'])
        self.assertEqual(results[0]['total_reward_exp'], 400)
        self.assertTrue(results[0]['achieved_any'])

        participation.refresh_from_db()
        self.assertTrue(participation.bronze_granted)
        self.assertTrue(participation.silver_granted)
        self.assertTrue(participation.gold_granted)  # 終了済で全 flag True 化
        self.assertIsNotNone(participation.bronze_granted_at)
        self.assertIsNotNone(participation.silver_granted_at)
        self.assertIsNone(participation.gold_granted_at)  # 未達 tier は null 維持

    # R7: 累積 tier + 1 回貢献 + Bronze のみ達成 → Bronze 配布 + 100 XP
    def test_R7_bronze_only_achieved(self):
        self.tiered_challenge.current_count = 120  # bronze(100) 以上、silver(250) 未満
        self.tiered_challenge.save(update_fields=['current_count'])
        participation = ChallengeParticipation.objects.create(
            player=self.player, challenge=self.tiered_challenge,
            contribution_count=5, last_contribution_date=self.contribution_date,
        )

        results = grant_pending_rewards(self.player)

        self.assertEqual(results[0]['granted_tiers'], ['bronze'])
        self.assertEqual(results[0]['total_reward_exp'], 100)

        participation.refresh_from_db()
        self.assertTrue(participation.bronze_granted)
        self.assertTrue(participation.silver_granted)
        self.assertTrue(participation.gold_granted)
        self.assertIsNotNone(participation.bronze_granted_at)
        self.assertIsNone(participation.silver_granted_at)
        self.assertIsNone(participation.gold_granted_at)

    # R8: 累積 tier + 1 回貢献 + 全 tier 未達 → 配布なし + 全 flag True 化
    def test_R8_no_tier_achieved_marks_all_granted_without_exp(self):
        self.tiered_challenge.current_count = 30  # bronze(100) 未満
        self.tiered_challenge.save(update_fields=['current_count'])
        participation = ChallengeParticipation.objects.create(
            player=self.player, challenge=self.tiered_challenge,
            contribution_count=3, last_contribution_date=self.contribution_date,
        )

        results = grant_pending_rewards(self.player)

        self.assertEqual(results[0]['granted_tiers'], [])
        self.assertEqual(results[0]['total_reward_exp'], 0)
        self.assertFalse(results[0]['achieved_any'])

        participation.refresh_from_db()
        self.assertTrue(participation.bronze_granted)
        self.assertTrue(participation.silver_granted)
        self.assertTrue(participation.gold_granted)
        self.assertIsNone(participation.bronze_granted_at)
        self.assertIsNone(participation.silver_granted_at)
        self.assertIsNone(participation.gold_granted_at)

        self.player.refresh_from_db()
        self.assertEqual(self.player.current_exp, 0)
        self.assertEqual(self.player.level, 1)

    # R9: 非累積 (is_tiered=False) + 1 回貢献 + gold 達成 → gold 1000 XP のみ配布
    def test_R9_non_tiered_gold_achieved(self):
        self.flat_challenge.current_count = 300
        self.flat_challenge.save(update_fields=['current_count'])
        participation = ChallengeParticipation.objects.create(
            player=self.player, challenge=self.flat_challenge,
            contribution_count=8, last_contribution_date=self.contribution_date,
        )

        results = grant_pending_rewards(self.player)

        self.assertEqual(results[0]['granted_tiers'], ['gold'])
        self.assertEqual(results[0]['total_reward_exp'], 1000)

        participation.refresh_from_db()
        # 非累積経路は bronze/silver を一切触らない (False 維持)
        self.assertFalse(participation.bronze_granted)
        self.assertFalse(participation.silver_granted)
        self.assertTrue(participation.gold_granted)
        self.assertIsNotNone(participation.gold_granted_at)

        self.player.refresh_from_db()
        # Lv1 (max_exp=100) → +1000 EXP: Lv1→2 (-100, max170) → Lv2→3 (-170,
        # max240) → Lv3→4 (-240, max310) → Lv4→5 (-310, max380) → 180 < 380
        # で停止。GameBalance.level_to_max_exp(level)=level*70+30 準拠。
        self.assertEqual(self.player.level, 5)
        self.assertEqual(self.player.current_exp, 180)

    # R10: 非累積 + 1 回貢献 + gold 未達 → 配布なし + gold_granted=True
    def test_R10_non_tiered_gold_not_achieved(self):
        self.flat_challenge.current_count = 50
        self.flat_challenge.save(update_fields=['current_count'])
        participation = ChallengeParticipation.objects.create(
            player=self.player, challenge=self.flat_challenge,
            contribution_count=2, last_contribution_date=self.contribution_date,
        )

        results = grant_pending_rewards(self.player)

        self.assertEqual(results[0]['granted_tiers'], [])
        self.assertFalse(results[0]['achieved_any'])

        participation.refresh_from_db()
        self.assertTrue(participation.gold_granted)
        self.assertIsNone(participation.gold_granted_at)

        self.player.refresh_from_db()
        self.assertEqual(self.player.current_exp, 0)

    # R11: 累積 tier + 2 回連続呼出 → 2 回目は no-op (冪等性)
    def test_R11_idempotent_on_second_call(self):
        self.tiered_challenge.current_count = 600
        self.tiered_challenge.save(update_fields=['current_count'])
        ChallengeParticipation.objects.create(
            player=self.player, challenge=self.tiered_challenge,
            contribution_count=23, last_contribution_date=self.contribution_date,
        )

        first = grant_pending_rewards(self.player)
        second = grant_pending_rewards(self.player)

        self.assertEqual(len(first), 1)
        self.assertEqual(second, [])

        self.player.refresh_from_db()
        first_level = self.player.level
        first_exp = self.player.current_exp

        # 3 回目を呼んでも変化しないことで「2 回目以降は恒久的に no-op」を確認
        third = grant_pending_rewards(self.player)
        self.assertEqual(third, [])
        self.player.refresh_from_db()
        self.assertEqual(self.player.level, first_level)
        self.assertEqual(self.player.current_exp, first_exp)

    # R12: 累積 tier + 0 回貢献 → 配布されず全 flag False 維持 (再判定対象)
    def test_R12_zero_contribution_not_processed(self):
        self.tiered_challenge.current_count = 600
        self.tiered_challenge.save(update_fields=['current_count'])
        participation = ChallengeParticipation.objects.create(
            player=self.player, challenge=self.tiered_challenge,
            contribution_count=0, last_contribution_date=None,
        )

        results = grant_pending_rewards(self.player)

        self.assertEqual(results, [])
        participation.refresh_from_db()
        self.assertFalse(participation.bronze_granted)
        self.assertFalse(participation.silver_granted)
        self.assertFalse(participation.gold_granted)

        self.player.refresh_from_db()
        self.assertEqual(self.player.current_exp, 0)
        self.assertEqual(self.player.level, 1)
