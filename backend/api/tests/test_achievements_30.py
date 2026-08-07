"""【新規 (2026-06-26)】実績 13 → 30 件への拡張の契約テスト。

検証シナリオ:
    A1: migration 0159 適用後、Achievement テーブルに 30 件以上の entry がある
    A2: 新規 17 件 (key) がすべて DB に存在
    A3: 各新 condition_type で metrics 計算 + unlock 経路が動作する
        - perfect_day_count: active 習慣すべてに log がある日数
        - active_habits: アクティブ習慣数 (ToDo 除外)
        - total_exp_earned: HabitLog.exp_gained 合計
    A4: check_achievements で新規 17 件のうち閾値到達分が unlock される
"""
from datetime import date as date_t, timedelta

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone

from api.models import (
    Achievement,
    Habit,
    HabitLog,
    PlayerAchievement,
    PlayerProfile,
)
from api.services.exp_service import create_default_stats
from api.views.achievements import check_achievements

User = get_user_model()


_EXPECTED_NEW_KEYS = {
    # 数量階梯延長
    'log_300', 'log_500', 'log_1000',
    'streak_14', 'streak_60', 'streak_100', 'streak_365',
    # Lv 階梯延長
    'level_30', 'level_50',
    # 完璧な日々
    'perfect_day_1', 'perfect_day_10', 'perfect_day_30',
    # 多彩さ
    'multi_habits_3', 'multi_habits_5',
    # 学びの累積
    'exp_1000', 'exp_5000', 'exp_20000',
    # 絆
    'friends_5',
}


class AchievementSeed30Test(TestCase):
    """A1, A2: migration 0159 で 30 件構成になっていること。"""

    def test_A1_total_count_at_least_30(self):
        count = Achievement.objects.count()
        self.assertGreaterEqual(
            count, 30,
            f'Achievement テーブルが 30 件未満 (現状 {count} 件)。'
            f'migration 0159 が未適用、または旧 seed が消失している可能性。',
        )

    def test_A2_new_keys_present(self):
        present_keys = set(
            Achievement.objects.filter(key__in=_EXPECTED_NEW_KEYS)
            .values_list('key', flat=True)
        )
        missing = _EXPECTED_NEW_KEYS - present_keys
        # 18 件 expected (streak_365 追加で 17 件 + 1)。実装上 17 件であれば missing が
        # 空集合になる調整が必要。本テストは実装と整合させる。
        self.assertEqual(
            missing, set(),
            f'migration 0159 で追加されるはずの key が見つからない: {missing}',
        )

    def test_A3_new_condition_types_in_choices(self):
        """Achievement.CONDITION_CHOICES に新 3 種が含まれる。"""
        choices = dict(Achievement._meta.get_field('condition_type').choices)
        self.assertIn('perfect_day_count', choices)
        self.assertIn('active_habits', choices)
        self.assertIn('total_exp_earned', choices)


