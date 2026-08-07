"""【FEAT-241】HabitCountView の体系的 API integration test。

3 経路 × 4 難易度 × 11 カテゴリ + 境界条件をカバーし、Sabiowl のコアフロー
（習慣達成 → EXP / stat 分散 / streak / coins）の中心ロジックを CI で保護する。

カバレッジ目標:
    - plus 経路    × 4 難易度 × 11 カテゴリ = 44 subtests
    - minus 経路   × 4 難易度 × 11 カテゴリ = 44 subtests
    - auto-shield 経路 × 11 カテゴリ          = 11 subtests
    - 境界条件（level-up / streak / stat 分散 / diamond / HabitRewardLog） 計 7+ 単独テスト
    - 計 99+ subtests ≈ FEAT-241 instruction の最小ターゲット
"""
import unittest
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.utils import timezone
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.constants import GameBalance
from api.models import (
    CharacterStat, Habit, HabitLog, HabitRewardLog, PlayerProfile, RestDay,
)
from api.services.exp_service import create_default_stats

User = get_user_model()

# 11 カテゴリ（Habit.CATEGORY_CHOICES と完全同期、constants.CATEGORY_STAT_MAP の key 集合）
_CATEGORIES = [
    '運動', '学習', '仕事', '体力', '美容', '健康',
    '精神', '創造', '社交', '休息', 'その他',
]
# 4 難易度
_DIFFICULTIES = ['easy', 'normal', 'hard', 'legendary']
# 【FEAT-434 (2026-06-14)】Habit (count/checklist) の EXP は difficulty を参照しない
# (calc_habit_base_exp = 10 + (streak // 30) * 3、新規 habit は streak=0 → 常に 10)。
# difficulty は ToDo (habit_type='todo') 経路のみ意味を持つ (calc_exp_gain、
# test_habit_exp_new_table.py S6 で検証)。
_HABIT_BASE_EXP_AT_ZERO_STREAK = 10


