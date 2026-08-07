"""【ユーザー要望 2026-06-22】Habit の UniqueConstraint から ToDo を除外した契約テスト。

旧 condition: Q(is_active=True)
新 condition: Q(is_active=True) & ~Q(habit_type='todo')

3 シナリオ (model 層 / IntegrityError レベル):
  S1. 同名 ToDo (habit_type='todo') 2 件作成 → 両方とも成功 (制約対象外)
  S2. 同名習慣 (habit_type='count') 2 件作成 → 2 件目で IntegrityError
  S3. アーカイブ済み習慣 (is_active=False) と同名のアクティブ習慣 → 成功
      (既存挙動の維持確認)

3 シナリオ (View 層 / POST /api/habits/ 経由、2026-06-23 追加):
  V1. POST /api/habits/ で同名 ToDo 2 件作成 → 両方 201 (View 層チェック除外確認)
  V2. ToDo 完了 (HabitLog 作成) 後、同名 ToDo を新規作成 → 201
      (完了済 ToDo は Habit.is_active=True のまま残るが、ToDo 除外で OK)
  V3. POST /api/habits/ で同名 count 習慣 2 件作成 → 2 件目 400
      (既存挙動の維持確認、View 層チェックがまだ機能)

対象: api.models.habits.Habit の UniqueConstraint
       'unique_active_habit_name_per_player'
+ api.views.habits.HabitListCreateView.post の View 層 exists() チェック
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.db import IntegrityError, transaction
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Habit, HabitLog, PlayerProfile

User = get_user_model()


_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
}


class HabitUniqueConstraintExcludesTodoTest(TestCase):
    """Habit UniqueConstraint の ToDo 除外契約テスト 3 件。"""

    def setUp(self):
        self.user = User.objects.create_user('p1', email='p1@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='P1')

    def test_S1_duplicate_todo_names_are_allowed(self):
        """同名の ToDo を 2 件作成できる (ID で個別管理されるため、UniqueConstraint 対象外)。"""
        todo1 = Habit.objects.create(
            player=self.player,
            name='買い物',
            category='その他',
            frequency='daily',
            habit_type='todo',
            is_active=True,
        )
        # 2 件目も IntegrityError なく作成できる
        todo2 = Habit.objects.create(
            player=self.player,
            name='買い物',  # 同じ名前
            category='その他',
            frequency='daily',
            habit_type='todo',
            is_active=True,
        )
        self.assertNotEqual(todo1.id, todo2.id, 'ID は別')
        self.assertEqual(todo1.name, todo2.name, '名前は同じで OK')

    def test_S2_duplicate_count_habit_names_are_blocked(self):
        """同名の習慣 (habit_type='count') は 2 件目で IntegrityError (既存挙動維持)。"""
        Habit.objects.create(
            player=self.player,
            name='運動',
            category='運動',
            frequency='daily',
            habit_type='count',
            is_active=True,
        )
        # 2 件目は IntegrityError でブロックされるべき
        with self.assertRaises(
            IntegrityError, msg='習慣 (count) の同名作成は制約違反になるべき',
        ):
            with transaction.atomic():
                Habit.objects.create(
                    player=self.player,
                    name='運動',  # 同名 count 習慣
                    category='運動',
                    frequency='daily',
                    habit_type='count',
                    is_active=True,
                )

    def test_S3_archived_habit_does_not_collide_with_active_one(self):
        """アーカイブ済み習慣 (is_active=False) と同名のアクティブ習慣は作成できる
        (既存の partial constraint condition `is_active=True` 動作を維持)。"""
        archived = Habit.objects.create(
            player=self.player,
            name='学習',
            category='学習',
            frequency='daily',
            habit_type='count',
            is_active=False,  # アーカイブ済み
        )
        # 同名のアクティブ習慣を作成しても collision しない
        active = Habit.objects.create(
            player=self.player,
            name='学習',  # 同名
            category='学習',
            frequency='daily',
            habit_type='count',
            is_active=True,
        )
        self.assertNotEqual(archived.id, active.id)
        self.assertFalse(archived.is_active)
        self.assertTrue(active.is_active)


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class HabitViewUniqueChecksExcludeTodoTest(APITestCase):
    """POST /api/habits/ 経由の同名チェック契約テスト 3 件 (View 層 / 2026-06-23 追加)。

    Backend は DB 層 (UniqueConstraint) と View 層 (`exists()` チェック) で
    二重防御している。前回 (migration 0155) で DB 層は ToDo を除外したが、
    View 層は未対応だった。本テストで View 層も ToDo を除外する契約を縛る。
    """

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('p1', email='p1@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='P1')
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        self.url = '/api/habits/'

    def _post_habit(self, name, habit_type='count'):
        return self.client.post(
            self.url,
            data={'name': name, 'habit_type': habit_type, 'category': 'その他'},
            format='json',
        )

    def test_V1_post_duplicate_todo_returns_201_twice(self):
        """POST /api/habits/ で同名 ToDo 2 件作成 → 両方 201 OK。"""
        res1 = self._post_habit('買い物', habit_type='todo')
        self.assertEqual(res1.status_code, 201, '1 件目 ToDo は作成成功')

        res2 = self._post_habit('買い物', habit_type='todo')
        self.assertEqual(
            res2.status_code, 201,
            '同名 ToDo 2 件目も作成成功 (View 層チェックから除外)',
        )
        # 別 ID で 2 件存在することを確認
        todos = Habit.objects.filter(
            player=self.player, name='買い物', habit_type='todo', is_active=True,
        )
        self.assertEqual(todos.count(), 2, '同名 ToDo が 2 件アクティブに存在')

    def test_V2_completed_todo_does_not_block_new_same_name_todo(self):
        """完了済み ToDo (is_active=True 維持) と同名の新規 ToDo を作成 → 201。"""
        # 1 件目作成 + 完了相当の HabitLog (Habit.is_active は True のまま維持)
        res1 = self._post_habit('掃除', habit_type='todo')
        self.assertEqual(res1.status_code, 201)
        first_id = res1.data['id']
        first_todo = Habit.objects.get(pk=first_id)
        HabitLog.objects.create(
            habit=first_todo, date=timezone.localdate(), count=1,
        )
        # 完了後も is_active は True 維持の前提を確認
        first_todo.refresh_from_db()
        self.assertTrue(first_todo.is_active, '完了済み ToDo も is_active=True')

        # 2 件目: 同名 ToDo を新規作成 → ブロックされず 201
        res2 = self._post_habit('掃除', habit_type='todo')
        self.assertEqual(
            res2.status_code, 201,
            '完了済 ToDo と同名でも新規 ToDo は作成成功',
        )

    def test_V3_duplicate_count_habit_still_returns_400(self):
        """同名 count 習慣の 2 件目は 400 を維持 (既存挙動)。"""
        res1 = self._post_habit('運動', habit_type='count')
        self.assertEqual(res1.status_code, 201, '1 件目 count 習慣は作成成功')

        res2 = self._post_habit('運動', habit_type='count')
        self.assertEqual(
            res2.status_code, 400,
            '同名 count 習慣 2 件目は 400 拒否 (既存挙動維持)',
        )
        # 【2026-07-25 P3 #1-c】FEAT-475 新エラー形式対応:
        # 旧: {'error': 'すでに登録されています'} (プレーン文字列)
        # 新: {'error': {'code': 'habit_create_duplicate_name', 'message': '...すでに登録されています...', 'fields': {...}}}
        err = res2.data.get('error', '')
        # dict の場合は新形式、str の場合は旧形式 (どちらでも通す)
        msg = err.get('message', '') if isinstance(err, dict) else err
        self.assertIn(
            'すでに登録されています', msg,
            f'エラーメッセージが返却される (実際の response: {res2.data})',
        )
