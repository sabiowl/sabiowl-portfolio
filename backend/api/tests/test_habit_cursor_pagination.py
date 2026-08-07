"""【FEAT-474 (2026-07-03)】HabitListCreateView cursor pagination テスト。

cursor = '<order>:<id>' 形式で前ページ末尾の位置を保持し、
limit+1 トリック で has_more を判定する設計を検証する。
"""
from django.test import TestCase
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient

from ..models import Habit, PlayerProfile

User = get_user_model()


def _create_user_and_player(username='testuser'):
    user = User.objects.create_user(username=username, password='pass')
    player = PlayerProfile.objects.create(user=user, name=username)
    return user, player


def _auth_client(user):
    client = APIClient()
    client.force_authenticate(user=user)
    return client


class HabitCursorPaginationTest(TestCase):
    """cursor pagination: 正常系・cursor 解析・has_more フラグ。"""

    def setUp(self):
        self.user, self.player = _create_user_and_player()
        self.client = _auth_client(self.user)
        # 5 件の習慣を order 1-5 で作成
        for i in range(1, 6):
            Habit.objects.create(
                player=self.player,
                name=f'習慣{i}',
                order=i,
                is_active=True,
            )

    def test_first_page_returns_results_and_next_cursor(self):
        """limit=2 の 1 ページ目: 2 件 + has_more=True + next_cursor が返る。"""
        res = self.client.get('/api/habits/', {'limit': 2})
        self.assertEqual(res.status_code, 200)
        data = res.json()
        self.assertIn('results', data)
        self.assertIn('next_cursor', data)
        self.assertIn('has_more', data)
        self.assertEqual(len(data['results']), 2)
        self.assertTrue(data['has_more'])
        self.assertNotEqual(data['next_cursor'], '')

    def test_second_page_uses_cursor(self):
        """cursor を使って 2 ページ目を取得できる。"""
        res1 = self.client.get('/api/habits/', {'limit': 2})
        cursor = res1.json()['next_cursor']

        res2 = self.client.get('/api/habits/', {'limit': 2, 'cursor': cursor})
        self.assertEqual(res2.status_code, 200)
        data2 = res2.json()
        self.assertEqual(len(data2['results']), 2)
        # 2 ページ目には 1 ページ目の ID が含まれないこと
        page1_ids = {h['id'] for h in res1.json()['results']}
        page2_ids = {h['id'] for h in data2['results']}
        self.assertTrue(page1_ids.isdisjoint(page2_ids))

    def test_last_page_has_more_false(self):
        """最終ページ: has_more=False + next_cursor='' が返る。"""
        res1 = self.client.get('/api/habits/', {'limit': 2})
        cursor1 = res1.json()['next_cursor']
        res2 = self.client.get('/api/habits/', {'limit': 2, 'cursor': cursor1})
        cursor2 = res2.json()['next_cursor']
        res3 = self.client.get('/api/habits/', {'limit': 2, 'cursor': cursor2})

        data3 = res3.json()
        self.assertFalse(data3['has_more'])
        self.assertEqual(data3['next_cursor'], '')
        self.assertEqual(len(data3['results']), 1)  # 5件目

    def test_all_pages_cover_all_habits(self):
        """全ページ結果を結合すると全 5 件になる。"""
        all_ids = []
        cursor = ''
        while True:
            params = {'limit': 2}
            if cursor:
                params['cursor'] = cursor
            res = self.client.get('/api/habits/', params)
            data = res.json()
            all_ids.extend(h['id'] for h in data['results'])
            if not data['has_more']:
                break
            cursor = data['next_cursor']

        self.assertEqual(len(all_ids), 5)
        self.assertEqual(len(set(all_ids)), 5)  # 重複なし

    def test_invalid_cursor_returns_400(self):
        """不正な cursor は 400 を返す。"""
        res = self.client.get('/api/habits/', {'cursor': 'invalid_format'})
        self.assertEqual(res.status_code, 400)

    def test_no_cursor_returns_all_when_under_limit(self):
        """件数がデフォルト limit 以下の場合 has_more=False が返る。"""
        res = self.client.get('/api/habits/')
        data = res.json()
        self.assertFalse(data['has_more'])
        self.assertEqual(data['next_cursor'], '')
        self.assertEqual(len(data['results']), 5)

    def test_limit_capped_at_100(self):
        """limit=999 でも最大 100 件にクランプされる (5 件しかないので全件)。"""
        res = self.client.get('/api/habits/', {'limit': 999})
        self.assertEqual(res.status_code, 200)
        data = res.json()
        self.assertEqual(len(data['results']), 5)
        self.assertFalse(data['has_more'])
