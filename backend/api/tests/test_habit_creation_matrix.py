"""
【BUG-71/73 反省契約テスト (2026-05-27)】習慣作成画面 (add_habit_page) の
網羅的設定マトリクス契約テスト。

PM 長期設計セッション 2026-05-27、PM 3 連続誤診断の反省を踏まえて add_habit_page
の **12 設定項目 × 5 検証軸** を構造的に縛る。これまで HabitListCreateView 直接の
テストが事実上空白 (test_legendary_slots.py で legendary slot 制のみカバー) で、
「設定通り保存される」契約が CI で守られていなかった。

カバー範囲 (13 シナリオ):
    名前バリデーション 3 件 (A1-A3): 必須 / 重複 / 長さ
    カテゴリ 1 件 (B5): 11 値で全て作成可能
    frequency × reset_cycle 制約 7 件 (C7-C13): 主要組み合わせ + 制約違反 400
    habit_type 2 件 (D19, D21): count / checklist
    難易度 1 件 (E23): easy/normal/hard 通常作成 (legendary は test_legendary_slots.py)
    デフォルト値 1 件 (F26): 作成直後の streak/best_streak/total_count/total_exp/is_active

Pre-mortem: BUG-73 (daily+monthly で表示と DB の乖離) のような「Backend は OK だが
UI 表示だけが間違っている」型のバグは本テストでは検出できない (UI 表示は Flutter widget
test の領分)。本テストは「Backend で設定通り保存される」を縛る。
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Habit, ChecklistItem, PlayerProfile

User = get_user_model()

_TEST_OVERRIDE = {
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


@override_settings(REST_FRAMEWORK=_TEST_OVERRIDE)
class HabitCreationMatrixTestCase(APITestCase):
    """add_habit_page 設定マトリクスの網羅契約テスト。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(username='tester', password='password')
        self.player = PlayerProfile.objects.create(
            user=self.user, level=1, max_exp=10000, mode='training',
        )
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    def _create(self, **overrides):
        """デフォルトの正常作成リクエスト、overrides で個別フィールド変更。"""
        data = {
            'name':        'テスト習慣',
            'category':    '学習',
            'frequency':   'daily',
            'reset_cycle': 'daily',
            'habit_type':  'count',
            'difficulty':  'normal',
            'memo':        '',
            'is_public':   True,
            'priority':    'medium',
        }
        data.update(overrides)
        return self.client.post('/api/habits/', data=data, format='json')

    # ─── A. 名前バリデーション 3 件 ───────────────────────────────

    def test_a1_normal_creation_returns_201(self):
        """正常作成 → 201 + Habit レコード作成。"""
        resp = self._create(name='朝のジョギング')
        self.assertEqual(resp.status_code, 201, resp.content)
        self.assertTrue(Habit.objects.filter(player=self.player, name='朝のジョギング').exists())

    def test_a2_duplicate_active_name_rejected_400(self):
        """同名 active 習慣が既に存在 → 400。"""
        Habit.objects.create(
            player=self.player, name='重複名前', category='学習',
            frequency='daily', reset_cycle='daily', habit_type='count',
            difficulty='normal', order=0,
        )
        resp = self._create(name='重複名前')
        self.assertEqual(resp.status_code, 400)
        self.assertIn('error', resp.json())

    def test_a3_archived_same_name_allowed(self):
        """同名でも is_active=False (アーカイブ済) なら再作成 OK = 201。"""
        Habit.objects.create(
            player=self.player, name='アーカイブ', category='学習',
            frequency='daily', reset_cycle='daily', habit_type='count',
            difficulty='normal', order=0, is_active=False,
        )
        resp = self._create(name='アーカイブ')
        self.assertEqual(resp.status_code, 201, resp.content)

    # ─── B. カテゴリ 1 件 ─────────────────────────────────────────

    def test_b5_all_eleven_categories_creatable(self):
        """11 値カテゴリすべてで作成可能 (FEAT-213 真実値、カテゴリ取りこぼし防止)。"""
        categories = [
            '運動', '学習', '仕事', '体力', '美容', '健康',
            '精神', '創造', '社交', '休息', 'その他',
        ]
        for i, cat in enumerate(categories):
            resp = self._create(name=f'cat_{i}', category=cat)
            self.assertEqual(
                resp.status_code, 201,
                f'カテゴリ {cat} で作成失敗: {resp.content}',
            )
        self.assertEqual(Habit.objects.filter(player=self.player).count(), 11)

    # ─── C. frequency × reset_cycle 制約 7 件 ────────────────────

    def test_c7_daily_daily_ok(self):
        """daily + daily = 201 (最頻組み合わせ)。"""
        resp = self._create(name='d_d', frequency='daily', reset_cycle='daily')
        self.assertEqual(resp.status_code, 201, resp.content)

    def test_c8_daily_monthly_ok(self):
        """daily + monthly = 201 (BUG-73 真因の組み合わせ、Backend では正常受付)。"""
        resp = self._create(name='d_m', frequency='daily', reset_cycle='monthly')
        self.assertEqual(resp.status_code, 201, resp.content)

    def test_c9_weekly_weekly_ok(self):
        """weekly + weekly = 201。"""
        resp = self._create(name='w_w', frequency='weekly', reset_cycle='weekly')
        self.assertEqual(resp.status_code, 201, resp.content)

    def test_c10_weekly_monthly_ok(self):
        """weekly + monthly = 201。"""
        resp = self._create(name='w_m', frequency='weekly', reset_cycle='monthly')
        self.assertEqual(resp.status_code, 201, resp.content)

    def test_c11_monthly_yearly_ok(self):
        """monthly + yearly = 201。"""
        resp = self._create(name='m_y', frequency='monthly', reset_cycle='yearly')
        self.assertEqual(resp.status_code, 201, resp.content)

    def test_c12_weekly_daily_rejected(self):
        """weekly + daily = 400 (reset_cycle < frequency、Habit.ALLOWED_RESET_CYCLES 制約)。"""
        resp = self._create(name='w_d', frequency='weekly', reset_cycle='daily')
        self.assertEqual(resp.status_code, 400)
        self.assertIn('reset_cycle', resp.json())

    def test_c13_monthly_daily_rejected(self):
        """monthly + daily = 400 (同上)。"""
        resp = self._create(name='m_d', frequency='monthly', reset_cycle='daily')
        self.assertEqual(resp.status_code, 400)
        self.assertIn('reset_cycle', resp.json())

    # ─── D. habit_type 2 件 ──────────────────────────────────────

    def test_d19_count_type_creation(self):
        """count 型作成 → 201 + habit.habit_type='count'。"""
        resp = self._create(name='count_h', habit_type='count')
        self.assertEqual(resp.status_code, 201, resp.content)
        habit = Habit.objects.get(player=self.player, name='count_h')
        self.assertEqual(habit.habit_type, 'count')

    def test_d21_checklist_type_with_items(self):
        """checklist 型 + checklist_items 3 件 → 201 + ChecklistItem 3 レコード作成。"""
        resp = self._create(
            name='checklist_h',
            habit_type='checklist',
            checklist_items=['朝食を食べる', 'ストレッチ', 'メール確認'],
        )
        self.assertEqual(resp.status_code, 201, resp.content)
        habit = Habit.objects.get(player=self.player, name='checklist_h')
        self.assertEqual(habit.habit_type, 'checklist')
        items = ChecklistItem.objects.filter(habit=habit).order_by('order')
        self.assertEqual(items.count(), 3)
        self.assertEqual(
            list(items.values_list('text', flat=True)),
            ['朝食を食べる', 'ストレッチ', 'メール確認'],
        )

    # ─── E. difficulty 1 件 ──────────────────────────────────────

    def test_e23_easy_normal_hard_creatable(self):
        """easy / normal / hard で正常作成 (legendary は test_legendary_slots.py)。"""
        for diff in ['easy', 'normal', 'hard']:
            resp = self._create(name=f'diff_{diff}', difficulty=diff)
            self.assertEqual(
                resp.status_code, 201,
                f'難易度 {diff} で作成失敗: {resp.content}',
            )
            habit = Habit.objects.get(player=self.player, name=f'diff_{diff}')
            self.assertEqual(habit.difficulty, diff)

    # ─── F. デフォルト値 + 自動設定 1 件 ─────────────────────────

    def test_f26_default_values_on_creation(self):
        """新規作成時の Backend 自動設定値が想定通り。"""
        resp = self._create(name='default_check')
        self.assertEqual(resp.status_code, 201, resp.content)
        habit = Habit.objects.get(player=self.player, name='default_check')
        self.assertEqual(habit.streak, 0, '新規 habit の streak=0')
        self.assertEqual(habit.best_streak, 0, '新規 habit の best_streak=0')
        self.assertEqual(habit.total_count, 0, '新規 habit の total_count=0')
        self.assertEqual(habit.total_exp, 0, '新規 habit の total_exp=0')
        self.assertTrue(habit.is_active, '新規 habit は is_active=True')
        self.assertEqual(habit.order, 0, '初回作成 habit の order=0')

        # 2 件目作成 → order=1
        resp2 = self._create(name='order_check_2')
        self.assertEqual(resp2.status_code, 201)
        habit2 = Habit.objects.get(player=self.player, name='order_check_2')
        self.assertEqual(habit2.order, 1, '2 件目 habit の order=1')

    # ─── G. レスポンス形式 (Flutter 互換性) 1 件 ────────────────

    def test_g29_response_includes_expected_fields(self):
        """API レスポンスに Flutter Habit.fromJson が期待する全フィールド含む。"""
        resp = self._create(name='resp_check')
        self.assertEqual(resp.status_code, 201, resp.content)
        data = resp.json()
        expected_fields = {
            'id', 'name', 'category', 'frequency', 'reset_cycle',
            'habit_type', 'difficulty', 'order',
            'streak', 'best_streak', 'total_count', 'total_exp',
            'created_at', 'is_active', 'memo', 'is_public',
            'priority', 'due_date',
            'today_log', 'history', 'checklist_items',
            'shield_active', 'period_progress',
        }
        for field in expected_fields:
            self.assertIn(
                field, data,
                f'レスポンス必須フィールド `{field}` が欠落: {data.keys()}',
            )
        # 新規習慣は today_log=null (まだ count されていない)
        self.assertIsNone(data['today_log'], '新規 habit は today_log=null')
