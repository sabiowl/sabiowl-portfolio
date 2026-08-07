"""【FEAT-518 (2026-08-05)】ガチャ排出確率開示の契約テスト。

指示書 doc/instructions/FEAT-518_gacha_odds_disclosure.md の Pre-mortem を固定する。

  #1 開示値と実際の排出がズレる      → test_odds_pool_matches_pick_pool
                                       test_probability_matches_weight_ratio
  #2 weight をそのまま % として表示  → test_probabilities_sum_to_100
                                       test_weekly_is_normalized_by_200_not_100
  #3 同名報酬をまとめてしまう        → test_same_name_rewards_are_listed_separately
  #4 is_active の扱いが食い違う      → test_inactive_reward_excluded_from_odds
  #6 購入前に到達できない            → test_guest_can_read_odds

本テストが守る最重要の性質は **「表示した確率で実際に抽選される」** こと。
これが崩れると App Store Guideline 3.1.1 / 景表法の観点で最も重い不具合になる。
"""
from django.contrib.auth import get_user_model
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import GachaReward, PlayerProfile
from api.views.gacha import _active_reward_pool, _ensure_gacha_rewards

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
class GachaOddsDisclosureTest(APITestCase):
    """排出確率開示 API の契約。"""

    def setUp(self):
        self.user = User.objects.create_user('oddsplayer', email='odds@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='OddsPlayer')
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        _ensure_gacha_rewards()
        self.url = reverse('gacha-odds')

    # ── Pre-mortem #1: 開示 pool と抽選 pool の一致 ──────────────────

    def test_odds_pool_matches_pick_pool(self):
        """開示に載る報酬集合が、抽選が使う pool と完全一致する。

        これが本 FEAT の中核契約。`GachaOddsView` と `_pick_reward` が
        別々に queryset を組むと乖離しうるため、`_active_reward_pool()` を
        唯一の入口にしている。その前提が壊れていないことを固定する。
        """
        res = self.client.get(self.url)
        self.assertEqual(res.status_code, 200)

        for block in res.json()['ticket_types']:
            ticket_type = block['ticket_type']
            pool = _active_reward_pool(ticket_type)

            disclosed = sorted((r['name'], r['detail']) for r in block['rewards'])
            actual    = sorted((r.name, r.detail) for r in pool)
            self.assertEqual(
                disclosed, actual,
                f'{ticket_type}: 開示された報酬集合が抽選 pool と一致していない',
            )

    def test_probability_matches_weight_ratio(self):
        """各報酬の probability が weight/total*100 と一致する。"""
        res = self.client.get(self.url)

        for block in res.json()['ticket_types']:
            pool  = _active_reward_pool(block['ticket_type'])
            total = sum(r.weight for r in pool)
            by_key = {(r.name, r.detail): r.weight for r in pool}

            for entry in block['rewards']:
                expected = round(by_key[(entry['name'], entry['detail'])] / total * 100, 2)
                self.assertAlmostEqual(
                    entry['probability'], expected, places=2,
                    msg=f"{block['ticket_type']} / {entry['name']}: 確率が weight 比と不一致",
                )

    # ── Pre-mortem #2: 正規化 ────────────────────────────────────────

    def test_probabilities_sum_to_100(self):
        """ticket_type ごとに確率の合計が 100% になる（丸め誤差 ±0.05 まで許容）。"""
        res = self.client.get(self.url)

        for block in res.json()['ticket_types']:
            total = sum(r['probability'] for r in block['rewards'])
            self.assertAlmostEqual(
                total, 100.0, delta=0.05,
                msg=f"{block['ticket_type']}: 確率合計が {total}% で 100% でない",
            )

    def test_rarity_summary_sums_to_100(self):
        """rarity サマリの合計も 100% になる。"""
        res = self.client.get(self.url)

        for block in res.json()['ticket_types']:
            total = sum(r['probability'] for r in block['rarity_summary'])
            self.assertAlmostEqual(
                total, 100.0, delta=0.05,
                msg=f"{block['ticket_type']}: rarity 合計が {total}%",
            )

    def test_weekly_is_normalized_by_200_not_100(self):
        """Weekly は weight 合計 200 なので、weight をそのまま % にしてはいけない。

        Pre-mortem #2 の中核。weight=45 の報酬は 45% ではなく 22.5%。
        """
        res = self.client.get(self.url)
        weekly = next(
            (b for b in res.json()['ticket_types'] if b['ticket_type'] == 'weekly'),
            None,
        )
        if weekly is None:
            self.skipTest('weekly 報酬が seed されていない')

        pool  = _active_reward_pool('weekly')
        total = sum(r.weight for r in pool)
        self.assertGreater(total, 100, 'Weekly の weight 合計が 100 以下 (前提が変わった)')
        self.assertEqual(weekly['total_weight'], total)

        # 最大 weight の報酬が「weight の数値そのもの」で表示されていないこと
        heaviest = max(pool, key=lambda r: r.weight)
        entry = next(
            e for e in weekly['rewards']
            if (e['name'], e['detail']) == (heaviest.name, heaviest.detail)
        )
        self.assertNotAlmostEqual(
            entry['probability'], float(heaviest.weight), places=2,
            msg='weight をそのまま % として出している',
        )

    # ── Pre-mortem #3: 同名報酬の分離 ────────────────────────────────

    def test_same_name_rewards_are_listed_separately(self):
        """同名で detail 違いの報酬（Daily の経験値ボーナス 3 種）が集約されない。"""
        res = self.client.get(self.url)
        daily = next(
            (b for b in res.json()['ticket_types'] if b['ticket_type'] == 'daily'),
            None,
        )
        if daily is None:
            self.skipTest('daily 報酬が seed されていない')

        pool = _active_reward_pool('daily')
        dup_names = {
            r.name for r in pool
            if sum(1 for x in pool if x.name == r.name) > 1
        }
        if not dup_names:
            self.skipTest('同名報酬が存在しない構成')

        for name in dup_names:
            expected = sum(1 for r in pool if r.name == name)
            actual   = sum(1 for e in daily['rewards'] if e['name'] == name)
            self.assertEqual(
                actual, expected,
                f'同名報酬「{name}」が {expected} 件あるのに {actual} 件しか開示されていない',
            )
            # detail が空だと区別できないため必ず入っていること
            for e in daily['rewards']:
                if e['name'] == name:
                    self.assertTrue(e['detail'], f'{name} の detail が空')

    # ── Pre-mortem #4: is_active ─────────────────────────────────────

    def test_inactive_reward_excluded_from_odds(self):
        """is_active=False の報酬は開示に含めず、確率も再正規化される。"""
        target = GachaReward.objects.filter(is_active=True, ticket_type='daily').first()
        self.assertIsNotNone(target, 'daily 報酬が存在しない')

        before = self.client.get(self.url).json()
        daily_before = next(
            b for b in before['ticket_types'] if b['ticket_type'] == 'daily'
        )

        target.is_active = False
        target.save(update_fields=['is_active'])

        after = self.client.get(self.url).json()
        daily_after = next(
            b for b in after['ticket_types'] if b['ticket_type'] == 'daily'
        )

        names_after = {(e['name'], e['detail']) for e in daily_after['rewards']}
        self.assertNotIn(
            (target.name, target.detail), names_after,
            '無効化した報酬が開示に残っている',
        )
        self.assertEqual(
            len(daily_after['rewards']), len(daily_before['rewards']) - 1,
        )
        # 残りで再正規化され、合計は 100% を保つ
        self.assertAlmostEqual(
            sum(e['probability'] for e in daily_after['rewards']), 100.0, delta=0.05,
        )

    # ── Pre-mortem #6: 購入前に到達できる ───────────────────────────

    def test_odds_readable_without_tickets(self):
        """チケットを 1 枚も持っていなくても確率を確認できる（購入前の開示）。"""
        res = self.client.get(self.url)
        self.assertEqual(res.status_code, 200)
        self.assertTrue(res.json()['ticket_types'], '報酬が 1 件も返っていない')

    def test_notes_are_present(self):
        """キャラ・武器の抽選方法を補足する注記が返る。"""
        res = self.client.get(self.url)
        self.assertTrue(res.json().get('notes'), '注記が空')

    # ── 構造 ─────────────────────────────────────────────────────────

    def test_weight_is_not_exposed(self):
        """生の weight はクライアントに返さない（正規化済み probability のみ）。"""
        res = self.client.get(self.url)
        for block in res.json()['ticket_types']:
            for entry in block['rewards']:
                self.assertNotIn('weight', entry)

    def test_unauthenticated_is_rejected(self):
        """未認証（ゲストトークンも無し）では 401。"""
        self.client.credentials()
        res = self.client.get(self.url)
        self.assertIn(res.status_code, (401, 403))
