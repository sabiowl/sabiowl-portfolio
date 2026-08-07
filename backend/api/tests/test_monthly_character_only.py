"""【BUG-97 (2026-06-12)】Monthly ガチャ キャラ専用化の契約テスト。"""
from django.test import TestCase
from django.contrib.auth.models import User
from rest_framework.test import APIClient
from rest_framework.authtoken.models import Token

from api.models import Character, GachaReward, OwnedCharacter, PlayerGachaStatus, PlayerProfile


class MonthlyCharacterOnlyTest(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(username='t', password='p')
        self.player = PlayerProfile.objects.create(user=self.user, name='T')
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client = APIClient()
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # Monthly チケット 5 枚で連続テスト可能に
        gacha_status, _ = PlayerGachaStatus.objects.get_or_create(player=self.player)
        gacha_status.monthly_tickets = 5
        gacha_status.save()

    # S1: Monthly 引き = キャラ排出 (非キャラ報酬出ない)
    def test_S1_monthly_pull_always_returns_character(self):
        for _ in range(5):
            res = self.client.post('/api/gacha/pull/', {'ticket_type': 'monthly'})
            self.assertEqual(res.status_code, 200, res.content)
            self.assertEqual(res.data['reward']['reward_type'], 'character',
                             f"非キャラ報酬が排出された: {res.data['reward']}")

    # S2: Monthly active な reward は character のみ
    def test_S2_monthly_active_pool_is_character_only(self):
        from api.views.gacha import _ensure_gacha_rewards
        _ensure_gacha_rewards()
        active = GachaReward.objects.filter(
            ticket_type='monthly', is_active=True,
        )
        self.assertEqual(active.count(), 1, f'active entry が 1 件でない: {list(active)}')
        entry = active.first()
        self.assertEqual(entry.reward_type, 'character')
        self.assertEqual(entry.name, 'マンスリーキャラ (SSR)')
        self.assertEqual(entry.weight, 100)

    # S3: 未所持 SSR キャラから優先排出
    def test_S3_monthly_pull_prefers_unowned_ssr(self):
        # noir 所持済、kyle 未所持の状態
        noir = Character.objects.get(key='noir')
        OwnedCharacter.objects.create(player=self.player, character=noir)
        # 1 回引く → 未所持 SSR (kyle/fia/irene/luna/aurum のいずれか) が出ることを期待
        res = self.client.post('/api/gacha/pull/', {'ticket_type': 'monthly'})
        self.assertEqual(res.data['reward']['reward_type'], 'character')
        self.assertFalse(res.data['is_duplicate'])

    # S4: 天井経路廃止 (monthly_pity 経路なし)
    def test_S4_no_monthly_pity_path(self):
        # 10 回連続引いてもキャラ交換券 +1 されない
        gacha_status, _ = PlayerGachaStatus.objects.get_or_create(player=self.player)
        gacha_status.monthly_tickets = 10
        gacha_status.save()
        for _ in range(10):
            res = self.client.post('/api/gacha/pull/', {'ticket_type': 'monthly'})
            self.assertEqual(res.data.get('character_exchange_ticket_awarded'),
                             None,
                             f'天井で交換券が配布された: {res.data}')
        self.player.refresh_from_db()
        # character_exchange_tickets は初期値 0 のまま (新規入手経路なし)
        self.assertEqual(self.player.character_exchange_tickets, 0)

    # S5: Monthly 非キャラ報酬は pool から除外
    def test_S5_monthly_pool_excludes_non_character(self):
        from api.views.gacha import _pick_reward
        for _ in range(50):
            r = _pick_reward('monthly')
            self.assertEqual(r.reward_type, 'character',
                             f'非キャラが排出された: {r.name} ({r.reward_type})')
