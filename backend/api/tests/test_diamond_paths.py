"""【FEAT-314】ダイヤ取得経路追加の契約テスト 9 件。

3 経路 × 各 3 シナリオ:
  - battle:  当日初勝利 +5 / 同日 2 回目 0 / 翌日初勝利 +5
  - streak:  7 日目 +5 / 8 日目 0 / 14 日目 +5
  - title:   初獲得 +20 / 同称号再判定 0 / Pre-mortem #2 backfill 後の既存 unlock 不付与

helper 単体テスト (transaction.atomic() + select_for_update() の冪等性) として記述。
HabitCountView / BattleFinishView 経由の e2e は `test_habit_count_view.py` /
`test_battle_views.py` 側で必要に応じて追加（本テストは helper 契約のみ縛る）。
"""
from datetime import date, timedelta

from django.contrib.auth import get_user_model
from django.test import TestCase

from api.models import Achievement, PlayerAchievement, PlayerProfile
from api.services.diamond_service import (
    DIAMOND_BATTLE_WIN_AMOUNT,
    DIAMOND_STREAK_MILESTONE_AMT,
    DIAMOND_TITLE_ACQUIRED_AMOUNT,
    award_diamond_for_battle_win,
    award_diamond_for_streak_7days,
    award_diamond_for_title_acquired,
)

User = get_user_model()


class _DiamondHelperTestBase(TestCase):
    """共通 setUp: User + PlayerProfile (diamonds=0)。"""

    def setUp(self):
        self.user = User.objects.create_user('p1', email='p1@example.com')
        self.player = PlayerProfile.objects.create(
            user=self.user,
            name='Player1',
            diamonds=0,
            diamonds_total=0,
        )


class BattleDiamondPathTest(_DiamondHelperTestBase):
    """`award_diamond_for_battle_win` の 3 シナリオ契約。"""

    def test_first_win_today_grants_5_diamond(self):
        """当日初勝利で +5 ダイヤ + `last_battle_diamond_at` が today に更新される。"""
        today = date(2026, 5, 26)
        granted = award_diamond_for_battle_win(self.player, today)
        self.assertTrue(granted)
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, DIAMOND_BATTLE_WIN_AMOUNT)
        self.assertEqual(self.player.diamonds_total, DIAMOND_BATTLE_WIN_AMOUNT)
        self.assertEqual(self.player.last_battle_diamond_at, today)

    def test_second_win_same_day_is_idempotent(self):
        """同日 2 回目の勝利では付与されない (冪等性、Pre-mortem #1 並列レース対策)。"""
        today = date(2026, 5, 26)
        award_diamond_for_battle_win(self.player, today)  # 1 回目
        granted = award_diamond_for_battle_win(self.player, today)  # 2 回目
        self.assertFalse(granted)
        self.player.refresh_from_db()
        # 累計は 1 回目の +5 のまま、2 回目は加算されない
        self.assertEqual(self.player.diamonds, DIAMOND_BATTLE_WIN_AMOUNT)

    def test_next_day_first_win_grants_5_diamond_again(self):
        """翌日の初勝利で再度 +5 ダイヤが付与される (日跨ぎリセット)。"""
        day1 = date(2026, 5, 26)
        day2 = day1 + timedelta(days=1)
        award_diamond_for_battle_win(self.player, day1)
        granted = award_diamond_for_battle_win(self.player, day2)
        self.assertTrue(granted)
        self.player.refresh_from_db()
        # 1 回目 +5 + 2 回目 +5 = 10
        self.assertEqual(self.player.diamonds, DIAMOND_BATTLE_WIN_AMOUNT * 2)
        self.assertEqual(self.player.last_battle_diamond_at, day2)