class CheckAchievementsNewMetricsTest(TestCase):
    """A3, A4: 新 metrics で unlock が走ること。"""

    def setUp(self):
        self.user = User.objects.create_user(username='ach30', password='p')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='T', level=5, max_exp=500,
        )
        create_default_stats(self.player)

    def _create_habit(self, name, is_active=True, habit_type='count'):
        return Habit.objects.create(
            player=self.player,
            name=name,
            category='その他',
            difficulty='normal',
            habit_type=habit_type,
            frequency='daily',
            reset_cycle='daily',
            is_active=is_active,
        )

    def test_active_habits_3_unlock(self):
        """同時アクティブ習慣 3 つで multi_habits_3 unlock。"""
        for i in range(3):
            self._create_habit(f'habit_{i}')

        # 60 秒ガード回避: last_achievement_check_at を None に
        self.player.last_achievement_check_at = None
        self.player.save(update_fields=['last_achievement_check_at'])

        newly_unlocked, _ = check_achievements(self.player)
        unlocked_keys = {a.key for a in newly_unlocked}
        self.assertIn('multi_habits_3', unlocked_keys)

    def test_active_habits_excludes_todo(self):
        """todo は active_habits 集計から除外される。"""
        for i in range(2):
            self._create_habit(f'habit_{i}')  # count habit ×2
        self._create_habit('todo_only', habit_type='todo')  # ToDo ×1

        self.player.last_achievement_check_at = None
        self.player.save(update_fields=['last_achievement_check_at'])

        newly_unlocked, _ = check_achievements(self.player)
        unlocked_keys = {a.key for a in newly_unlocked}
        # active_habits = 2 (todo 除外) なので multi_habits_3 (>=3) は unlock しない
        self.assertNotIn('multi_habits_3', unlocked_keys)

    def test_perfect_day_count_unlock(self):
        """全 active 習慣に log がある日が 1 日あれば perfect_day_1 unlock。"""
        h1 = self._create_habit('habit_a')
        h2 = self._create_habit('habit_b')
        today = timezone.localdate()
        HabitLog.objects.create(habit=h1, date=today, count=1, exp_gained=10)
        HabitLog.objects.create(habit=h2, date=today, count=1, exp_gained=10)

        self.player.last_achievement_check_at = None
        self.player.save(update_fields=['last_achievement_check_at'])

        newly_unlocked, _ = check_achievements(self.player)
        unlocked_keys = {a.key for a in newly_unlocked}
        self.assertIn('perfect_day_1', unlocked_keys)

    def test_perfect_day_not_counted_when_one_habit_missing(self):
        """1 つでも未達の習慣があるとその日は perfect_day にカウントされない。"""
        h1 = self._create_habit('habit_a')
        h2 = self._create_habit('habit_b')
        today = timezone.localdate()
        HabitLog.objects.create(habit=h1, date=today, count=1, exp_gained=10)
        # h2 の log は作らない → 当日は perfect ではない

        self.player.last_achievement_check_at = None
        self.player.save(update_fields=['last_achievement_check_at'])

        newly_unlocked, _ = check_achievements(self.player)
        unlocked_keys = {a.key for a in newly_unlocked}
        self.assertNotIn('perfect_day_1', unlocked_keys)

    def test_total_exp_earned_unlock(self):
        """累計 EXP 1000 で exp_1000 unlock。"""
        h1 = self._create_habit('habit_a')
        today = timezone.localdate()
        # 10 件 × 100 EXP = 1000 EXP
        for i in range(10):
            HabitLog.objects.create(
                habit=h1,
                date=today - timedelta(days=i),
                count=1,
                exp_gained=100,
            )

        self.player.last_achievement_check_at = None
        self.player.save(update_fields=['last_achievement_check_at'])

        newly_unlocked, _ = check_achievements(self.player)
        unlocked_keys = {a.key for a in newly_unlocked}
        self.assertIn('exp_1000', unlocked_keys)
        # 5000 未達なので exp_5000 は unlock しない
        self.assertNotIn('exp_5000', unlocked_keys)

    def test_no_double_unlock(self):
        """同じ achievement が二重 unlock されない (PlayerAchievement unique 制約 +
        already_unlocked filter 経路)。"""
        for _ in range(3):
            self._create_habit(f'h{_}')
        self.player.last_achievement_check_at = None
        self.player.save(update_fields=['last_achievement_check_at'])

        check_achievements(self.player)
        # 60 秒ガード回避のため再度 None に
        self.player.last_achievement_check_at = None
        self.player.save(update_fields=['last_achievement_check_at'])
        second, _ = check_achievements(self.player)
        # 2 回目は既 unlock なので newly_unlocked は空
        keys = {a.key for a in second}
        self.assertNotIn('multi_habits_3', keys)
        # multi_habits_3 は PlayerAchievement に 1 件のみ存在
        pa_count = PlayerAchievement.objects.filter(
            player=self.player, achievement__key='multi_habits_3',
        ).count()
        self.assertEqual(pa_count, 1)
