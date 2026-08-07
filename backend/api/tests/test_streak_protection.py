"""【FEAT-377 (2026-05-29)】ストリーク保護機能の契約テスト (8 件)。

Pre-mortem #1 の守護: 既存 7 日ダイヤ付与経路 (FEAT-314) への影響ゼロを確認。
Pre-mortem #2 の守護: login_streak は保護発動で影響しないことを確認。

検証対象:
1. 購入成功 → 💎 30 消費 + streak_protection_count +1
2. 在庫上限 3 個到達時 → 400 拒否
3. 自動保護 ON + 在庫あり → streak 途切れ時に自動消費
4. 自動保護 OFF → 自動消費しない
5. 在庫ゼロ → 自動消費しない (在庫不足でもエラーなし)
6. 1 日 1 回上限 (冪等) → 2 回目は発動しない
7. login_streak は保護発動で影響しない (Pre-mortem #2)
8. 7 日 streak ダイヤ付与経路は保護発動で冪等担保が壊れない (Pre-mortem #1)
"""
from datetime import date as date_type, timedelta

from django.contrib.auth import get_user_model
from django.test import override_settings
from django.utils import timezone
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Habit, HabitLog, PlayerProfile

User = get_user_model()


_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'api.authentication.ExpiringTokenAuthentication',
        'api.authentication.GuestTokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
}


