"""【FEAT-406 (2026-06-01)】battle_charges 日次リセット契約テスト 4 シナリオ。

Pre-mortem S1 対応: 「日跨ぎで charges が前日のまま持ち越される」問題を
reset_battle_charges_if_new_day() による「今日初めての操作でリセット」方式で解消する。

テスト方針:
  - reset_battle_charges_if_new_day() を直接 unit テスト
  - HabitCountView 経由の HTTP テストで加算 + 日次リセット動作を E2E 確認
"""
import datetime

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Habit, PlayerProfile
from api.services.daily_throttle_service import reset_battle_charges_if_new_day

User = get_user_model()

_TEST_RF_OVERRIDE = {
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


class BattleChargesDailyResetServiceTest(TestCase):
    """reset_battle_charges_if_new_day() の直接 unit テスト 4 シナリオ。"""

    def _make_player(self, battle_charges=0, date=None):
        u = User.objects.create_user(f'reset_u_{battle_charges}_{date}', email=f'r{battle_charges}@t.com')
        p = PlayerProfile.objects.create(user=u, name='ResetTest')
        # 【FEAT-478 Phase 2b (2026-07-04)】initial state を NEW state
        # (PlayerBattleState) に書込 + save。旧 OLD field 直書き (p.battle_charges = X)
        # は write path (reset_battle_charges_if_new_day) が NEW state を読むため無効。
        battle = p.battle
        battle.battle_charges = battle_charges
        battle.battle_charges_date = date
        battle.save(update_fields=['battle_charges', 'battle_charges_date'])
        return p

    # ─────────────────────────────────────────────────────────────────────
    # シナリオ 1: battle_charges_date=None (初回) → リセット発火、charges=0 に
    # ─────────────────────────────────────────────────────────────────────
    def test_1_null_date_triggers_reset(self):
        """battle_charges_date=None → reset_battle_charges_if_new_day が True を返す。

        既存 charges (3) が 0 にリセットされ、battle_charges_date=today に更新。
        Pre-mortem S1: 既存ユーザーが migration 0120 後も安全に動作するシナリオ。
        """
        today = timezone.localdate()
        p = self._make_player(battle_charges=3, date=None)

        result = reset_battle_charges_if_new_day(p)

        self.assertTrue(result, 'date=None → リセット発火 (True を返す)')
        self.assertEqual(p.battle.battle_charges, 0, 'charges がリセットされた')
        self.assertEqual(p.battle.battle_charges_date, today, 'battle_charges_date が today に設定された')

    # ─────────────────────────────────────────────────────────────────────
    # シナリオ 2: battle_charges_date=今日 → リセットなし
    # ─────────────────────────────────────────────────────────────────────
    def test_2_same_day_no_reset(self):
        """battle_charges_date=today → reset_battle_charges_if_new_day が False を返す。

        charges は変更されない (同日内の 2 回目以降の呼び出しを想定)。
        """
        today = timezone.localdate()
        p = self._make_player(battle_charges=2, date=today)

        result = reset_battle_charges_if_new_day(p)

        self.assertFalse(result, 'date=today → リセットなし (False を返す)')
        self.assertEqual(p.battle.battle_charges, 2, 'charges は変更なし')
        self.assertEqual(p.battle.battle_charges_date, today, 'battle_charges_date も変更なし')

    # ─────────────────────────────────────────────────────────────────────
    # シナリオ 3: battle_charges_date=昨日 → リセット発火
    # ─────────────────────────────────────────────────────────────────────
    def test_3_yesterday_triggers_reset(self):
        """battle_charges_date=昨日 → リセット発火、charges=0 に。

        Pre-mortem S1 の主要シナリオ: 23:59 に 3 達成 → 0:01 にバトル試行。
        """
        today = timezone.localdate()
        yesterday = today - datetime.timedelta(days=1)
        p = self._make_player(battle_charges=3, date=yesterday)

        result = reset_battle_charges_if_new_day(p)

        self.assertTrue(result, 'date=昨日 → リセット発火 (True を返す)')
        self.assertEqual(p.battle.battle_charges, 0, '前日の charges が 0 にリセットされた')
        self.assertEqual(p.battle.battle_charges_date, today, 'battle_charges_date が today に更新')

    # ─────────────────────────────────────────────────────────────────────
    # シナリオ 4: 同日複数回呼び出し → 1 回目だけリセット、2 回目は no-op
    # ─────────────────────────────────────────────────────────────────────
    def test_4_idempotent_second_call_same_day(self):
        """1 回目リセット (date=None → today) → 2 回目は同日なので no-op。

        習慣達成 → バトル開始の順でどちらも reset を呼ぶ場合も安全。
        """
        p = self._make_player(battle_charges=3, date=None)

        result1 = reset_battle_charges_if_new_day(p)  # リセット発火
        self.assertTrue(result1)
        self.assertEqual(p.battle.battle_charges, 0)

        # 2 回目: date が today になっているのでリセット不要
        # 【FEAT-478 Phase 2b】NEW state の charges を 1 に (「1 回習慣達成した状態」)
        battle = p.battle
        battle.battle_charges = 1
        battle.save(update_fields=['battle_charges'])
        result2 = reset_battle_charges_if_new_day(p)
        self.assertFalse(result2, '2 回目は同日なので no-op')
        self.assertEqual(p.battle.battle_charges, 1, 'charges は変更されない')


@override_settings(REST_FRAMEWORK=_TEST_RF_OVERRIDE)
class BattleChargesDailyResetE2ETest(APITestCase):
    """HabitCountView 経由で日次リセット + charges 加算の E2E 確認 2 件。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('e2e_reset_user', email='e2er@t.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='E2EResetTest',
        )
        # 【FEAT-478 Phase 2b (2026-07-04)】initial state を NEW state
        # (PlayerBattleState) に書込 + save。旧 PlayerProfile.objects.create の
        # battle_charges=3 kwargs は OLD field への write で、write path (HabitCount)
        # が NEW state を読むため無効化された。
        battle = self.player.battle
        battle.battle_charges = 3           # 前日の最大 charges
        battle.battle_charges_date = None   # 未設定 (migration 後の初期状態 or 前日ユーザー)
        battle.save(update_fields=['battle_charges', 'battle_charges_date'])
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        self.habit = Habit.objects.create(
            player=self.player,
            name='日次リセットテスト習慣',
            category='運動',
            difficulty='easy',
            frequency='daily',
            habit_type='count',
        )

    def _plus(self):
        return self.client.post(
            reverse('habit-count', args=[self.habit.pk]),
            data={'action': 'plus'}, format='json',
        )

    # E2E-A: date=None → plus → charges が 3 から 0 にリセット後 +1 = 1 になる
    def test_E2E_A_null_date_resets_before_add(self):
        """battle_charges=3, date=None の状態で plus → charges=1 (リセット後 +1)。

        FEAT-403 以前の「蓄積した charges が翌日以降に持ち越される」問題を解消。
        """
        res = self._plus()
        self.assertEqual(res.status_code, 200, res.content)

        # 【2026-07-25 P3 #1-c】refresh_from_db() で shim state cache invalidate
        self.player.refresh_from_db()
        self.assertEqual(
            self.player.battle.battle_charges, 1,
            'リセット (3→0) 後に +1 = 1。前日の charges 3 は引き継がれない',
        )
        self.assertEqual(
            self.player.battle.battle_charges_date, timezone.localdate(),
            'battle_charges_date が今日付になった',
        )

    # E2E-B: date=today → plus → リセットなし、通常加算
    def test_E2E_B_today_date_no_reset_normal_add(self):
        """battle_charges=1, date=today の状態で plus → charges=2 (リセットなし)。"""
        today = timezone.localdate()
        battle = self.player.battle
        battle.battle_charges = 1
        battle.battle_charges_date = today
        battle.save(update_fields=['battle_charges', 'battle_charges_date'])

        res = self._plus()
        self.assertEqual(res.status_code, 200, res.content)

        self.player.refresh_from_db()
        self.assertEqual(
            self.player.battle.battle_charges, 2,
            '今日付 → リセットなし → 1+1=2',
        )
