"""【FEAT-398 (2026-05-31)】日次スロットル契約テスト 16 シナリオ (A-P)。

カバー:
  EXP スロットル (経路 1-2): A-H (8 件)
  バトル出陣上限 (経路 4):   I-L (4 件)
  battle_charges 取り消し対称化 (第 3 段階): M-P (4 件)

テスト方針:
  - EXP スロットル: daily_throttle_service を直接 mock して unit テスト
  - バトル出陣上限: HTTP 経由で BattleStartView を呼び、403 を確認
  - charges フラグ: HTTP 経由で HabitCountView plus/minus を呼び、DB を確認
"""
import datetime

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.constants import (
    DAILY_BATTLE_LIMIT,
    DAILY_EXP_THROTTLE_LIMIT,
    DAILY_EXP_THROTTLED_VALUE,
)
from api.models import Enemy, Habit, HabitLog, PlayerProfile, TimelineEvent
from api.services.daily_throttle_service import (
    apply_daily_exp_throttle,
    check_daily_battle_limit,
    increment_daily_battle_count,
)
from ._error_assert import error_code, error_message  # 【FEAT-515】

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


# ─────────────────────────────────────────────────────────────────────────────
# EXP スロットル service ユニットテスト (A-H)
# ─────────────────────────────────────────────────────────────────────────────

class DailyExpThrottleServiceTest(TestCase):
    """apply_daily_exp_throttle の 8 シナリオ。"""

    def _make_player(self, count=0, date=None):
        u = User.objects.create_user(f'u{count}_{date}', email=f'u{count}@t.com')
        p = PlayerProfile.objects.create(user=u, name='Test')
        # 【FEAT-478 Phase 2b (2026-07-04)】initial state を NEW state
        # (PlayerBattleState) に直接書込 + save。proxy が毎回新インスタンスを返すため、
        # local 変数に受けてから save する必要がある (in-memory 変更は破棄される)。
        battle = p.battle
        battle.daily_exp_count = count
        battle.daily_exp_count_date = date
        battle.save(update_fields=['daily_exp_count', 'daily_exp_count_date'])
        return p

    # A: 閾値前は通常 EXP
    def test_A_below_limit_no_throttle(self):
        """daily_exp_count=0 → +1 → exp_gain=20、throttled=False。"""
        today = timezone.localdate()
        p = self._make_player(count=0, date=today)
        exp_out, triggered = apply_daily_exp_throttle(p, 20)
        self.assertEqual(exp_out, 20)
        self.assertFalse(triggered)
        self.assertEqual(p.battle.daily_exp_count, 1)

    # B: 閾値ぎりぎり (25 件目) は通常 EXP
    def test_B_at_limit_minus1_no_throttle(self):
        """daily_exp_count=24 → +1 → exp_gain=20、count=25、throttled=False。"""
        today = timezone.localdate()
        p = self._make_player(count=24, date=today)
        exp_out, triggered = apply_daily_exp_throttle(p, 20)
        self.assertEqual(exp_out, 20)
        self.assertFalse(triggered)
        self.assertEqual(p.battle.daily_exp_count, 25)

    # C: 閾値到達直後 (26 件目) は 1pt 固定 + triggered=True
    def test_C_first_over_limit_is_1pt_and_triggered(self):
        """daily_exp_count=25 → +1 → exp_gain=1、throttled_now=True。"""
        today = timezone.localdate()
        p = self._make_player(count=DAILY_EXP_THROTTLE_LIMIT, date=today)
        exp_out, triggered = apply_daily_exp_throttle(p, 100)
        self.assertEqual(exp_out, DAILY_EXP_THROTTLED_VALUE)
        self.assertTrue(triggered)
        self.assertEqual(p.battle.daily_exp_count, DAILY_EXP_THROTTLE_LIMIT + 1)

    # D: 閾値超過後 2 回目以降も 1pt 固定 (再通知なし)
    def test_D_over_limit_subsequent_no_retrigger(self):
        """daily_exp_count=26 → +1 → exp_gain=1、throttled_now=False。"""
        today = timezone.localdate()
        p = self._make_player(count=DAILY_EXP_THROTTLE_LIMIT + 1, date=today)
        exp_out, triggered = apply_daily_exp_throttle(p, 40)
        self.assertEqual(exp_out, DAILY_EXP_THROTTLED_VALUE)
        self.assertFalse(triggered)

    # E: 日付変わったら自動リセット
    def test_E_date_change_resets_count(self):
        """daily_exp_count=30, date=昨日 → +1 → count=1、exp_gain=20。"""
        yesterday = timezone.localdate() - datetime.timedelta(days=1)
        p = self._make_player(count=30, date=yesterday)
        exp_out, triggered = apply_daily_exp_throttle(p, 20)
        self.assertEqual(exp_out, 20)
        self.assertFalse(triggered)
        self.assertEqual(p.battle.daily_exp_count, 1)
        self.assertEqual(p.battle.daily_exp_count_date, timezone.localdate())

    # F: date=None (初回) も今日として扱う → リセット
    def test_F_none_date_treated_as_new_day(self):
        """date=None → リセットして count=1。"""
        p = self._make_player(count=30, date=None)
        exp_out, triggered = apply_daily_exp_throttle(p, 20)
        self.assertEqual(exp_out, 20)
        self.assertFalse(triggered)
        self.assertEqual(p.battle.daily_exp_count, 1)

    # G: Legendary 難易度も 1pt 固定
    def test_G_legendary_over_limit_becomes_1pt(self):
        """daily_exp_count=25 で Legendary +1 → exp_gain=1。"""
        today = timezone.localdate()
        p = self._make_player(count=DAILY_EXP_THROTTLE_LIMIT, date=today)
        exp_out, triggered = apply_daily_exp_throttle(p, 100)
        self.assertEqual(exp_out, DAILY_EXP_THROTTLED_VALUE)
        self.assertTrue(triggered)

    # H: バトル出陣上限は apply_daily_exp_throttle と独立
    def test_H_battle_count_does_not_affect_exp_throttle(self):
        """daily_battle_count=10 (上限) でも EXP スロットルは独立。"""
        today = timezone.localdate()
        p = self._make_player(count=0, date=today)
        p.daily_battle_count = DAILY_BATTLE_LIMIT
        p.daily_battle_count_date = today
        # EXP スロットルはバトルカウントと無関係
        exp_out, triggered = apply_daily_exp_throttle(p, 20)
        self.assertEqual(exp_out, 20)
        self.assertFalse(triggered)


