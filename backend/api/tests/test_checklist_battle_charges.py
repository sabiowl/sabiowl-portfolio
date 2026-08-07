"""【BUG-96 (2026-06-12)】checklist 経路の battle_charges 加算 + 対称化契約テスト。"""
import datetime

from django.contrib.auth.models import User
from django.test import TestCase
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from api.models import ChecklistItem, Habit, PlayerProfile


class ChecklistBattleChargesTest(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(username='t96', password='p')
        self.player = PlayerProfile.objects.create(user=self.user, name='T')
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client = APIClient()
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        self.habit = Habit.objects.create(
            player=self.player, name='gym', habit_type='checklist',
            difficulty='normal', frequency='daily', category='運動',
        )
        self.items = [
            ChecklistItem.objects.create(habit=self.habit, text=f'item-{i}', order=i)
            for i in range(5)
        ]

    # S1: 1 個チェック = battle_charges +1
    def test_S1_single_check_increments_battle_charges(self):
        before = self.player.battle_charges
        res = self.client.post(f'/api/habits/{self.habit.pk}/checklist/{self.items[0].pk}/toggle/')
        self.assertEqual(res.status_code, 200, res.content)
        self.player.refresh_from_db()
        self.assertEqual(self.player.battle_charges, before + 1)

    # S2: 5 個チェック = +5 (上限 30 未満なら累積)
    def test_S2_five_checks_increment_by_five(self):
        for item in self.items:
            self.client.post(f'/api/habits/{self.habit.pk}/checklist/{item.pk}/toggle/')
        self.player.refresh_from_db()
        self.assertEqual(self.player.battle_charges, 5)

    # S3: チェック → 解除 = -1 対称化
    def test_S3_check_and_uncheck_is_symmetric(self):
        item = self.items[0]
        self.client.post(f'/api/habits/{self.habit.pk}/checklist/{item.pk}/toggle/')  # +1
        self.player.refresh_from_db()
        self.assertEqual(self.player.battle_charges, 1)
        self.client.post(f'/api/habits/{self.habit.pk}/checklist/{item.pk}/toggle/')  # -1
        self.player.refresh_from_db()
        self.assertEqual(self.player.battle_charges, 0)

    # S4: battle_charges 上限 30 を超えない
    def test_S4_charges_capped_at_30(self):
        self.player.battle_charges = 29
        self.player.battle_charges_date = timezone.localdate()
        self.player.save()
        self.client.post(f'/api/habits/{self.habit.pk}/checklist/{self.items[0].pk}/toggle/')  # +1 → 30
        self.client.post(f'/api/habits/{self.habit.pk}/checklist/{self.items[1].pk}/toggle/')  # +0 (上限)
        self.player.refresh_from_db()
        self.assertEqual(self.player.battle_charges, 30)

    # S5: 日次リセット (battle_charges_date != today)
    def test_S5_daily_reset_before_increment(self):
        yesterday = timezone.localdate() - datetime.timedelta(days=1)
        self.player.battle_charges = 15
        self.player.battle_charges_date = yesterday
        self.player.save()
        # チェック → 日次リセット (15→0) + 加算 (0→1)
        self.client.post(f'/api/habits/{self.habit.pk}/checklist/{self.items[0].pk}/toggle/')
        self.player.refresh_from_db()
        self.assertEqual(self.player.battle_charges, 1)
        self.assertEqual(self.player.battle_charges_date, timezone.localdate())
