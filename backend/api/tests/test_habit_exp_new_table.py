"""【FEAT-434 (2026-06-14)】EXP システム再設計 v1.0 の契約テスト。

Habit (count/checklist) の EXP は旧 `calc_exp_gain` (難易度倍率方式) を廃止し、
継続日数 (`habit.streak`) ベースの新テーブル `calc_habit_base_exp` に置換した。

式: `10 + min(habit.streak // 30, 12) * 3` (上限 46、365 日継続で到達)。

検証対象 (6 シナリオ):
    S1: Habit (count) streak=0   → +1 達成 → EXP +10
    S2: Habit (count) streak=30  → +1 達成 → EXP +13
    S3: Habit (count) streak=365 → +1 達成 → EXP +46 (上限)
    S4: Habit (count) streak=400 → +1 達成 → EXP +46 (上限超え、min でクランプ)
    S5: Habit (checklist) item check → EXP +10 (BUG-96 と整合、count と同じテーブル)
    S6: ToDo (difficulty=legendary) 完了 → EXP +150 (既存テーブル維持確認)

Note: `calc_habit_base_exp` は `habit.streak` (達成 *前* の値) を参照する
(`habit_count_service.apply_count_change` で streak 更新前に base_exp を計算)。
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import ChecklistItem, Habit, PlayerProfile
from api.services.exp_service import create_default_stats

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


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class HabitExpNewTableTest(APITestCase):
    """FEAT-434 calc_habit_base_exp の契約テスト。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(username='exp_table_tester', password='pw')
        self.player = PlayerProfile.objects.create(
            user=self.user, level=1, max_exp=10000, mode='training',
        )
        create_default_stats(self.player)
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    # ─────────────────────────────────────────────────────────────────
    # S1: streak=0 → +1 達成 → EXP +10
    # ─────────────────────────────────────────────────────────────────
    def test_S1_count_streak_0_gives_10_exp(self):
        habit = Habit.objects.create(
            player=self.player, name='習慣 streak0', category='その他',
            difficulty='normal', habit_type='count',
            frequency='daily', reset_cycle='daily', streak=0,
        )
        res = self.client.post(f'/api/habits/{habit.pk}/count/', {'action': 'plus'}, format='json')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertEqual(res.data['exp_gain'], 10)

    # ─────────────────────────────────────────────────────────────────
    # S2: streak=30 → +1 達成 → EXP +13 (10 + 1*3)
    # ─────────────────────────────────────────────────────────────────
    def test_S2_count_streak_30_gives_13_exp(self):
        habit = Habit.objects.create(
            player=self.player, name='習慣 streak30', category='その他',
            difficulty='normal', habit_type='count',
            frequency='daily', reset_cycle='daily', streak=30,
        )
        res = self.client.post(f'/api/habits/{habit.pk}/count/', {'action': 'plus'}, format='json')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertEqual(res.data['exp_gain'], 13)

    # ─────────────────────────────────────────────────────────────────
    # S3: streak=365 → +1 達成 → EXP +46 (上限、10 + 12*3)
    # ─────────────────────────────────────────────────────────────────
    def test_S3_count_streak_365_gives_46_exp(self):
        habit = Habit.objects.create(
            player=self.player, name='習慣 streak365', category='その他',
            difficulty='normal', habit_type='count',
            frequency='daily', reset_cycle='daily', streak=365,
        )
        res = self.client.post(f'/api/habits/{habit.pk}/count/', {'action': 'plus'}, format='json')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertEqual(res.data['exp_gain'], 46)

    # ─────────────────────────────────────────────────────────────────
    # S4: streak=400 → +1 達成 → EXP +46 (上限超え、min でクランプ)
    # ─────────────────────────────────────────────────────────────────
    def test_S4_count_streak_400_clamped_to_46_exp(self):
        habit = Habit.objects.create(
            player=self.player, name='習慣 streak400', category='その他',
            difficulty='normal', habit_type='count',
            frequency='daily', reset_cycle='daily', streak=400,
        )
        res = self.client.post(f'/api/habits/{habit.pk}/count/', {'action': 'plus'}, format='json')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertEqual(res.data['exp_gain'], 46)

    # ─────────────────────────────────────────────────────────────────
    # S5: checklist item check → EXP +10 (BUG-96 と整合、count と同じテーブル)
    # ─────────────────────────────────────────────────────────────────
    def test_S5_checklist_streak_0_gives_10_exp(self):
        habit = Habit.objects.create(
            player=self.player, name='習慣 checklist', category='その他',
            difficulty='normal', habit_type='checklist',
            frequency='daily', reset_cycle='daily', streak=0,
        )
        item = ChecklistItem.objects.create(habit=habit, text='item1')
        res = self.client.post(
            f'/api/habits/{habit.pk}/checklist/{item.pk}/toggle/', format='json',
        )
        self.assertEqual(res.status_code, 200, res.content)
        self.assertEqual(res.data['exp_gain'], 10)

    # ─────────────────────────────────────────────────────────────────
    # S6: ToDo (difficulty=legendary) 完了 → EXP +150 (既存テーブル維持確認)
    # ─────────────────────────────────────────────────────────────────
    def test_S6_todo_legendary_gives_150_exp(self):
        habit = Habit.objects.create(
            player=self.player, name='ToDo legendary', category='その他',
            difficulty='legendary', habit_type='todo',
            frequency='daily', reset_cycle='daily',
        )
        res = self.client.post(f'/api/habits/{habit.pk}/count/', {'action': 'plus'}, format='json')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertEqual(res.data['exp_gain'], 150)
