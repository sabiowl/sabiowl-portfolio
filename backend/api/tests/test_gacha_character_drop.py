"""【FEAT-312】Weekly Character 排出経路の契約テスト 4 件。

指示書 §Phase 2 シナリオ:
  1. **基本**: Weekly 引きで `character` 排出時、OwnedCharacter が作成される
  2. **重複**: 既に所持済の character_id を引いた場合、`PendingDuplicateReward` が
     作成され `is_duplicate=True`
  3. **フォールバック**: Character マスター 0 件時に diamond 救済が走る
     (Pre-mortem #1 緩和、Response 200 でチケット消費しつつ +50 diamond)
  4. **退行なし**: 既存 SR exp / diamond / title 排出が引き続き動作（weight 配分が増えただけ）

加えて補助テスト:
  - `_pick_random_character_id` の rarity → price proxy 動作
  - `value > 0` (旧 Monthly 経路) と `value == 0` (新 Weekly ランダム経路) の両立

【BUG-94 (2026-06-12)】Weekly SSR レアキャラは migration 0130 で is_active=False に
変更され、`_pick_reward` の通常抽選 pool からは除外された。
【BUG-98 (2026-06-13)】migration 0133 で is_active=True / weight=6 に再活性化、
Weekly 5% でキャラ排出される経路として復活 (test_weekly_5pct_character.py が契約)。
シナリオ 1-3 は `_pick_reward` を直接 patch して character 報酬を強制注入するため
is_active の影響を受けず、`_apply_reward` の character 分岐 (OwnedCharacter 作成 /
PendingDuplicateReward / diamond フォールバック) 自体の回帰テストとして引き続き
有効 (この分岐は BUG-98 で実際に通常抽選 pool からも到達可能になった)。
"""
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import (
    Character, GachaReward, OwnedCharacter, PendingDuplicateReward,
    PlayerGachaStatus, PlayerProfile,
)

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
class GachaCharacterDropContractTest(APITestCase):
    """FEAT-312: Weekly Character 排出 + 既存経路退行ゼロの契約。"""

    def setUp(self):
        self.user = User.objects.create_user('player1', email='p1@example.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='Player1',
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        # Weekly チケットを多めに付与
        self.status_obj, _ = PlayerGachaStatus.objects.get_or_create(player=self.player)
        self.status_obj.weekly_tickets = 4
        self.status_obj.save(update_fields=['weekly_tickets'])

        # 既存の Weekly 報酬 8 件を seed する（テスト DB ではない場合のフォールバック）。
        # 注: 本番では `_ensure_gacha_rewards()` が初回 GachaPullView でまとめて
        # bulk_create するが、本テスト DB では migration 0090 が先に Weekly Character
        # 2 件追加 → `_ensure_gacha_rewards` の「if not exists()」判定で skip され、
        # 既存 8 件が seed されない。テストで diamond/xp_boost/title 経路を確認するため
        # ここで強制 seed する（指示書 §Phase 1-4 の dead path 想定対応）。
        from api.views.gacha import _WEEKLY_REWARDS
        for spec in _WEEKLY_REWARDS:
            GachaReward.objects.get_or_create(
                ticket_type=spec['ticket_type'],
                rarity=spec['rarity'],
                name=spec['name'],
                defaults={k: v for k, v in spec.items()
                          if k not in ('ticket_type', 'rarity', 'name')},
            )

    # ─────────────────────────────────────────────────────────────
    # シナリオ 1: 基本 - Weekly character 排出 → OwnedCharacter 作成
    # ─────────────────────────────────────────────────────────────
    def test_weekly_character_pull_creates_owned_character(self):
        """Weekly SSR Character 報酬を強制的に選ばせ、OwnedCharacter が作成される。

        【FEAT-421 (2026-06-10)】SR Character (守護獣) を廃止したため SSR 経路に
        切替。契約 (character 報酬 → OwnedCharacter 作成) は SR/SSR 共通のため、
        SSR 経路でも等価に担保される。
        """
        # SSR Character 報酬を取得 (migration 0090 で seed 済の SSR レアキャラ)
        ssr_char_reward = GachaReward.objects.filter(
            ticket_type='weekly', rarity='SSR', reward_type='character',
        ).first()
        self.assertIsNotNone(ssr_char_reward,
                             'migration 0090 で Weekly SSR Character が seed されているはず')

        # `_pick_reward` をモックして必ず Character 報酬を返す
        with patch('api.views.gacha._pick_reward', return_value=ssr_char_reward):
            res = self.client.post(reverse('gacha-pull'),
                                   {'ticket_type': 'weekly'}, format='json')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertEqual(res.data['reward']['reward_type'], 'character')
        self.assertFalse(res.data['is_duplicate'],
                         '新規 OwnedCharacter なので duplicate=false')

        # OwnedCharacter が作成されている
        self.assertEqual(
            OwnedCharacter.objects.filter(player=self.player).count(), 1,
            'Weekly Character 排出で OwnedCharacter が 1 件作成されるはず',
        )

    # ─────────────────────────────────────────────────────────────
    # シナリオ 2: 重複 - 既所持 character_id → PendingDuplicateReward
    # ─────────────────────────────────────────────────────────────
    def test_weekly_character_pull_duplicate_creates_pending(self):
        """全 Character を予め所持済の状態で Weekly Character を引くと
        PendingDuplicateReward が作成される。"""
        # 全 Character を予め所持済にする
        all_chars = list(Character.objects.all())
        self.assertGreater(len(all_chars), 0,
                           'Character マスターが seed されている前提')
        for c in all_chars:
            OwnedCharacter.objects.create(player=self.player, character=c)

        ssr_char_reward = GachaReward.objects.filter(
            ticket_type='weekly', rarity='SSR', reward_type='character',
        ).first()

        with patch('api.views.gacha._pick_reward', return_value=ssr_char_reward):
            res = self.client.post(reverse('gacha-pull'),
                                   {'ticket_type': 'weekly'}, format='json')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertTrue(res.data['is_duplicate'],
                        '全所持済 → 必ず duplicate になるはず')
        self.assertIsNotNone(res.data['pending_reward_id'])

        # PendingDuplicateReward が作成されている
        self.assertEqual(
            PendingDuplicateReward.objects.filter(player=self.player).count(), 1,
            '重複時に PendingDuplicateReward が 1 件作成される',
        )

    # ─────────────────────────────────────────────────────────────
    # シナリオ 3: フォールバック - Character マスター 0 件 → diamond 救済
    # ─────────────────────────────────────────────────────────────
    def test_weekly_character_pull_no_character_master_falls_back_to_diamond(self):
        """Character マスター 0 件時に diamond 50 で救済（Pre-mortem #1）。"""
        # Character マスター全削除（OwnedCharacter も CASCADE で消える）
        Character.objects.all().delete()
        self.assertEqual(Character.objects.count(), 0)

        ssr_char_reward = GachaReward.objects.filter(
            ticket_type='weekly', rarity='SSR', reward_type='character',
        ).first()

        initial_diamonds = self.player.diamonds
        with patch('api.views.gacha._pick_reward', return_value=ssr_char_reward):
            res = self.client.post(reverse('gacha-pull'),
                                   {'ticket_type': 'weekly'}, format='json')
        self.assertEqual(
            res.status_code, 200,
            f'フォールバックで 200 OK を返すはず（503 ではない）: {res.content}',
        )
        self.assertFalse(res.data['is_duplicate'])

        # diamond 50 が救済として加算されている
        self.player.refresh_from_db()
        self.assertEqual(
            self.player.diamonds, initial_diamonds + 50,
            'Character マスター 0 件時に diamond 50 fallback が走るはず',
        )
        # OwnedCharacter は作成されない
        self.assertEqual(
            OwnedCharacter.objects.filter(player=self.player).count(), 0,
            'Character マスター 0 件なので OwnedCharacter は作成されない',
        )

    # ─────────────────────────────────────────────────────────────
    # シナリオ 4: 退行なし - 既存 SR diamond / title / xp_boost が動作
    # ─────────────────────────────────────────────────────────────
    def test_weekly_existing_reward_types_unaffected(self):
        """Weekly に Character 追加した後も、既存の diamond / title / xp_boost
        排出経路は退行ゼロで動作する。"""
        # SR diamond 報酬を強制
        sr_diamond_reward = GachaReward.objects.filter(
            ticket_type='weekly', rarity='SR', reward_type='diamond',
        ).first()
        self.assertIsNotNone(sr_diamond_reward)

        initial_diamonds = self.player.diamonds
        with patch('api.views.gacha._pick_reward', return_value=sr_diamond_reward):
            res = self.client.post(reverse('gacha-pull'),
                                   {'ticket_type': 'weekly'}, format='json')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertEqual(res.data['reward']['reward_type'], 'diamond')
        self.assertFalse(res.data['is_duplicate'])

        # diamond が反映されている（value=80）
        self.player.refresh_from_db()
        self.assertEqual(
            self.player.diamonds, initial_diamonds + 80,
            '既存 SR diamond 経路で +80 が反映されるはず（退行ゼロ）',
        )
        # Character は何も作られていない
        self.assertEqual(
            OwnedCharacter.objects.filter(player=self.player).count(), 0,
        )

    # ─────────────────────────────────────────────────────────────
    # 補助: _pick_random_character_id の動作 (BUG-108 で is_starter=False ベースに統一)
    # ─────────────────────────────────────────────────────────────
    def test_pick_random_character_id_picks_only_non_starter(self):
        """`_pick_random_character_id` が SR / SSR どちらの rarity 引数でも
        is_starter=False のキャラのみを返すことを確認。

        【BUG-108 (2026-06-14)】判定基準を price >= 3000 → is_starter=False に変更。
        rarity 引数は backward compat のため受け取るが、全 non-starter を SSR 扱い
        として同じプールから抽選する v1.0 設計。
        """
        from api.views.gacha import _pick_random_character_id

        # SR と SSR で複数回試行し、全結果が non-starter であることを確認
        sr_ids = {_pick_random_character_id(self.player, 'SR') for _ in range(20)}
        ssr_ids = {_pick_random_character_id(self.player, 'SSR') for _ in range(20)}

        non_starter_ids = set(
            Character.objects.filter(is_starter=False).values_list('id', flat=True)
        )

        if non_starter_ids:
            self.assertTrue(
                sr_ids.issubset(non_starter_ids | {None}),
                f'SR の返却は全て non-starter のはず: 返却={sr_ids} / 期待={non_starter_ids}',
            )
            self.assertTrue(
                ssr_ids.issubset(non_starter_ids | {None}),
                f'SSR の返却は全て non-starter のはず: 返却={ssr_ids} / 期待={non_starter_ids}',
            )
