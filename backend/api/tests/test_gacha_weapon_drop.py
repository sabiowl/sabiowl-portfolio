"""【FEAT-326 Phase 3】 ガチャ weapon 排出の契約テスト 3 件。

カバー:
    1. Daily SR weapon 排出時 PlayerWeapon が作成 + GachaHistory 記録
    2. 既所持 weapon ガチャ排出時のダイヤ救済 (PendingDuplicateReward 経路、Pre-mortem #5)
    3. weight 合計の不変式 (Daily 100 / Weekly 200 / Monthly 100、Pre-mortem #3)
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import (
    GachaHistory, GachaReward, PendingDuplicateReward,
    PlayerGachaStatus, PlayerProfile, PlayerWeapon, WeaponMaster,
)
from api.views.gacha import _ensure_gacha_rewards

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
class GachaWeaponDropContractTest(APITestCase):
    """FEAT-326 ガチャ武器排出の契約 3 件。"""

    def setUp(self):
        cache.clear()
        # ランタイム seed を確実に走らせる (Daily/Monthly は migration で seed されない)
        _ensure_gacha_rewards()

        self.user = User.objects.create_user('gacha_tester', email='gt@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='GachaTester')
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        # チケット付与 + pity を pull 用に準備
        self.gacha_status = PlayerGachaStatus.objects.create(
            player=self.player,
            daily_tickets=10,
            weekly_tickets=10,
            monthly_tickets=10,
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: Daily SR weapon 排出 (force 直指定) で PlayerWeapon + 履歴
    # ─────────────────────────────────────────────────────────────────

    def test_daily_sr_weapon_drop_creates_player_weapon(self):
        """Daily SR weapon (mythril_sword) を強制排出 (テスト経由で reward を直接呼出)
        → PlayerWeapon 作成 + GachaHistory 記録される。

        ランタイム確率が weight 4/100 = 4% で flaky になるため、本テストは
        実装の `GachaPullView._apply_reward` 直接呼出ではなく、
        `_pick_reward` が weight=0 化された他候補を含む pool から weapon を
        必ず引くシナリオを構成 (他全 weight を 0 にする)。
        """
        # mythril_sword の GachaReward を確実に存在させる (migration 0095 で投入済)
        mythril_reward = GachaReward.objects.filter(
            ticket_type='daily', reward_type='weapon', weapon_key='mythril_sword',
        ).first()
        self.assertIsNotNone(mythril_reward, 'migration 0095 で mythril_sword が seed 済のはず')

        # 他の Daily reward を一時的に weight=0 で無効化 (mythril 確実排出)
        GachaReward.objects.filter(ticket_type='daily').exclude(
            pk=mythril_reward.pk,
        ).update(weight=0)

        res = self.client.post(
            reverse('gacha-pull'),
            data={'ticket_type': 'daily'},
            format='json',
        )
        self.assertEqual(res.status_code, 200, res.content)
        self.assertEqual(res.data['reward']['reward_type'], 'weapon')
        # 重複ではないため pending_reward_id は null
        self.assertFalse(res.data['is_duplicate'])

        # PlayerWeapon が作成され、is_equipped=False
        mythril_master = WeaponMaster.objects.get(key='mythril_sword')
        pw = PlayerWeapon.objects.filter(
            player=self.player, weapon=mythril_master,
        ).first()
        self.assertIsNotNone(pw, '排出後に PlayerWeapon が作成されているはず')
        self.assertFalse(pw.is_equipped, 'ガチャ排出時は未装備 (装備変更は EquipWeaponView)')

        # GachaHistory も記録されている
        hist = GachaHistory.objects.filter(player=self.player).first()
        self.assertIsNotNone(hist)
        self.assertEqual(hist.reward.weapon_key, 'mythril_sword')

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: 既所持 weapon でダイヤ救済 (PendingDuplicateReward)
    # ─────────────────────────────────────────────────────────────────

    def test_duplicate_weapon_drop_creates_pending_reward(self):
        """既に dragon_slayer を所持している状態で Weekly SSR weapon を排出 →
        is_duplicate=True + PendingDuplicateReward 作成 (Pre-mortem #5)。"""
        dragon_master = WeaponMaster.objects.get(key='dragon_slayer')
        # 事前準備: 既に dragon_slayer を所持
        PlayerWeapon.objects.create(
            player=self.player, weapon=dragon_master, is_equipped=False,
        )

        # dragon_slayer (Weekly SSR weapon) を確実に排出させる
        dragon_reward = GachaReward.objects.filter(
            ticket_type='weekly', reward_type='weapon', weapon_key='dragon_slayer',
        ).first()
        self.assertIsNotNone(dragon_reward)
        GachaReward.objects.filter(ticket_type='weekly').exclude(
            pk=dragon_reward.pk,
        ).update(weight=0)

        res = self.client.post(
            reverse('gacha-pull'),
            data={'ticket_type': 'weekly'},
            format='json',
        )
        self.assertEqual(res.status_code, 200, res.content)
        self.assertEqual(res.data['reward']['reward_type'], 'weapon')
        self.assertTrue(res.data['is_duplicate'], '既所持で is_duplicate=True が立つはず')
        self.assertIsNotNone(res.data['pending_reward_id'])

        # PendingDuplicateReward が作成されている
        pending = PendingDuplicateReward.objects.filter(player=self.player).first()
        self.assertIsNotNone(pending)
        self.assertEqual(pending.status, 'pending')
        # PlayerWeapon は重複作成されていない (1 件のまま)
        count = PlayerWeapon.objects.filter(
            player=self.player, weapon=dragon_master,
        ).count()
        self.assertEqual(count, 1)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: weight 合計の不変式 (Pre-mortem #3)
    # ─────────────────────────────────────────────────────────────────

    def test_weight_totals_remain_invariant(self):
        """Daily 100 / Weekly 200 / Monthly 100 を契約として縛る。

        FEAT-326 で weapon 追加 + 既存 weight 再分配 (Daily SR exp 5→1、
        Weekly SSR diamond 10→6) を実施しており、合計値の不変条件を保証する。
        【BUG-97 (2026-06-12)】Monthly はキャラ専用ガチャに再設計。旧 SR/SSR
        非キャラ報酬 (合計 100) を is_active=False、新規「マンスリーキャラ
        (SSR)」(weight=100) のみが active → Monthly 合計は 115 → 100 に変更。
        【BUG-98 (2026-06-13)】Weekly に 5% キャラ排出を復活 (SSR diamond
        10→8、character weight=6 再活性化) → Weekly 合計は 116 → 120 に変更
        (6/120 = 厳密 5.00%)。
        将来 weight を変更する際は本テストを更新して意図変更を明示する責務。"""

        daily_total = sum(
            r.weight for r in GachaReward.objects.filter(ticket_type='daily', is_active=True)
        )
        weekly_total = sum(
            r.weight for r in GachaReward.objects.filter(ticket_type='weekly', is_active=True)
        )
        monthly_total = sum(
            r.weight for r in GachaReward.objects.filter(ticket_type='monthly', is_active=True)
        )

        self.assertEqual(
            daily_total, 100,
            f'Daily weight 合計が 100 から逸脱: {daily_total} '
            '(FEAT-326 で weapon +4、SR exp 350 を 5→1 で相殺の契約に違反)',
        )
        self.assertEqual(
            weekly_total, 200,
            f'Weekly weight 合計が 200 から逸脱: {weekly_total} '
            '(BUG-131 で SSR character 5%→0.5%、weight 合計 120→200 に変更)',
        )
        # 【BUG-97 (2026-06-12)】Monthly キャラ専用化で旧 SR/SSR 非キャラ報酬を
        # is_active=False、「マンスリーキャラ (SSR)」(weight=100) のみ active。
        self.assertEqual(
            monthly_total, 100,
            f'Monthly weight 合計が 100 から逸脱: {monthly_total} '
            '(BUG-97 で Monthly = キャラ専用 weight=100 単独 entry)',
        )