# ─────────────────────────────────────────────────────────────────────────────
# バトル出陣上限 HTTP テスト (I-L)
# ─────────────────────────────────────────────────────────────────────────────

@override_settings(REST_FRAMEWORK=_TEST_RF_OVERRIDE)
class DailyBattleLimitTest(APITestCase):
    """check_daily_battle_limit + BattleStartView の 4 シナリオ。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('battle_limit_user', email='bl@t.com')
        today = timezone.localdate()
        self.player = PlayerProfile.objects.create(
            user=self.user, name='BLimit',
            battle_charges=9,             # 出陣可能
            battle_charges_date=today,    # FEAT-406: 日次リセットで 0 になるのを防ぐ
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        Enemy.objects.update_or_create(
            key='goblin',
            defaults={
                'name': 'ゴブリン', 'sprite_key': 'enemy_goblin',
                'base_hp': 60, 'base_atk': 8, 'base_spd': 10,
                'level_scaling': 1.0, 'reward_coins': 10, 'reward_exp': 20,
                'tier': 'zako',
            },
        )

    def _start_battle(self):
        return self.client.post(reverse('battle-start'))

    # 【FEAT-478 Phase 2b (2026-07-04)】write path が player.battle
    # (PlayerBattleState、@property proxy) 経由に統一されたため、初期状態設定も
    # 同 proxy 経由で NEW state に直接書込 + save する。
    # `self.player.battle.field = X` は proxy が毎回新しいインスタンスを返すため
    # in-memory 変更が破棄される (BUG-prone)。必ず local 変数に受けてから save する。

    # I: 上限前は通常出陣
    def test_I_below_limit_battle_succeeds(self):
        """daily_battle_count=0 → 出陣成功、count=1。"""
        today = timezone.localdate()
        battle = self.player.battle
        battle.daily_battle_count = 0
        battle.daily_battle_count_date = today
        battle.save(update_fields=['daily_battle_count', 'daily_battle_count_date'])

        res = self._start_battle()
        self.assertEqual(res.status_code, 200, res.content)
        # 【2026-07-25 P3 #1-c】refresh_from_db() で shim state cache invalidate
        self.player.refresh_from_db()
        self.assertEqual(self.player.battle.daily_battle_count, 1)

    # J: 上限ぎりぎり (10 回目) は出陣可
    def test_J_at_limit_minus1_still_succeeds(self):
        """daily_battle_count=9 → 出陣成功、count=10。"""
        today = timezone.localdate()
        battle = self.player.battle
        battle.daily_battle_count = DAILY_BATTLE_LIMIT - 1
        battle.daily_battle_count_date = today
        battle.save(update_fields=['daily_battle_count', 'daily_battle_count_date'])

        res = self._start_battle()
        self.assertEqual(res.status_code, 200, res.content)
        self.player.refresh_from_db()
        self.assertEqual(self.player.battle.daily_battle_count, DAILY_BATTLE_LIMIT)

    # K: 上限到達後 (11 回目) は 403 拒否
    def test_K_at_limit_returns_403(self):
        """daily_battle_count=10 → 出陣 → 403 + code='daily_battle_limit_reached'。

        【FEAT-429 (2026-06-12)】check_daily_battle_limit は 3 要素タプル
        (can_battle, current_count, dynamic_limit) を返すようになったが、
        本シナリオは daily_battle_limit_bonus=0 (default) のため
        dynamic_limit = DAILY_BATTLE_LIMIT + 0 = DAILY_BATTLE_LIMIT で従来通り。
        bonus > 0 の動的 limit シナリオは test_dynamic_battle_limit.py 側で検証する。
        """
        today = timezone.localdate()
        battle = self.player.battle
        battle.daily_battle_count = DAILY_BATTLE_LIMIT
        battle.daily_battle_count_date = today
        battle.save(update_fields=['daily_battle_count', 'daily_battle_count_date'])

        res = self._start_battle()
        self.assertEqual(res.status_code, 403, res.content)
        self.assertEqual(error_code(res), 'daily_battle_limit_reached')
        self.assertEqual(res.data['limit'], DAILY_BATTLE_LIMIT)
        # count は増えない
        self.assertEqual(self.player.battle.daily_battle_count, DAILY_BATTLE_LIMIT)

    # L: 日付変わったらリセット → 出陣可
    def test_L_date_change_resets_battle_count(self):
        """daily_battle_count=10, date=昨日 → 出陣成功、count=1。"""
        yesterday = timezone.localdate() - datetime.timedelta(days=1)
        battle = self.player.battle
        battle.daily_battle_count = DAILY_BATTLE_LIMIT
        battle.daily_battle_count_date = yesterday
        battle.save(update_fields=['daily_battle_count', 'daily_battle_count_date'])

        res = self._start_battle()
        self.assertEqual(res.status_code, 200, res.content)
        self.player.refresh_from_db()
        self.assertEqual(self.player.battle.daily_battle_count, 1)
        self.assertEqual(self.player.battle.daily_battle_count_date, timezone.localdate())

    def test_L2_player_fetch_resets_stale_battle_count_for_ui_gate(self):
        """daily_battle_count=10, date=昨日 → /player/ は 0 を返し DB も今日付に同期する。

        BUG-78: Flutter の BattleAvailability が stale な 10/10 を見て
        BattleStartView に到達する前に出陣ボタンを無効化し続ける回帰を防ぐ。
        """
        yesterday = timezone.localdate() - datetime.timedelta(days=1)
        battle = self.player.battle
        battle.daily_battle_count = DAILY_BATTLE_LIMIT
        battle.daily_battle_count_date = yesterday
        battle.save(update_fields=['daily_battle_count', 'daily_battle_count_date'])

        res = self.client.get(reverse('player'))
        self.assertEqual(res.status_code, 200, res.content)
        self.assertEqual(res.data['daily_battle_count'], 0)

        self.player.refresh_from_db()
        self.assertEqual(self.player.battle.daily_battle_count, 0)
        self.assertEqual(self.player.battle.daily_battle_count_date, timezone.localdate())

    def test_L3_home_bootstrap_resets_stale_battle_count_for_ui_gate(self):
        """daily_battle_count=10, date=昨日 → /home/ の player は 0 を返す。"""
        yesterday = timezone.localdate() - datetime.timedelta(days=1)
        battle = self.player.battle
        battle.daily_battle_count = DAILY_BATTLE_LIMIT
        battle.daily_battle_count_date = yesterday
        battle.save(update_fields=['daily_battle_count', 'daily_battle_count_date'])

        res = self.client.get(reverse('home-bootstrap'))
        self.assertEqual(res.status_code, 200, res.content)
        self.assertEqual(res.data['player']['daily_battle_count'], 0)

        self.player.refresh_from_db()
        self.assertEqual(self.player.battle.daily_battle_count, 0)
        self.assertEqual(self.player.battle.daily_battle_count_date, timezone.localdate())


# ─────────────────────────────────────────────────────────────────────────────
# battle_charges 取り消し対称化 HTTP テスト (M-P)
# ─────────────────────────────────────────────────────────────────────────────

@override_settings(REST_FRAMEWORK=_TEST_RF_OVERRIDE)
class BattleChargesSymmetryTest(APITestCase):
    """HabitCountView plus/minus の battle_charges_awarded フラグ管理 4 シナリオ。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('charges_sym_user', email='cs@t.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='ChargesTest', battle_charges=0,
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        self.habit = Habit.objects.create(
            player=self.player,
            name='テスト習慣',
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

    def _minus(self):
        return self.client.post(
            reverse('habit-count', args=[self.habit.pk]),
            data={'action': 'minus'}, format='json',
        )

    def _log(self):
        return HabitLog.objects.filter(
            habit=self.habit, date=timezone.localdate(),
        ).first()

    # 【FEAT-478 Phase 2b (2026-07-04)】write path が player.battle
    # (PlayerBattleState) 経由に統一されたため、テストの読み書きも proxy 経由に統一。

    # M: 達成 → 取り消し で battle_charges 対称デクリメント
    def test_M_plus_minus_symmetric_decrement(self):
        """charges=0 → plus → charges=1, flag=True → minus → charges=0, flag=False。"""
        res_plus = self._plus()
        self.assertEqual(res_plus.status_code, 200)
        # 【2026-07-25 P3 #1-c】refresh_from_db() で shim state cache invalidate
        self.player.refresh_from_db()
        self.assertEqual(self.player.battle.battle_charges, 1)

        log = self._log()
        self.assertIsNotNone(log)
        self.assertTrue(log.battle_charges_awarded)

        res_minus = self._minus()
        self.assertEqual(res_minus.status_code, 200)
        self.player.refresh_from_db()
        self.assertEqual(self.player.battle.battle_charges, 0, 'minus でバグ修正: charges が 0 に戻る')
        log.refresh_from_db()
        self.assertFalse(log.battle_charges_awarded)

    # N: 達成 → 取り消し → 再達成 で +1 のみ (+2 にならない)
    def test_N_plus_minus_plus_no_double_increment(self):
        """charges=0 → plus → minus → plus → charges=1 (バグ修正: 旧は 2 になっていた)。"""
        self._plus()
        self._minus()
        self._plus()

        self.player.refresh_from_db()
        self.assertEqual(
            self.player.battle.battle_charges, 1,
            '取り消し → 再達成 で charges=1 のみ (旧バグでは 2 になっていた)',
        )

    # O: charges=30 上限で達成 → 取り消し で charges 維持 (フラグ False 保証)
    # 【FEAT-410】上限 3 → 30 (10 戦分ストック、daily 上限と整合)
    def test_O_at_max_charges_no_decrement_on_minus(self):
        """charges=30 (FEAT-410 上限) + date=today → plus → charges=30 維持、flag=False → minus → 維持。

        battle_charges_date=today を事前設定しないと、リセット (null → 0) が発火して
        charges が 0 に戻ってしまうため、同日フラグとして today を設定する。
        """
        from django.utils import timezone
        today = timezone.localdate()
        battle = self.player.battle
        battle.battle_charges = 30
        battle.battle_charges_date = today  # 【FEAT-406】リセット防止: 同日設定
        battle.save(update_fields=['battle_charges', 'battle_charges_date'])

        self._plus()
        self.assertEqual(self.player.battle.battle_charges, 30, '上限 30 は超えない (FEAT-410)')

        log = self._log()
        self.assertIsNotNone(log)
        self.assertFalse(log.battle_charges_awarded, '上限で加算されなかった記録 → False')

        self._minus()
        self.assertEqual(self.player.battle.battle_charges, 30, 'フラグ False のため -1 されない (健全)')

    # P: 戦闘消費後の取り消し → charges 不変 (max 0 ガード)
    def test_P_battle_consumed_then_minus_guards_at_zero(self):
        """charges=3, flag=True → 戦闘消費 (mock で -3) → minus → max(0, 0-1)=0, flag=False。"""
        # まず plus で flag True にする
        self._plus()  # charges=1, flag=True
        self._plus()  # charges=2, flag=True (2 つ目ログ or 同 log 2 カウント)
        self._plus()  # charges=3, flag=True

        # 戦闘消費を直接 DB で模倣 (-3)
        battle = self.player.battle
        battle.battle_charges = max(0, battle.battle_charges - 3)
        battle.save(update_fields=['battle_charges'])

        # この時点で charges=0、log の flag は True のまま
        self.assertEqual(self.player.battle.battle_charges, 0)

        log = self._log()
        self.assertTrue(log.battle_charges_awarded)

        # minus 実行 → max(0, 0-1)=0 で停止、flag=False
        self._minus()
        self.assertEqual(self.player.battle.battle_charges, 0, 'max(0, ...) ガードで 0 以下にならない')
        log.refresh_from_db()
        self.assertFalse(log.battle_charges_awarded)