def _make_habit(player, name='テスト習慣', streak=5) -> Habit:
    """テスト用 Habit を作成して streak を設定する。"""
    habit = Habit.objects.create(
        player=player, name=name, category='運動', frequency='daily',
        reset_cycle='daily', habit_type='count', difficulty='normal',
    )
    habit.streak = streak
    habit.save(update_fields=['streak'])
    return habit


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class StreakProtectionPurchaseTest(APITestCase):
    """ショップ購入経路の契約テスト。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='sp_buy_test', password='pw')
        self.player = PlayerProfile.objects.create(user=self.user, diamonds=100)
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    def _purchase(self):
        return self.client.post(
            '/api/shop/purchase/',
            data={'item_id': 'streak_protection'},
            format='json',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: 購入成功
    # ─────────────────────────────────────────────────────────────────
    def test_purchase_consumes_30_diamonds_and_increments_count(self):
        res = self._purchase()
        self.assertEqual(res.status_code, http_status.HTTP_201_CREATED, res.data)

        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 100 - 30)
        self.assertEqual(self.player.streak_protection_count, 1)
        self.assertEqual(res.data.get('streak_protection_count'), 1)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: 上限 3 個到達時 → 400 拒否
    # ─────────────────────────────────────────────────────────────────
    def test_purchase_rejected_at_max_stock_3(self):
        self.player.streak_protection_count = 3
        self.player.save(update_fields=['streak_protection_count'])

        res = self._purchase()
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        self.player.refresh_from_db()
        self.assertEqual(self.player.streak_protection_count, 3)  # 変わらない
        self.assertEqual(self.player.diamonds, 100)  # 消費されない


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class StreakProtectionAutoTest(APITestCase):
    """自動保護発動 / 非発動のテスト (HabitCountView 経由)。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='sp_auto_test', password='pw')
        self.player = PlayerProfile.objects.create(
            user=self.user,
            streak_protection_count=2,
            streak_protection_auto_enabled=True,
        )
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        self.habit = _make_habit(self.player, streak=7)

    def _simulate_streak_break_and_achieve(self):
        """昨日を空けて (streak 途切れ条件) 今日 plus を叩く。"""
        # 「昨日なし」= HabitLog が昨日にない
        # 本日 plus を呼ぶと `was_zero=True`, `yesterday_done=False`, `yesterday_rest=False`
        # → streak = 1 になるはずが、自動保護発動で streak = 8 になる
        today = timezone.localdate()
        # 今日の log がまだない状態で plus を叩く
        return self.client.post(
            f'/api/habits/{self.habit.pk}/count/',
            data={'action': 'plus'},
            format='json',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: 自動保護 ON + 在庫あり → streak 途切れを自動保護
    # ─────────────────────────────────────────────────────────────────
    def test_auto_protection_consumed_when_enabled_and_stock_available(self):
        """自動保護 ON + 在庫あり → streak 維持 (1 にリセットされない)。"""
        res = self._simulate_streak_break_and_achieve()
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)

        self.habit.refresh_from_db()
        self.player.refresh_from_db()

        # streak は 8 に継続 (7 + 1、1 にリセットされていない)
        self.assertEqual(self.habit.streak, 8,
                         msg='自動保護発動で streak は維持されるはず (7+1=8)')
        # 在庫が 1 減った
        self.assertEqual(self.player.streak_protection_count, 1)
        # streak_protected フラグが response に含まれる
        self.assertTrue(res.data.get('streak_protected'),
                        msg='response に streak_protected=True が含まれるはず')

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 4: 自動保護 OFF → 自動消費しない
    # ─────────────────────────────────────────────────────────────────
    def test_auto_protection_not_consumed_when_disabled(self):
        """自動保護 OFF では streak が 1 にリセットされる。"""
        self.player.streak_protection_auto_enabled = False
        self.player.save(update_fields=['streak_protection_auto_enabled'])

        res = self._simulate_streak_break_and_achieve()
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)

        self.habit.refresh_from_db()
        self.player.refresh_from_db()

        self.assertEqual(self.habit.streak, 1,
                         msg='自動保護 OFF なら streak は 1 にリセットされるはず')
        self.assertEqual(self.player.streak_protection_count, 2,
                         msg='自動保護 OFF なら在庫は消費されないはず')
        self.assertFalse(res.data.get('streak_protected', False))

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 5: 在庫ゼロ → 自動消費しない
    # ─────────────────────────────────────────────────────────────────
    def test_auto_protection_not_consumed_when_stock_zero(self):
        """在庫ゼロ (count=0) では保護発動しない。"""
        self.player.streak_protection_count = 0
        self.player.save(update_fields=['streak_protection_count'])

        res = self._simulate_streak_break_and_achieve()
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)

        self.habit.refresh_from_db()
        self.assertEqual(self.habit.streak, 1,
                         msg='在庫ゼロなら保護発動しないため streak は 1')
        self.assertFalse(res.data.get('streak_protected', False))

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 6: 1 日 1 回上限 (冪等)
    # ─────────────────────────────────────────────────────────────────
    def test_protection_idempotent_per_day(self):
        """同日 2 回目は在庫消費なしで保護発動 (BUG-85 挙動、当日冪等)。

        【BUG-85 (2026-06-10) 変更】旧: today_already_used → 保護未発動 (streak=1)
        新: today_already_used → 在庫消費なしで保護発動 (streak=8、stock 維持)
        """
        today = timezone.localdate()
        # 当日既使用をマーク
        self.player.last_streak_protection_used_at = today
        self.player.save(update_fields=['last_streak_protection_used_at'])

        res = self._simulate_streak_break_and_achieve()
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)

        self.habit.refresh_from_db()
        self.player.refresh_from_db()

        # BUG-85: 当日既使用でも保護は発動する (在庫消費なし)
        self.assertEqual(self.habit.streak, 8,
                         msg='BUG-85: today_already_used でも保護発動、streak=7+1=8')
        self.assertEqual(self.player.streak_protection_count, 2,
                         msg='当日既使用なら在庫は消費されないはず')
        self.assertTrue(res.data.get('streak_protected', False),
                        msg='BUG-85: today_already_used でも streak_protected=True')


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class StreakProtectionIndependenceTest(APITestCase):
    """Pre-mortem #1/#2 の独立性担保テスト。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='sp_indep_test', password='pw')
        self.player = PlayerProfile.objects.create(
            user=self.user,
            streak_protection_count=2,
            streak_protection_auto_enabled=True,
            login_streak_days=5,  # 既存 login_streak を持つ
        )
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        self.habit = _make_habit(self.player, streak=7)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 7: login_streak は保護発動で影響しない (Pre-mortem #2)
    # ─────────────────────────────────────────────────────────────────
    def test_protection_does_not_affect_login_streak(self):
        """ストリーク保護発動時に login_streak_days は変わらない。"""
        before_login_streak = self.player.login_streak_days  # 5

        # streak 保護発動させる (streak=7 の習慣を昨日なしで today plus)
        res = self.client.post(
            f'/api/habits/{self.habit.pk}/count/',
            data={'action': 'plus'},
            format='json',
        )
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)

        self.player.refresh_from_db()
        self.assertEqual(
            self.player.login_streak_days, before_login_streak,
            msg='ストリーク保護発動は login_streak_days に影響しないはず',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 8: 7 日ダイヤ付与経路は保護後も冪等担保 (Pre-mortem #1)
    # ─────────────────────────────────────────────────────────────────
    # 【BUG-141 判定完了 (2026-08-04)】
    #
    # 症状は「保護発動で +500 diamond (550 != 50)」だったが、**spec 変更でも
    # 冪等回帰でもなく、本テストの分離漏れ**だった。
    #
    # 習慣カウント経路は当日初回タスクで 3 つのダイヤ経路を踏む:
    #
    #   1. award_diamond_if_first_today   ガード: economy.diamond_bonus_date
    #   2. award_daily_first_task_bonus   ガード: streak.last_login_diamond_at
    #   3. award_diamond_for_streak_7days ガード: streak.last_streak_diamond_day ← 本テストの対象
    #
    # 旧実装は 1 だけを止めていた。setUp で作られたプレイヤーは created_at が
    # 当日なので 2 が **Day 1 = +500 ダイヤ** (DIAMOND_FIRST_TASK_DAY_1) を配る。
    # 50 + 500 = 550 で観測値と一致する。
    #
    # → 2 のガードも立てて「7 日ダイヤ経路のみ」を正しく分離する。これで本テストが
    #   元々守りたかった **冪等性の検証が復活する** (500 に埋もれて、+5 が付いたか
    #   付かないかを判定できていなかった)。
    def test_existing_7day_streak_diamond_unaffected_by_protection(self):
        """streak=7 で既に 7 日ダイヤを取得済みの場合、保護で streak=8 になっても
        award_diamond_for_streak_7days は冪等チェックで再付与しない。"""
        today = timezone.localdate()
        # streak=7 の習慣 + last_streak_diamond_day=7 (既に 7 日ダイヤ取得済み)
        self.player.last_streak_diamond_day = 7
        self.player.diamonds = 50
        self.player.diamond_bonus_date = today  # 当日初回ダイヤ (+1) を無効化
        self.player.save(update_fields=['last_streak_diamond_day', 'diamonds', 'diamond_bonus_date'])
        # 当日初回タスクボーナス (Day 1 なら +500) を無効化。
        # **これが無いと 7 日ダイヤ経路の増減が 500 に埋もれて検証できない。**
        streak_state = self.player.streak
        streak_state.last_login_diamond_at = today
        streak_state.save(update_fields=['last_login_diamond_at'])

        # streak 保護発動 → streak: 7 → 8 (7 の倍数ではないので diamond 追加なし)
        res = self.client.post(
            f'/api/habits/{self.habit.pk}/count/',
            data={'action': 'plus'},
            format='json',
        )
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)

        self.habit.refresh_from_db()
        self.player.refresh_from_db()

        # streak = 8 (保護発動)
        self.assertEqual(self.habit.streak, 8,
                         msg='保護で streak は 8 になるはず')

        # ダイヤは変わらない (8 は 7 の倍数でないため付与なし)
        self.assertEqual(self.player.diamonds, 50,
                         msg='streak=8 は 7 の倍数でないため ダイヤ付与なし')
        # last_streak_diamond_day も変わらない
        self.assertEqual(self.player.last_streak_diamond_day, 7,
                         msg='last_streak_diamond_day は変わらないはず')
