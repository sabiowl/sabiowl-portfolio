"""
【FEAT-334/FEAT-380 廃止】Legendary スロット制の契約テスト。
【FEAT-434 (2026-06-14)】Habit (count/checklist) の難易度廃止に伴い、
6 軸 stat Lv 連動の Legendary スロット制 (FEAT-334/380) を全廃した。

検証対象 (FEAT-434):
    1. `calc_legendary_slots` は stat レベルに関わらず常に 0 を返す
    2. Habit (count/checklist) の difficulty='legendary' 作成は、
       stat レベルに関わらず構造的に常時 400 (Legendary 不可)
    3. ToDo (habit_type='todo') は元から slot 制限の対象外
       (`views/habits.py` のチェックは `habit_type != 'todo'` のときのみ発火)
       であり、PATCH で difficulty='legendary' に変更しても slot 制限なし
    4. `calc_exp_gain('legendary')` = round(EXP_PER_COUNT(30) * 5.0) = 150
       (FEAT-406 の EXP_PER_COUNT 20→30 変更後の値、ToDo 経路で使用)

旧シナリオ (6 軸全 Lv5 で 1 枠目解放 / ボトルネック厳格化 / 既存 legendary の
カウント等) は構造そのものが撤廃されたため削除。
"""
from django.contrib.auth import get_user_model
from django.test import override_settings
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.constants import GameBalance
from api.models import CharacterStat, Habit, PlayerProfile
from api.services.exp_service import calc_exp_gain, create_default_stats
from api.services.habit_slot_service import (
    calc_legendary_slots,
    count_active_legendary,
)

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
class LegendarySlotTestCase(APITestCase):
    """FEAT-434 Legendary スロット制廃止の契約テスト。"""

    def setUp(self):
        self.user = User.objects.create_user(username='tester', password='password')
        self.player = PlayerProfile.objects.create(
            user=self.user, level=1, max_exp=10000, mode='training',
        )
        create_default_stats(self.player)
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    # ─────────────────────────────────────────────────────────────────
    # ヘルパー
    # ─────────────────────────────────────────────────────────────────

    def _set_all_stat_levels(self, level: int):
        """6 軸 stat 全部の level を一律で設定。"""
        CharacterStat.objects.filter(player=self.player).update(level=level)

    def _create_habit(self, habit_type='count', difficulty='legendary', name='伝説の習慣'):
        return self.client.post('/api/habits/', data={
            'name':       name,
            'category':   '運動',
            'difficulty': difficulty,
            'frequency':  'daily',
            'habit_type': habit_type,
        }, format='json')

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: calc_legendary_slots は stat レベルに関わらず常に 0
    # ─────────────────────────────────────────────────────────────────

    def test_calc_legendary_slots_always_zero(self):
        """【FEAT-434】stat Lv 0 / 5 / 50 のいずれでも calc_legendary_slots は 0。"""
        self.assertEqual(calc_legendary_slots(self.player), 0)

        self._set_all_stat_levels(5)
        self.assertEqual(calc_legendary_slots(self.player), 0)

        self._set_all_stat_levels(50)
        self.assertEqual(calc_legendary_slots(self.player), 0)

        # stat 0 件 (新規ユーザー等) でも 0
        CharacterStat.objects.filter(player=self.player).delete()
        self.assertEqual(calc_legendary_slots(self.player), 0)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: Habit (count/checklist) の Legendary は常時 400
    # ─────────────────────────────────────────────────────────────────

    def test_all_stats_lv5_unlocks_first_slot(self):
        """【FEAT-434】6 軸全部 Lv 5 でも Habit (count) の Legendary は常時 400。

        旧テスト名 (`test_all_stats_lv5_unlocks_first_slot`) は FEAT-380 で
        「初解禁 milestone」を検証していたが、FEAT-434 でスロット制自体が
        全廃されたため、「stat レベルに関わらず Habit Legendary は不可」
        という新しい不変条件を検証する。
        """
        self._set_all_stat_levels(5)
        self.assertEqual(calc_legendary_slots(self.player), 0)

        resp = self._create_habit(habit_type='count', difficulty='legendary', name='伝説 1')
        self.assertEqual(resp.status_code, 400, resp.content)
        self.assertEqual(resp.json()['legendary_slots_total'], 0)
        self.assertEqual(resp.json()['legendary_slots_used'], 0)

    def test_checklist_legendary_also_rejected(self):
        """【FEAT-434】habit_type='checklist' の Legendary も常時 400。"""
        self._set_all_stat_levels(50)
        resp = self._create_habit(habit_type='checklist', difficulty='legendary', name='伝説チェック')
        self.assertEqual(resp.status_code, 400, resp.content)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: ToDo (habit_type='todo') は slot 制限の対象外
    # ─────────────────────────────────────────────────────────────────

    def test_legacy_legendary_counts_against_new_slots(self):
        """【FEAT-434】既存 (legacy) の active な Habit Legendary が残っていても、
        ToDo の作成・difficulty 変更には影響しない (slot 制限は ToDo に存在しない)。

        旧テスト名 (`test_legacy_legendary_counts_against_new_slots`) は FEAT-380 の
        「過去 legendary の使用済カウント」を検証していたが、FEAT-434 でスロット制が
        全廃されたため、「legacy データの存在が ToDo の挙動に影響しない」ことを検証する。
        """
        # legacy: 過去に作成された active な Habit Legendary (移行前データを模す)
        Habit.objects.create(
            player=self.player, name='legacy 伝説',
            category='運動', difficulty='legendary',
            frequency='daily', reset_cycle='daily',
            habit_type='count', order=0,
        )
        self.assertEqual(count_active_legendary(self.player), 1)

        # ToDo (habit_type='todo') の作成は legacy legendary の有無に関わらず成功する
        resp = self.client.post('/api/habits/', data={
            'name':       '新規 ToDo',
            'category':   '運動',
            'habit_type': 'todo',
        }, format='json')
        self.assertEqual(resp.status_code, 201, resp.content)

        # 作成された ToDo に PATCH で difficulty='legendary' を設定しても slot 制限なし
        todo_id = resp.json()['id']
        patch_resp = self.client.patch(f'/api/habits/{todo_id}/', data={
            'difficulty': 'legendary',
        }, format='json')
        self.assertEqual(patch_resp.status_code, 200, patch_resp.content)
        self.assertEqual(patch_resp.json()['difficulty'], 'legendary')

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 4: calc_exp_gain('legendary') = 150 (FEAT-406 整合)
    # ─────────────────────────────────────────────────────────────────

    def test_legendary_full_multiplier_at_player_level_1(self):
        """ToDo (habit_type='todo') の legendary 完了 EXP = round(30 * 5.0) = 150。

        【FEAT-406 (2026-06-01)】EXP_PER_COUNT 20 → 30 変更後の値。
        旧テストの期待値 100 (= 20 * 5.0) は FEAT-406 で陳腐化していた。
        """
        habit = Habit.objects.create(
            player=self.player, name='X', category='運動',
            difficulty='legendary', frequency='daily',
            reset_cycle='daily', habit_type='todo', order=0,
        )
        self.assertEqual(self.player.level, 1)
        self.assertEqual(calc_exp_gain(habit, self.player), 150)
        self.assertEqual(GameBalance.DIFFICULTY_MULTIPLIER['legendary'], 5.0)
        self.assertEqual(GameBalance.EXP_PER_COUNT, 30)