# ── REST_FRAMEWORK throttle を緩めて 100+ subtests を 1 メソッド内で回せるようにする ──
# 旧設定: 'habit_action': 120/hour, 'user': 300/hour。subTest が 44 回 + 累積で
# テスト全体は 200 件超を 1 ユーザー identity で叩くため、テストフラグで実質無効化する。
_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'api.authentication.ExpiringTokenAuthentication',
        'api.authentication.GuestTokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_THROTTLE_CLASSES': [],   # throttle 完全 OFF
    'DEFAULT_THROTTLE_RATES': {},
}


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class HabitCountViewTestCase(APITestCase):
    """HabitCountView の plus / minus / auto-shield + 境界条件統合テスト。"""

    def setUp(self):
        cache.clear()  # throttle カウンタを念のためクリア（throttle OFF 設定と二重保険）
        self.user = User.objects.create_user(username='tester', password='password')
        # 【FEAT-241】player.level=20 で Legendary 解禁条件（LEGENDARY_UNLOCK_LEVEL=20）を満たす。
        # max_exp=10000 で 1 リクエストで level-up しないようゆとりを取る（個別 level-up
        # テストは別メソッドで current_exp を上げて検証）。
        self.player = PlayerProfile.objects.create(
            user=self.user,
            level=20,
            max_exp=10000,
            mode='training',  # diamond 付与経路をデフォルトに（adventure 経路は専用テストで切替）
            last_login_diamond_at=timezone.localdate(),  # Day 1 +500 diamond ボーナスを抑制
        )
        # stat bonus / 分散按分のため初期 6 stat を作成
        create_default_stats(self.player)
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    # ─────────────────────────────────────────────────────────────────────
    # ヘルパー
    # ─────────────────────────────────────────────────────────────────────

    def _create_habit(self, category='運動', difficulty='normal', habit_type='count'):
        return Habit.objects.create(
            player=self.player,
            name=f'h_{category}_{difficulty}_{habit_type}',
            category=category,
            difficulty=difficulty,
            habit_type=habit_type,
            frequency='daily',
            reset_cycle='daily',
        )

    def _post_count(self, habit_pk: int, action: str):
        return self.client.post(
            f'/api/habits/{habit_pk}/count/',
            {'action': action},
            format='json',
        )

    # ─────────────────────────────────────────────────────────────────────
    # plus 経路: 4 難易度 × 11 カテゴリ = 44 subtests
    # ─────────────────────────────────────────────────────────────────────

    def test_plus_exp_gain_by_difficulty_and_category(self):
        """plus 経路で全 4 難易度 × 11 カテゴリ、streak=0 の新規 Habit は常に base EXP=10。

        【FEAT-434 (2026-06-14)】Habit (count/checklist) の EXP は difficulty を
        参照しない（calc_habit_base_exp）。本テストは「difficulty に関わらず
        base EXP が一定」であることを 44 通りの組み合わせで確認する不変条件テスト。
        """
        for difficulty in _DIFFICULTIES:
            for category in _CATEGORIES:
                with self.subTest(difficulty=difficulty, category=category):
                    self.player.refresh_from_db()
                    # 【FEAT-398 対応】日次スロットルカウンタをリセット。
                    # 44 件 subTest が同一 player を使うため 25 件目で throttle が発火する。
                    # 各 subTest は独立した「1 件の達成」シナリオなので、カウンタをリセットして
                    # スロットルなし状態で EXP 精度を確認する。
                    self.player.daily_exp_count = 0
                    self.player.daily_exp_count_date = None
                    self.player.save(update_fields=['daily_exp_count', 'daily_exp_count_date'])
                    initial_exp = self.player.current_exp
                    habit = self._create_habit(category=category, difficulty=difficulty)

                    res = self._post_count(habit.pk, 'plus')
                    self.assertEqual(
                        res.status_code, http_status.HTTP_200_OK,
                        f'{difficulty}/{category}: response={res.status_code} body={res.data}',
                    )

                    # exp_gain は streak=0 → base 10（difficulty に依存しない）
                    expected_base = _HABIT_BASE_EXP_AT_ZERO_STREAK
                    self.assertEqual(
                        res.data['exp_gain'], expected_base,
                        f'{difficulty}/{category}: exp_gain={res.data["exp_gain"]} != base {expected_base}',
                    )
                    # bonus_exp は 0 以上の整数（stat Lv.1 ベースなので bonus = round(base * 0.05) ≒ 0〜1）
                    self.assertGreaterEqual(res.data['bonus_exp'], 0)

                    # player.current_exp の増分 == base + bonus
                    self.player.refresh_from_db()
                    delta = self.player.current_exp - initial_exp
                    expected_delta = res.data['exp_gain'] + res.data['bonus_exp']
                    self.assertEqual(
                        delta, expected_delta,
                        f'{difficulty}/{category}: actual delta={delta} != expected {expected_delta}',
                    )

                    # HabitLog が作成され count=1 / exp_gained=base
                    log = HabitLog.objects.get(habit=habit, date=timezone.localdate())
                    self.assertEqual(log.count, 1)
                    self.assertEqual(log.exp_gained, expected_base)

    # ─────────────────────────────────────────────────────────────────────
    # minus 経路: 4 難易度 × 11 カテゴリ = 44 subtests
    # ─────────────────────────────────────────────────────────────────────

    def test_minus_subtracts_exp_after_plus(self):
        """plus → minus で EXP が元に戻り、HabitLog.count が 0 に減ること。"""
        for difficulty in _DIFFICULTIES:
            for category in _CATEGORIES:
                with self.subTest(difficulty=difficulty, category=category):
                    self.player.refresh_from_db()
                    initial_exp = self.player.current_exp
                    habit = self._create_habit(category=category, difficulty=difficulty)

                    # +1
                    plus_res = self._post_count(habit.pk, 'plus')
                    self.assertEqual(plus_res.status_code, http_status.HTTP_200_OK)
                    # -1
                    minus_res = self._post_count(habit.pk, 'minus')
                    self.assertEqual(
                        minus_res.status_code, http_status.HTTP_200_OK,
                        f'{difficulty}/{category}: minus failed body={minus_res.data}',
                    )

                    # minus 経路は exp_gain=0 / bonus_exp は revoke 量（plus と対称）
                    self.assertEqual(minus_res.data['exp_gain'], 0)

                    # player.current_exp は初期値に戻っている
                    self.player.refresh_from_db()
                    self.assertEqual(
                        self.player.current_exp, initial_exp,
                        f'{difficulty}/{category}: current_exp={self.player.current_exp} != initial {initial_exp}',
                    )

                    # HabitLog.count = 0 / exp_gained = 0
                    log = HabitLog.objects.get(habit=habit, date=timezone.localdate())
                    self.assertEqual(log.count, 0)
                    self.assertEqual(log.exp_gained, 0)

    # ─────────────────────────────────────────────────────────────────────
    # auto-shield 経路: 11 カテゴリ
    # ─────────────────────────────────────────────────────────────────────

    @unittest.skip('FEAT-424 で廃止、v1.2 で削除予定')
    def test_auto_shield_consumes_rest_fruit_on_yesterday_skip(self):
        """昨日未達成 + rest_fruits > 0 → 自動シールド発火、rest_fruits -= 1 + RestDay 作成。"""
        for category in _CATEGORIES:
            with self.subTest(category=category):
                # 各 subTest 用に状態をリセット（rest_fruits + 昨日の状態）
                today = timezone.localdate()
                yesterday = today - timedelta(days=1)
                # 既存の自動シールド痕跡 (RestDay / HabitLog) をクリア
                RestDay.objects.filter(player=self.player, date=yesterday).delete()
                HabitLog.objects.filter(habit__player=self.player, date=yesterday).delete()
                HabitLog.objects.filter(habit__player=self.player, date=today).delete()

                self.player.refresh_from_db()
                self.player.rest_fruits = 3
                self.player.save(update_fields=['rest_fruits'])

                habit = self._create_habit(category=category, difficulty='easy')

                res = self._post_count(habit.pk, 'plus')
                self.assertEqual(
                    res.status_code, http_status.HTTP_200_OK,
                    f'{category}: status={res.status_code} body={res.data}',
                )

                # 自動シールドが発火している
                self.assertEqual(
                    res.data['auto_shield_type'], 'fruit',
                    f'{category}: auto_shield_type={res.data["auto_shield_type"]} != "fruit"',
                )

                # rest_fruits が 3 → 2 に減少
                self.player.refresh_from_db()
                self.assertEqual(
                    self.player.rest_fruits, 2,
                    f'{category}: rest_fruits={self.player.rest_fruits} != 2',
                )

                # 昨日付の RestDay が used_fruit=True で作成されている
                rd = RestDay.objects.get(player=self.player, date=yesterday)
                self.assertTrue(
                    rd.used_fruit,
                    f'{category}: RestDay.used_fruit={rd.used_fruit}',
                )

    # ─────────────────────────────────────────────────────────────────────
    # 境界条件: レベルアップ跨ぎ
    # ─────────────────────────────────────────────────────────────────────

    def test_plus_triggers_level_up_when_exp_overflows(self):
        """current_exp が max_exp 直前で plus → level += 1 + allocatable_points += 10。"""
        self.player.current_exp = self.player.max_exp - 5   # あと 5 EXP で level-up
        self.player.allocatable_points = 0
        self.player.save(update_fields=['current_exp', 'allocatable_points'])

        habit = self._create_habit(category='運動', difficulty='hard')  # base 40 EXP
        res = self._post_count(habit.pk, 'plus')
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)

        self.player.refresh_from_db()
        self.assertEqual(
            self.player.level, 21,
            f'level={self.player.level} != 21 after overflow',
        )
        # level-up で +10pt 加算（GameBalance.ALLOCATABLE_POINTS_HABIT、FEAT-285）
        self.assertEqual(
            self.player.allocatable_points, 10,
            f'allocatable_points={self.player.allocatable_points} != 10',
        )
        # 【FEAT-319】max_exp = level * 70 + 30 = 21 * 70 + 30 = 1500 にリセット
        # 旧式 level * 100 = 2100 から調整 (UX 体感「少し多く感じる」改善)。
        from api.constants import GameBalance
        self.assertEqual(self.player.max_exp, GameBalance.level_to_max_exp(21))

    # ─────────────────────────────────────────────────────────────────────
    # 境界条件: ストリーク連続更新
    # ─────────────────────────────────────────────────────────────────────

    def test_streak_increments_when_yesterday_done(self):
        """昨日「いずれかの習慣」を達成済み → 今日 plus で streak = 1（新規）または +1（既存）。"""
        today = timezone.localdate()
        yesterday = today - timedelta(days=1)

        # 別の habit で昨日達成済みログを作る（any_activity_yesterday=True 経路）
        prev_habit = self._create_habit(category='学習', difficulty='easy')
        HabitLog.objects.create(habit=prev_habit, date=yesterday, count=1, exp_gained=20)

        # 今日カウントする習慣（streak=5 から +1 されることを検証）
        habit = self._create_habit(category='運動', difficulty='normal')
        habit.streak = 5
        habit.best_streak = 5
        habit.save(update_fields=['streak', 'best_streak'])

        res = self._post_count(habit.pk, 'plus')
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)

        habit.refresh_from_db()
        self.assertEqual(
            habit.streak, 6,
            f'streak={habit.streak} != 6 (5+1 expected via any_activity_yesterday)',
        )
        self.assertEqual(habit.best_streak, 6)

    def test_streak_resets_when_yesterday_skipped(self):
        """昨日達成なし & rest_day なし & rest_fruit なし → streak = 1 にリセット。"""
        # rest_fruits = 0 にして auto-shield を無効化
        self.player.rest_fruits = 0
        self.player.save(update_fields=['rest_fruits'])

        habit = self._create_habit(category='運動', difficulty='normal')
        habit.streak = 10
        habit.best_streak = 10
        habit.save(update_fields=['streak', 'best_streak'])

        res = self._post_count(habit.pk, 'plus')
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)

        habit.refresh_from_db()
        # 昨日達成なし + シールドなし → streak は 1 にリセット
        self.assertEqual(
            habit.streak, 1,
            f'streak={habit.streak} != 1 (reset expected)',
        )
        # best_streak は維持（max(1, 10) = 10）
        self.assertEqual(habit.best_streak, 10)

    # ─────────────────────────────────────────────────────────────────────
    # stat 分散按分（FEAT-213 / FEAT-223 整合）
    # ─────────────────────────────────────────────────────────────────────

    def test_stat_bonus_exp_is_added_for_mapped_category(self):
        """stat Lv.1 でも bonus_exp が 0 以上の整数で返り、player に加算される。

        【FEAT-434 (2026-06-14)】streak=0 の新規 Habit は base=10。
        Lv.1 stat の重み付きレベル = 1.0 → bonus = round(10 * min(1.0 * 0.05, 0.50))
        = round(0.5) = 0（Python の banker's rounding）。
        '体力' (運動 0.5 + 健康 0.5) のような分散カテゴリも重み付き平均 = 1.0 で同じ。
        """
        # 単一マッピング: '運動' → 運動力 1.0
        h_single = self._create_habit(category='運動', difficulty='easy')
        res = self._post_count(h_single.pk, 'plus')
        self.assertEqual(res.data['exp_gain'], 10)
        self.assertEqual(res.data['bonus_exp'], 0)

        # 分散マッピング: '体力' → 運動力 0.5 + 健康力 0.5
        # 重み付きレベル = 1.0*0.5 + 1.0*0.5 = 1.0 → bonus = round(10 * 0.05) = 0
        h_dual = self._create_habit(category='体力', difficulty='easy')
        res2 = self._post_count(h_dual.pk, 'plus')
        self.assertEqual(res2.data['exp_gain'], 10)
        self.assertEqual(res2.data['bonus_exp'], 0)

    # ─────────────────────────────────────────────────────────────────────
    # diamond 付与 (training mode) / adventure bonus
    # ─────────────────────────────────────────────────────────────────────

    def test_diamond_awarded_on_first_plus_today_in_training_mode(self):
        """training mode + 今日初の plus → diamond +1 + HabitRewardLog.diamond_delta=1。"""
        self.player.diamonds = 0
        self.player.diamonds_total = 0
        self.player.diamond_bonus_date = None
        self.player.mode = 'training'
        self.player.save(update_fields=['diamonds', 'diamonds_total', 'diamond_bonus_date', 'mode'])

        habit = self._create_habit(category='運動', difficulty='easy')
        res = self._post_count(habit.pk, 'plus')
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)
        self.assertTrue(
            res.data['diamond_earned'],
            f'diamond_earned={res.data["diamond_earned"]} expected True',
        )

        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 1)
        self.assertEqual(self.player.diamonds_total, 1)
        self.assertEqual(self.player.diamond_bonus_date, timezone.localdate())

        # HabitRewardLog に diamond_delta=1 で記録されている
        log = HabitRewardLog.objects.filter(habit=habit, action=HabitRewardLog.ACTION_PLUS).first()
        self.assertIsNotNone(log)
        self.assertEqual(log.diamond_delta, 1)
        # exp_delta = base + bonus
        self.assertEqual(log.exp_delta, res.data['exp_gain'] + res.data['bonus_exp'])

    def test_no_diamond_in_adventure_mode_but_bonus_exp_increased(self):
        """adventure mode + plus → diamond_earned=False、bonus_exp に adventure +20% 加算。"""
        self.player.diamonds = 0
        self.player.diamond_bonus_date = None
        self.player.mode = 'adventure'
        self.player.save(update_fields=['diamonds', 'diamond_bonus_date', 'mode'])

        habit = self._create_habit(category='運動', difficulty='easy')
        res = self._post_count(habit.pk, 'plus')
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)
        self.assertFalse(
            res.data['diamond_earned'],
            f'adventure mode で diamond_earned={res.data["diamond_earned"]} expected False',
        )

        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 0)

        # 【FEAT-434 (2026-06-14)】base=10 (streak=0)。
        # bonus_exp = stat bonus (Lv.1 → round(10*0.05)=0) + adventure bonus
        # (round(10 * 0.20)=2) = 2。adventure 加算は GameBalance.ADVENTURE_EXP_BONUS_RATE（FEAT-285）
        self.assertEqual(
            res.data['bonus_exp'], 0 + 2,
            f'bonus_exp={res.data["bonus_exp"]} != stat(0) + adventure(2)',
        )

    # ─────────────────────────────────────────────────────────────────────
    # minus 冪等性（BUG-2026-01）
    # ─────────────────────────────────────────────────────────────────────

    def test_minus_is_idempotent_when_no_log_exists(self):
        """count=0 の状態で minus 連打しても EXP / streak が削られない（BUG-2026-01）。"""
        self.player.current_exp = 100
        self.player.save(update_fields=['current_exp'])

        habit = self._create_habit(category='運動', difficulty='normal')
        habit.streak = 5
        habit.total_count = 5
        habit.total_exp = 150
        habit.save(update_fields=['streak', 'total_count', 'total_exp'])

        # 達成していない状態で minus を 3 連打
        for _ in range(3):
            res = self._post_count(habit.pk, 'minus')
            self.assertEqual(res.status_code, http_status.HTTP_200_OK)
            self.assertEqual(res.data['exp_gain'], 0)
            self.assertEqual(res.data['bonus_exp'], 0)

        # player.current_exp 不変 / habit.streak / total_count / total_exp 不変
        self.player.refresh_from_db()
        habit.refresh_from_db()
        self.assertEqual(self.player.current_exp, 100)
        self.assertEqual(habit.streak, 5)
        self.assertEqual(habit.total_count, 5)
        self.assertEqual(habit.total_exp, 150)
        # HabitRewardLog も作成されない
        self.assertFalse(
            HabitRewardLog.objects.filter(habit=habit, action=HabitRewardLog.ACTION_MINUS).exists(),
            'BUG-2026-01: 早期 return 経路で HabitRewardLog が作成されてはいけない',
        )

    # ─────────────────────────────────────────────────────────────────────
    # auto-allocations（レベルアップ時の 10pt 達成比率連動配分）
    # ─────────────────────────────────────────────────────────────────────

    def test_auto_allocations_returned_on_level_up(self):
        """レベルアップ時に auto_allocations が `{stat名: pts}` で返る。"""
        # plus 直前で level-up 状態を作る
        self.player.current_exp = self.player.max_exp - 5
        self.player.save(update_fields=['current_exp'])

        habit = self._create_habit(category='運動', difficulty='hard')
        # 過去 30 日に達成ログを 1 件作る（_auto_allocate_by_ratio の分母を満たす）
        HabitLog.objects.create(habit=habit, date=timezone.localdate() - timedelta(days=2), count=1, exp_gained=40)

        res = self._post_count(habit.pk, 'plus')
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)
        # auto_allocations が dict で返り、配分先 stat 名のキーが存在する
        self.assertIsInstance(res.data['auto_allocations'], dict)
        self.assertGreater(
            len(res.data['auto_allocations']), 0,
            f'level-up したのに auto_allocations が空: {res.data["auto_allocations"]}',
        )
        # 運動カテゴリのみなので '運動力' に配分されている
        self.assertIn('運動力', res.data['auto_allocations'])
