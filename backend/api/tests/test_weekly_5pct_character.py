"""【BUG-131 (2026-06-17)】Weekly ガチャ 0.5% キャラ排出の契約テスト。

【経緯】
旧 BUG-98 (5.0% character drop) の契約テストを更新。BUG-131 で Weekly SSR
character 5.00% → 0.50% に削減 + 合計 weight 120 → 200 にスケールアップ。
R/SR tier 比率は維持、character から解放された 4.5% は SSR 非キャラ枠が吸収。

ファイル名は git 履歴保持のため `test_weekly_5pct_character.py` のまま (内容は
0.5% 契約に書き換え)。
"""
from django.test import TestCase
from django.contrib.auth.models import User
from rest_framework.test import APIClient
from rest_framework.authtoken.models import Token

from api.models import GachaReward, PlayerGachaStatus, PlayerProfile


class WeeklySSRCharacterDropRateTest(TestCase):
    """【BUG-131】Weekly SSR character 0.5% 排出契約。"""

    def setUp(self):
        self.user = User.objects.create_user(username='t', password='p')
        self.player = PlayerProfile.objects.create(user=self.user, name='T')
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client = APIClient()
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    # S1: Weekly SSR レアキャラ entry が is_active=True、weight=1 (旧 6)
    def test_S1_weekly_ssr_character_weight_is_1(self):
        from api.views.gacha import _ensure_gacha_rewards
        _ensure_gacha_rewards()
        entry = GachaReward.objects.filter(
            ticket_type='weekly', rarity='SSR',
            reward_type='character', name='レアキャラ (SSR)',
        ).first()
        self.assertIsNotNone(entry)
        self.assertTrue(entry.is_active)
        self.assertEqual(entry.weight, 1)

    # S2: SSR diamond weight 再配分 (旧 8 → 新 18、SSR コンソリエーション吸収)
    def test_S2_ssr_diamond_weight_is_18(self):
        from api.views.gacha import _ensure_gacha_rewards
        _ensure_gacha_rewards()
        entry = GachaReward.objects.filter(
            ticket_type='weekly', rarity='SSR',
            reward_type='diamond', name='ダイヤ', detail='× 200',
        ).first()
        self.assertIsNotNone(entry)
        self.assertEqual(entry.weight, 18)

    # S3: Weekly 合計 weight = 200、character weight = 1 (= 厳密 0.50% の根拠)
    def test_S3_weekly_total_weight_is_200(self):
        from api.views.gacha import _ensure_gacha_rewards
        _ensure_gacha_rewards()
        active = GachaReward.objects.filter(ticket_type='weekly', is_active=True)
        total = sum(r.weight for r in active)
        self.assertEqual(total, 200, f'Weekly 合計 weight が 200 でない: {total}')
        char_total = sum(r.weight for r in active if r.reward_type == 'character')
        self.assertEqual(char_total, 1, f'character weight が 1 でない: {char_total}')

    # S4: R/SR/SSR tier 比率が維持されている (Option B の特徴)
    def test_S4_tier_ratios_preserved(self):
        from api.views.gacha import _ensure_gacha_rewards
        _ensure_gacha_rewards()
        active = GachaReward.objects.filter(ticket_type='weekly', is_active=True)
        tiers = {'R': 0, 'SR': 0, 'SSR': 0}
        for r in active:
            tiers[r.rarity] += r.weight
        self.assertEqual(tiers['R'], 83, f'R tier weight 想定 83、実際 {tiers["R"]}')
        self.assertEqual(tiers['SR'], 78, f'SR tier weight 想定 78、実際 {tiers["SR"]}')
        self.assertEqual(tiers['SSR'], 39, f'SSR tier weight 想定 39、実際 {tiers["SSR"]}')

    # S5: 0.5% (= 1/200) でキャラ排出 (10000 回引いて 50 ± 30 回程度)
    def test_S5_weekly_character_drop_rate_is_0_5pct(self):
        """10000 回引いてキャラ排出回数が 50 ± 30 回 (= 約 0.5%) であることを確認。"""
        from api.views.gacha import _pick_reward
        char_count = 0
        for _ in range(10000):
            r = _pick_reward('weekly')
            if r.reward_type == 'character':
                char_count += 1
        # 厳密 0.5% = 50 回 / 10000 回、SD ≈ sqrt(10000 × 0.005 × 0.995) ≈ 7.05
        # 3σ で 50 ± 21、99.7% 信頼区間。マージン込みで [20, 80] を許容範囲とする。
        self.assertGreater(char_count, 20,
            f'character が 20 回未満しか出ていない (実測 {char_count}/10000、'
            '想定 50 ± 21)。weight 配分を確認')
        self.assertLess(char_count, 80,
            f'character が 80 回以上出ている (実測 {char_count}/10000、'
            '想定 50 ± 21)。weight 配分を確認')
