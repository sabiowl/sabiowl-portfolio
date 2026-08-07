"""【FEAT-467 (2026-07-02)】TaskSuggestion API テスト。"""
from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from api.models import GuestSession, PlayerProfile, TaskSuggestion

User = get_user_model()


class TaskSuggestionListViewTests(TestCase):
    def setUp(self):
        self.client = APIClient()

        # Seed a few active TaskSuggestion rows
        TaskSuggestion.objects.create(type='event', title='ランニング', category='運動', order=0)
        TaskSuggestion.objects.create(type='event', title='読書', category='学習', order=1)
        TaskSuggestion.objects.create(type='todo', title='買い物リスト', category='その他', order=0)
        TaskSuggestion.objects.create(type='habit', title='瞑想', category='精神', order=0)
        # inactive — must not appear
        TaskSuggestion.objects.create(type='event', title='非表示イベント', is_active=False, order=99)

        # Authenticated user — manually create PlayerProfile (no signal in test env)
        self.user = User.objects.create_user(username='tester@example.com', password='pw')
        self.player = PlayerProfile.objects.create(user=self.user, name='テスター')
        token, _ = Token.objects.get_or_create(user=self.user)
        self.token = token.key

    def _auth(self):
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token}')

    # ── Test 1: type=event でアクティブ候補を返す ────────────────────────────
    def test_list_event_returns_active_items(self):
        self._auth()
        res = self.client.get('/api/task-suggestions/?type=event')
        self.assertEqual(res.status_code, 200)
        titles = [item['title'] for item in res.data]
        self.assertIn('ランニング', titles)
        self.assertIn('読書', titles)
        # inactive must not appear
        self.assertNotIn('非表示イベント', titles)

    # ── Test 2: type フィルターが機能する ───────────────────────────────────
    def test_type_filter_isolates_categories(self):
        self._auth()
        res_todo = self.client.get('/api/task-suggestions/?type=todo')
        self.assertEqual(res_todo.status_code, 200)
        titles = [item['title'] for item in res_todo.data]
        self.assertIn('買い物リスト', titles)
        self.assertNotIn('ランニング', titles)

        res_habit = self.client.get('/api/task-suggestions/?type=habit')
        self.assertEqual(res_habit.status_code, 200)
        habit_titles = [item['title'] for item in res_habit.data]
        self.assertIn('瞑想', habit_titles)
        self.assertNotIn('買い物リスト', habit_titles)

    # ── Test 3: is_active=False のエントリは除外される ──────────────────────
    def test_inactive_entries_excluded(self):
        self._auth()
        res = self.client.get('/api/task-suggestions/?type=event')
        self.assertEqual(res.status_code, 200)
        titles = [item['title'] for item in res.data]
        self.assertNotIn('非表示イベント', titles)

    # ── Test 4: ゲスト認証 (GuestToken) でも取得できる ─────────────────────
    def test_guest_auth_allowed(self):
        # GuestSession requires a PlayerProfile with user=None
        guest_profile = PlayerProfile.objects.create(user=None, name='ゲスト')
        guest = GuestSession.objects.create(player_profile=guest_profile)
        self.client.credentials(HTTP_AUTHORIZATION=f'GuestToken {guest.token}')
        res = self.client.get('/api/task-suggestions/?type=event')
        self.assertEqual(res.status_code, 200)

    # ── Test 5: 不正な type は 400 を返す ────────────────────────────────────
    def test_invalid_type_returns_400(self):
        self._auth()
        res = self.client.get('/api/task-suggestions/?type=invalid')
        self.assertEqual(res.status_code, 400)
        self.assertIn('error', res.data)
