"""【FEAT-420 (2026-06-10)】ストリーク保護「予約 → 翌日判定」モードの契約テスト (6 件)。

旧 FEAT-377 の「使う」即時消費 (在庫 -1 + 昨日の RestDay 作成) を廃止し、
予約 (`streak_protection_pending=True`) → 翌日の習慣達成判定で「途切れていた」
場合のみ消費する仕様に変更した (PM 設計決定 2026-06-10)。

検証対象:
1. 予約 (use/) → 在庫減らない、pending=True
2. 予約 + 翌日達成 (途切れず継続) → 在庫減らない + pending=False (消費なし)
3. 予約 + 翌日達成 (途切れ条件) → 在庫 1 減 + 保護発動 + pending=False + メッセージ
4. 予約 + 在庫 0 + 翌日途切れ → 在庫 0 のまま + pending=False (救済なし、消費もなし)
5. 自動保護 ON 時の use/ 呼び出し → 400 拒否
6. 予約取消 (cancel/) → pending=False、冪等
"""
from django.contrib.auth import get_user_model
from django.test import override_settings
from django.utils import timezone
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Habit, HabitLog, PlayerProfile
from ._error_assert import error_code, error_message  # 【FEAT-515】

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
class StreakProtectionPendingTest(APITestCase):
    """予約 → 翌日判定モードの契約テスト (HabitCountView + StreakProtection*View 経由)。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='sp_pending_test', password='pw')
        self.player = PlayerProfile.objects.create(
            user=self.user,
            streak_protection_count=2,
            streak_protection_auto_enabled=False,
        )
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        self.habit = _make_habit(self.player, streak=5)
        self.today = timezone.localdate()

    def _use(self):
        return self.client.post('/api/streak-protection/use/', format='json')

    def _cancel(self):
        return self.client.post('/api/streak-protection/cancel/', format='json')

    def _achieve_today(self):
        """今日の plus を 1 回叩く (was_zero=True で streak 判定が走る)。"""
        return self.client.post(
            f'/api/habits/{self.habit.pk}/count/',
            data={'action': 'plus'},
            format='json',
        )

    def _mark_yesterday_done(self):
        """昨日この習慣を達成済みにする (streak 継続条件)。"""
        from datetime import timedelta
        HabitLog.objects.create(
            habit=self.habit, date=self.today - timedelta(days=1),
            count=1, exp_gained=30,
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: 予約 → 在庫減らない、pending=True
    # ─────────────────────────────────────────────────────────────────
    def test_use_sets_pending_without_consuming_stock(self):
        res = self._use()
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)
        self.assertTrue(res.data.get('streak_protection_pending'))

        self.player.refresh_from_db()
        self.assertTrue(self.player.streak_protection_pending)
        self.assertEqual(self.player.streak_protection_count, 2,
                         msg='予約時点では在庫は消費されないはず')

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: 予約 + 翌日達成 (途切れず継続) → pending=False、消費なし
    # ─────────────────────────────────────────────────────────────────
    def test_pending_reset_without_consumption_when_streak_continues(self):
        self._mark_yesterday_done()
        self._use()

        res = self._achieve_today()
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)

        self.habit.refresh_from_db()
        self.player.refresh_from_db()

        self.assertEqual(self.habit.streak, 6,
                         msg='昨日達成済みなので streak は 5+1=6 で継続するはず')
        self.assertEqual(self.player.streak_protection_count, 2,
                         msg='途切れていないので在庫は消費されないはず')
        self.assertFalse(self.player.streak_protection_pending,
                          msg='判定後は pending=False にリセットされるはず')
        self.assertFalse(res.data.get('streak_protection_pending_consumed', False))
        self.assertIsNone(res.data.get('streak_protection_message'))

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: 予約 + 翌日達成 (途切れ条件) → 在庫 1 消費 + 保護発動
    # ─────────────────────────────────────────────────────────────────
    def test_pending_consumed_when_streak_was_broken(self):
        self._use()

        res = self._achieve_today()
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)

        self.habit.refresh_from_db()
        self.player.refresh_from_db()

        self.assertEqual(self.habit.streak, 6,
                         msg='保護発動で streak は 5+1=6 として継続するはず')
        self.assertEqual(self.player.streak_protection_count, 1,
                         msg='保護発動で在庫が 1 消費されるはず')
        self.assertFalse(self.player.streak_protection_pending)
        self.assertTrue(res.data.get('streak_protected'))
        self.assertTrue(res.data.get('streak_protection_pending_consumed'))
        self.assertIsNotNone(res.data.get('streak_protection_message'))

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 4: 予約 + 在庫 0 + 翌日途切れ → 救済なし、消費もなし
    # ─────────────────────────────────────────────────────────────────
    def test_pending_reset_without_rescue_when_no_stock(self):
        # まず予約 (在庫 2 で予約成功)
        self._use()
        # その後、別経路で在庫がゼロになったケースを再現 (Pre-mortem S1)
        self.player.streak_protection_count = 0
        self.player.save(update_fields=['streak_protection_count'])

        res = self._achieve_today()
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)

        self.habit.refresh_from_db()
        self.player.refresh_from_db()

        self.assertEqual(self.habit.streak, 1,
                         msg='在庫なしなので保護されず streak は 1 にリセットされるはず')
        self.assertEqual(self.player.streak_protection_count, 0)
        self.assertFalse(self.player.streak_protection_pending,
                          msg='救済できなくても pending は False にリセットされるはず')
        self.assertFalse(res.data.get('streak_protected', False))
        self.assertFalse(res.data.get('streak_protection_pending_consumed', False))

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 5: 自動保護 ON 時の use/ 呼び出し → 400 拒否
    # ─────────────────────────────────────────────────────────────────
    def test_use_rejected_when_auto_protection_enabled(self):
        self.player.streak_protection_auto_enabled = True
        self.player.save(update_fields=['streak_protection_auto_enabled'])

        res = self._use()
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST, res.data)
        self.assertEqual(error_code(res), 'streak_protection_auto_enabled')

        self.player.refresh_from_db()
        self.assertFalse(self.player.streak_protection_pending)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 6: 予約取消 (cancel/) → pending=False、冪等
    # ─────────────────────────────────────────────────────────────────
    def test_cancel_resets_pending_and_is_idempotent(self):
        self._use()
        self.player.refresh_from_db()
        self.assertTrue(self.player.streak_protection_pending)

        res = self._cancel()
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)
        self.assertFalse(res.data.get('streak_protection_pending'))

        self.player.refresh_from_db()
        self.assertFalse(self.player.streak_protection_pending)
        self.assertEqual(self.player.streak_protection_count, 2,
                         msg='取消では在庫は変化しないはず')

        # 冪等: 既に pending=False の状態で再度叩いても 200
        res2 = self._cancel()
        self.assertEqual(res2.status_code, http_status.HTTP_200_OK, res2.data)
        self.player.refresh_from_db()
        self.assertFalse(self.player.streak_protection_pending)
