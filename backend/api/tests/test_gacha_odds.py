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
from api.views.gacha import (
    _DAILY_REWARDS, _MONTHLY_REWARDS, _WEEKLY_REWARDS,
    _active_reward_pool, _ensure_gacha_rewards,
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


# ──────────────────────────────────────────────────────────────────────────────
# 【2026-08-09】weight 合計の「母数」を縛る
# ──────────────────────────────────────────────────────────────────────────────

class GachaWeightTotalContractTest(APITestCase):
    """ticket_type ごとの active weight 合計が設計値であることを固定する。

    ## なぜ既存テストでは足りなかったか (実際に起きたこと)

    dev DB で `daily` の weight 合計が **102** になっていた。原因は
    `大量経験値 EXP +250` / `特大経験値 EXP +500` という**旧世代の行が
    is_active=True のまま残っていた**こと。`_ensure_gacha_rewards` は
    `(ticket_type, name, detail)` で `get_or_create` するため、報酬額を
    +250 -> +350 に変えた時点で「旧行を残したまま新行を作る」動きになる
    (gacha.py:117「既存 entry は触らず、欠落分のみ作成」)。

    結果、daily SSR の排出率が設計 1.00% に対し **1.96% (約 2 倍)** になり、
    SSR を引いても半分は +500 (期待 EXP 1000 -> 750) という状態だった。

    既存の `test_probabilities_sum_to_100` はこれを検出できない。
    **`weight / total * 100` の合計**を見ているので、行が何行増えても
    常に 100% になる。「合計が 100 になる」は縛れていても
    **「母数が 100 である」は縛れていなかった**。

    gacha.py:41-43 のコメントは「Pre-mortem #3 weight 合計の不変式 (Daily 100)
    を契約テストで縛る」と書いていたが、縛れていたのは別のものだった。

    ## 本テストの守備範囲と、その外側

    本テストが守るのは **コード側の spec** と **seed 直後の DB**。
    デプロイ済み環境で起きた drift (今回の実例) は、テスト DB に旧行が
    存在しないため構造的に検出できない。**環境の drift は SQL による
    運用チェックで見る** —— doc/release_checklist/v1.1.md の G7 参照。
    """

    # 設計値。変更するときは gacha.py の spec と本表を **同時に** 動かすこと。
    EXPECTED_TOTALS = {'daily': 100, 'weekly': 200, 'monthly': 100}

    def test_code_spec_weight_totals(self):
        """コード側 spec の weight 合計が設計値。

        報酬を足すとき「weight を再配分し忘れる」のを止める層。
        """
        specs = {
            'daily':   _DAILY_REWARDS,
            'weekly':  _WEEKLY_REWARDS,
            'monthly': _MONTHLY_REWARDS,
        }
        for ticket_type, expected in self.EXPECTED_TOTALS.items():
            total = sum(s['weight'] for s in specs[ticket_type])
            self.assertEqual(
                total, expected,
                f'{ticket_type} の spec weight 合計が {total} (設計値 {expected})。'
                '報酬を足したなら他の weight を減らして合計を保つこと',
            )

    def test_seeded_db_weight_totals(self):
        """seed 直後の DB でも合計が設計値。

        spec が正しくても `_ensure_gacha_rewards` が重複行を作れば崩れる層。
        """
        _ensure_gacha_rewards()
        for ticket_type, expected in self.EXPECTED_TOTALS.items():
            total = sum(r.weight for r in _active_reward_pool(ticket_type))
            self.assertEqual(
                total, expected,
                f'{ticket_type} の DB weight 合計が {total} (設計値 {expected})',
            )

    def test_no_active_reward_outside_code_spec(self):
        """active な行はすべてコード spec に存在する。

        dev で起きた drift そのものの形。テスト DB には旧行が無いので
        ここは通るが、**同じ判定を SQL に写して環境に対して流す**ための
        基準として置いておく (docstring 参照)。
        """
        _ensure_gacha_rewards()
        spec_keys = {
            (s['ticket_type'], s['name'], s['detail'])
            for s in (*_DAILY_REWARDS, *_WEEKLY_REWARDS, *_MONTHLY_REWARDS)
        }
        for ticket_type in self.EXPECTED_TOTALS:
            for r in _active_reward_pool(ticket_type):
                # weapon / character 等 migration 由来の行は spec に無くてよい。
                # exp / xp_boost は spec が唯一の真実値。
                if r.reward_type not in ('exp', 'xp_boost'):
                    continue
                self.assertIn(
                    (r.ticket_type, r.name, r.detail), spec_keys,
                    f'コード spec に無い active 報酬: {r.ticket_type} / '
                    f'{r.name} / {r.detail} (旧世代の行が残っていないか)',
                )

    def test_detail_change_leaves_stale_row(self):
        """`detail` を変えると旧行が残る —— という既知の挙動を明文化する。

        これは「直すべきバグ」ではなく **`get_or_create` の帰結**であり、
        dev で 102 になった機構そのもの。将来この挙動を変えるなら本テストが
        赤くなるので、そのとき初めて意図的な変更として扱える。

        同時に「**なぜ環境側の運用チェックが要るのか**」の実行可能な説明でもある。
        """
        _ensure_gacha_rewards()
        before = sum(r.weight for r in _active_reward_pool('daily'))
        self.assertEqual(before, 100, '前提: seed 直後は 100')

        # 報酬額を過去世代に巻き戻した状態を作る (dev で起きていた形)
        GachaReward.objects.filter(
            ticket_type='daily', name='特大経験値', detail='EXP +1000',
        ).update(detail='EXP +500', value=500)

        _ensure_gacha_rewards()  # 再 seed = +1000 の行が新規作成される

        after = sum(r.weight for r in _active_reward_pool('daily'))
        self.assertEqual(
            after, 101,
            '旧行が残ったまま新行が増える挙動が変わった。'
            '意図した変更なら本テストと運用チェックを見直すこと',
        )
        self.assertEqual(
            GachaReward.objects.filter(
                ticket_type='daily', name='特大経験値', is_active=True,
            ).count(), 2,
            '同名で detail 違いの行が 2 本 active になる',
        )