class StreakDiamondPathTest(_DiamondHelperTestBase):
    """`award_diamond_for_streak_7days` の 3 シナリオ契約。"""

    def test_streak_7days_grants_5_diamond(self):
        """7 日連続達成で +5 ダイヤ + `last_streak_diamond_day = 7`。"""
        granted = award_diamond_for_streak_7days(self.player, 7)
        self.assertTrue(granted)
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, DIAMOND_STREAK_MILESTONE_AMT)
        self.assertEqual(self.player.last_streak_diamond_day, 7)

    def test_streak_8days_does_not_grant(self):
        """8 日 (7 の倍数でない) では付与されない (節目以外は 0)。"""
        granted = award_diamond_for_streak_7days(self.player, 8)
        self.assertFalse(granted)
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 0)
        self.assertEqual(self.player.last_streak_diamond_day, 0)

    def test_streak_14days_grants_after_7days(self):
        """7 → 14 日達成で再度 +5、`last_streak_diamond_day = 14` に更新。"""
        award_diamond_for_streak_7days(self.player, 7)
        granted = award_diamond_for_streak_7days(self.player, 14)
        self.assertTrue(granted)
        self.player.refresh_from_db()
        # 7 +5 + 14 +5 = 10
        self.assertEqual(self.player.diamonds, DIAMOND_STREAK_MILESTONE_AMT * 2)
        self.assertEqual(self.player.last_streak_diamond_day, 14)

    def test_streak_same_value_is_idempotent(self):
        """同 streak 値 (7) で再度呼ばれても重複付与しない (Pre-mortem #1)。"""
        award_diamond_for_streak_7days(self.player, 7)
        granted = award_diamond_for_streak_7days(self.player, 7)
        self.assertFalse(granted)
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, DIAMOND_STREAK_MILESTONE_AMT)


class TitleDiamondPathTest(_DiamondHelperTestBase):
    """`award_diamond_for_title_acquired` の 3 シナリオ契約 (PlayerAchievement.diamond_awarded)。"""

    def setUp(self):
        super().setUp()
        # 1 つの Achievement と未付与 PlayerAchievement を用意
        # migration 0028 で seed 済の既存 key (first_log / streak_7 等) との衝突を
        # 避けるためテスト専用の `_test_*` プレフィックスを使う。
        self.achievement = Achievement.objects.create(
            key='_test_feat314_title',
            name='テスト称号',
            description='FEAT-314 contract test 専用',
            icon='🌱',
            condition_type='total_logs',
            condition_value=1,
            reward_diamonds=10,
        )
        self.pa = PlayerAchievement.objects.create(
            player=self.player,
            achievement=self.achievement,
            diamond_awarded=False,  # 新規 unlock 想定
        )

    def test_title_first_acquired_grants_20_diamond(self):
        """初獲得で +20 ダイヤ + `diamond_awarded=True` に更新される。"""
        granted = award_diamond_for_title_acquired(self.player, self.achievement.id)
        self.assertTrue(granted)
        self.player.refresh_from_db()
        self.pa.refresh_from_db()
        self.assertEqual(self.player.diamonds, DIAMOND_TITLE_ACQUIRED_AMOUNT)
        self.assertEqual(self.player.diamonds_total, DIAMOND_TITLE_ACQUIRED_AMOUNT)
        self.assertTrue(self.pa.diamond_awarded)

    def test_title_already_awarded_is_idempotent(self):
        """同称号再判定で重複付与しない (Pre-mortem #1 並列レース対策)。"""
        award_diamond_for_title_acquired(self.player, self.achievement.id)
        granted = award_diamond_for_title_acquired(self.player, self.achievement.id)
        self.assertFalse(granted)
        self.player.refresh_from_db()
        # 1 回目の +20 のまま、2 回目は加算されない
        self.assertEqual(self.player.diamonds, DIAMOND_TITLE_ACQUIRED_AMOUNT)

    def test_title_backfilled_existing_achievement_does_not_grant(self):
        """既存 unlock 済 (migration 0091 backfill 済) は付与対象外 (Pre-mortem #2)。

        ダイヤインフレ回避のため、リリース前 unlock 済の称号は `diamond_awarded=True`
        で初期化されており、本ヘルパーを再度呼んでも no-op になることを縛る。
        """
        # 既存 unlock を模擬: diamond_awarded=True で初期化
        self.pa.diamond_awarded = True
        self.pa.save(update_fields=['diamond_awarded'])

        granted = award_diamond_for_title_acquired(self.player, self.achievement.id)
        self.assertFalse(granted)
        self.player.refresh_from_db()
        # 付与されない = 0 のまま
        self.assertEqual(self.player.diamonds, 0)
