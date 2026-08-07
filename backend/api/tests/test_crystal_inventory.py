"""【FEAT-379 (2026-05-29)】ステータス結晶インベントリの契約テスト (4 件)。

Pre-mortem #1 (最重要): 既存 CharacterStat Lv UP 経路への回帰チェック。
既存テストとの整合: test_diamond_paths / test_stat_battle_link / test_stat_balance_boundary。

検証対象:
1. 運動力 Lv UP で exercise_crystal_count += 1 (他 5 結晶は変動なし)
2. 6 ステータス全部で Lv UP → それぞれ正しい結晶 +1 (6 軸独立性)
3. PlayerProfileSerializer に crystals ネスト 6 キーが含まれる
4. 既存 max_exp *= 1.2 + allocatable_points + level の回帰なし (Pre-mortem #1)
"""
from django.contrib.auth import get_user_model
from django.test import TestCase

from api.models import CharacterStat, PlayerProfile
from api.serializers import PlayerProfileSerializer
from api.services.exp_service import _award_crystal_on_stat_level_up

User = get_user_model()


class CrystalAwardOnStatLevelUpTest(TestCase):
    """_award_crystal_on_stat_level_up の契約テスト。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='crystal_test', password='pw')
        self.player = PlayerProfile.objects.create(user=self.user)

    def _make_stat(self, name: str) -> CharacterStat:
        return CharacterStat.objects.create(
            player=self.player, name=name,
            level=1, current_exp=0, max_exp=100,
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: 運動力 Lv UP で exercise_crystal_count += 1
    # ─────────────────────────────────────────────────────────────────
    def test_exercise_stat_level_up_increments_exercise_crystal(self):
        """運動力 Lv UP で exercise_crystal_count が +1、他 5 結晶は変動なし。"""
        stat = self._make_stat('運動力')

        # before: all crystals = 0
        self.assertEqual(self.player.exercise_crystal_count, 0)
        self.assertEqual(self.player.learning_crystal_count, 0)
        self.assertEqual(self.player.health_crystal_count,   0)
        self.assertEqual(self.player.mental_crystal_count,   0)
        self.assertEqual(self.player.creation_crystal_count, 0)
        self.assertEqual(self.player.contribution_crystal_count, 0)

        crystal_key = _award_crystal_on_stat_level_up(stat, self.player)

        self.assertEqual(crystal_key, 'exercise')

        self.player.refresh_from_db()
        self.assertEqual(self.player.exercise_crystal_count, 1)
        # 他 5 結晶は変動なし (6 軸独立性 Pre-mortem #1)
        self.assertEqual(self.player.learning_crystal_count,     0)
        self.assertEqual(self.player.health_crystal_count,       0)
        self.assertEqual(self.player.mental_crystal_count,       0)
        self.assertEqual(self.player.creation_crystal_count,     0)
        self.assertEqual(self.player.contribution_crystal_count, 0)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: 6 ステータス全部で Lv UP → 正しい結晶 +1 (6 軸独立性)
    # ─────────────────────────────────────────────────────────────────
    def test_all_6_stats_increment_correct_crystals(self):
        """6 ステータス全部でそれぞれ正しい結晶が +1 される。"""
        expected_pairs = [
            ('運動力', 'exercise',     'exercise_crystal_count'),
            ('学習力', 'learning',     'learning_crystal_count'),
            ('健康力', 'health',       'health_crystal_count'),
            ('精神力', 'mental',       'mental_crystal_count'),
            ('創造力', 'creation',     'creation_crystal_count'),
            ('貢献力', 'contribution', 'contribution_crystal_count'),
        ]
        for stat_name, expected_key, field in expected_pairs:
            # 各 stat を独立テスト (他の stat が残っていても独立性を確認)
            stat = self._make_stat(stat_name)
            key  = _award_crystal_on_stat_level_up(stat, self.player)

            self.assertEqual(key, expected_key,
                             msg=f'{stat_name} → expected crystal key {expected_key!r}')

            self.player.refresh_from_db()
            self.assertGreater(
                getattr(self.player, field), 0,
                msg=f'{stat_name}: {field} should be > 0 after award',
            )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: PlayerProfileSerializer に crystals ネスト 6 キーが含まれる
    # ─────────────────────────────────────────────────────────────────
    def test_player_serializer_exposes_crystal_inventory(self):
        """PlayerProfileSerializer 出力に crystals ネスト 6 キーが含まれる。"""
        # 運動力を 1 個付与しておく
        stat = self._make_stat('運動力')
        _award_crystal_on_stat_level_up(stat, self.player)
        self.player.refresh_from_db()

        data = PlayerProfileSerializer(self.player).data

        self.assertIn('crystals', data, 'crystals フィールドが serializer に存在するはず')
        crystals = data['crystals']
        self.assertEqual(set(crystals.keys()),
                         {'exercise', 'learning', 'health', 'mental', 'creation', 'contribution'},
                         '6 つの結晶キーが全て含まれるはず')
        self.assertEqual(crystals['exercise'], 1, '運動の結晶が 1 になるはず')
        self.assertEqual(crystals['learning'], 0, '他の結晶は 0 のはず')

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 4: 既存経路に回帰なし (Pre-mortem #1)
    # ─────────────────────────────────────────────────────────────────
    def test_existing_stat_level_up_regression(self):
        """既存 max_exp *= 1.2 + allocatable_points + level 経路への回帰なし。

        _award_crystal_on_stat_level_up は player の crystal フィールドのみを更新し、
        stat.level / stat.max_exp / player.allocatable_points を変更しない。
        """
        stat = self._make_stat('運動力')
        before_level    = stat.level
        before_max_exp  = stat.max_exp
        before_alloc    = self.player.allocatable_points

        _award_crystal_on_stat_level_up(stat, self.player)

        # stat.level / stat.max_exp は変更されない (結晶関数は読み取りのみ)
        stat.refresh_from_db()
        self.assertEqual(stat.level,   before_level,   'stat.level は変更しないはず')
        self.assertEqual(stat.max_exp, before_max_exp, 'stat.max_exp は変更しないはず')

        # player.allocatable_points も変更されない
        self.player.refresh_from_db()
        self.assertEqual(
            self.player.allocatable_points, before_alloc,
            'allocatable_points は変更しないはず',
        )
