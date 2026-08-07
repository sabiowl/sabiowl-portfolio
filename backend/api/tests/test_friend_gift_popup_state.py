"""【codebase_review 20260704 P2-#5】friend_gift_popup_service の NEW state 経由 契約テスト。

FEAT-478 Phase 2b で PlayerProfile 4 分割 (Battle / Economy / Streak / Settings) 後、
`friend_gift_popup_service.check_friend_gift_popup_trigger` は下記 3 経路を
PlayerStreakState (NEW state) / PlayerBattleState (NEW state) 経由に統一した:

1. daily_task_count の read / write → PlayerStreakState.daily_task_count
2. last_friend_gift_popup_date の read / write → PlayerStreakState.last_friend_gift_popup_date
3. 返却 dict の候補フレンドの level → chosen.battle.level (PlayerBattleState 経由)

本テストは「NEW state のみ更新 → service 関数が正しく NEW state を参照する」ことを
契約として縛ることで、旧 field 直接参照への回帰を防止する。Phase 2c (RemoveField)
で旧 field が物理削除された瞬間に AttributeError で production down する事故を
防ぐ regression guard。

3 シナリオ:
- A: daily_task_count が PlayerStreakState 経由で increment される
- B: last_friend_gift_popup_date が PlayerStreakState 経由で更新される
- C: 候補フレンドの level が chosen.battle.level (NEW state) から取得される
"""
from datetime import date as date_type, timedelta

from django.contrib.auth import get_user_model
from django.test import TestCase

from api.constants import FriendStatus
from api.models import Friendship, PlayerProfile
from api.services.friend_gift_popup_service import check_friend_gift_popup_trigger

User = get_user_model()


class FriendGiftPopupNewStateContractTest(TestCase):
    """【codebase_review 20260704 P2-#5】friend_gift_popup_service の NEW state 契約。"""

    def setUp(self):
        self.today = date_type.today()

        # ── プレイヤー (発火判定対象) ─────────────────────
        self.player_user = User.objects.create_user(
            username='player', password='password',
        )
        self.player = PlayerProfile.objects.create(
            user=self.player_user, name='プレイヤー',
        )

        # ── フレンド (候補) ────────────────────────────────
        self.friend_user = User.objects.create_user(
            username='friend', password='password',
        )
        self.friend_player = PlayerProfile.objects.create(
            user=self.friend_user, name='フレンド',
        )
        # 直近ログイン日を今日に (candidate 抽出条件を満たす)
        friend_streak = self.friend_player.streak
        friend_streak.last_login_diamond_at = self.today
        friend_streak.save(update_fields=['last_login_diamond_at'])

        # accepted 状態のフレンド関係
        Friendship.objects.create(
            from_player=self.player,
            to_player=self.friend_player,
            status=FriendStatus.ACCEPTED,
        )

    # ─────────────────────────────────────────────────────────────
    # シナリオ A: daily_task_count は PlayerStreakState 経由で increment される
    # ─────────────────────────────────────────────────────────────
    def test_A_daily_task_count_writes_to_streak_state(self):
        """3 回連続で service を呼ぶと PlayerStreakState.daily_task_count が 1→2→3 に。

        旧実装 (バグ状態、Phase 2c 前の時限爆弾): PlayerProfile.daily_task_count に
        直接 write していたため、Phase 2c で RemoveField した瞬間に AttributeError。
        新実装: player.streak (PlayerStreakState proxy) 経由で書込。
        """
        # 1 回目
        check_friend_gift_popup_trigger(self.player, self.today)
        streak = self.player.streak
        self.assertEqual(
            streak.daily_task_count, 1,
            'PlayerStreakState.daily_task_count が increment されていない = '
            '旧 PlayerProfile.daily_task_count 直接 write 疑い (Phase 2c 破綻シグナル)',
        )
        self.assertEqual(streak.daily_task_count_date, self.today)

        # 2 回目
        check_friend_gift_popup_trigger(self.player, self.today)
        streak.refresh_from_db()
        self.assertEqual(streak.daily_task_count, 2)

        # 3 回目 (発火条件を満たす、popup 候補が返るはず)
        result = check_friend_gift_popup_trigger(self.player, self.today)
        streak.refresh_from_db()
        self.assertEqual(streak.daily_task_count, 3)
        self.assertIsNotNone(
            result,
            '3 回目で popup 候補が返るべき (フレンドが直近ログイン済 + accepted なため)',
        )

    # ─────────────────────────────────────────────────────────────
    # シナリオ B: last_friend_gift_popup_date は PlayerStreakState 経由で更新される
    # ─────────────────────────────────────────────────────────────
    def test_B_last_friend_gift_popup_date_writes_to_streak_state(self):
        """3 回目の service 呼出後、PlayerStreakState.last_friend_gift_popup_date に
        今日が記録される。旧 PlayerProfile.last_friend_gift_popup_date への直接 write
        では Phase 2c で壊れるため、NEW state 経由で書き込まれることを保証。
        """
        # 3 回目で popup 発火 (Step 8 で flag が立つ)
        for _ in range(3):
            check_friend_gift_popup_trigger(self.player, self.today)

        streak = self.player.streak
        streak.refresh_from_db()
        self.assertEqual(
            streak.last_friend_gift_popup_date, self.today,
            'PlayerStreakState.last_friend_gift_popup_date が今日で更新されていない = '
            '旧 PlayerProfile 直接 write 疑い (Phase 2c 破綻シグナル)',
        )

        # 同日 4 回目呼出でも popup は再発火しない (Step 3 の重複防止)
        result_4th = check_friend_gift_popup_trigger(self.player, self.today)
        self.assertIsNone(
            result_4th,
            'daily_task_count = 4 で = 3 の厳密一致条件から外れるため popup は返らない',
        )

    # ─────────────────────────────────────────────────────────────
    # シナリオ C: 候補 dict の level は PlayerBattleState (NEW state) 経由で読む
    # ─────────────────────────────────────────────────────────────
    def test_C_candidate_level_reflects_new_state_battle_level(self):
        """候補フレンドの level が NEW state (chosen.battle.level) 経由で読まれる。

        旧実装 (バグ状態): `chosen.level` (PlayerProfile.level、Phase 2b 以降どこからも
        書き込まれない孤立 field) を返却していたため、フレンドのレベルアップが popup
        候補には反映されなかった。
        新実装: `chosen.battle.level` (PlayerBattleState、NEW state) 経由。

        本テストは write path が NEW state に書込 → service 関数が NEW state から
        読み取る 契約を縛る。旧実装だと popup 候補の level は初期値のまま。
        """
        # フレンドのレベルアップ (NEW state のみ更新)
        friend_battle = self.friend_player.battle
        friend_battle.level = 20
        friend_battle.save(update_fields=['level'])
        # 【2026-07-09 修正】前提 assert を「NEW state 側で level=20 が persist している」に置換。
        # 旧 assert (`self.friend_player.level == 1`) は Phase 2c で導入された
        # PlayerProfile.__getattr__ shim (models/player.py:266-277,
        # _OLD_FIELD_TO_STATE['level'] = 'battle') により透過的に `player.battle.level`
        # にリダイレクトされるため、shim 導入後は常に 20 が返り成立しない。
        # 本 assert は「setup が期待通り NEW state に書けた」ことを保証する意義を残す。
        self.friend_player.refresh_from_db()
        self.assertEqual(
            self.friend_player.battle.level, 20,
            '前提: PlayerBattleState.level = 20 が persist していること (setup 健全性確認)',
        )

        # 3 回目で popup 発火 → 候補 dict が返る
        for _ in range(2):
            check_friend_gift_popup_trigger(self.player, self.today)
        result = check_friend_gift_popup_trigger(self.player, self.today)

        self.assertIsNotNone(result, '3 回目で候補が返る前提')
        self.assertEqual(
            result['level'], 20,
            '候補 dict の level は chosen.battle.level (NEW state) から読むべき。'
            '1 が返る場合は chosen.level (旧 field 直接参照) の回帰',
        )

    # ─────────────────────────────────────────────────────────────
    # シナリオ D: 日跨ぎリセットも PlayerStreakState 経由で動く
    # ─────────────────────────────────────────────────────────────
    def test_D_daily_reset_uses_streak_state_date(self):
        """PlayerStreakState.daily_task_count_date != today で自動 0 リセット。
        旧実装は PlayerProfile.daily_task_count_date を読んでリセット判定していたが、
        新実装は PlayerStreakState.daily_task_count_date を見る。
        """
        # 前日分の state を仕込む (NEW state のみ)
        yesterday = self.today - timedelta(days=1)
        streak = self.player.streak
        streak.daily_task_count = 5
        streak.daily_task_count_date = yesterday
        streak.save(update_fields=['daily_task_count', 'daily_task_count_date'])

        # 今日初回呼出 → yesterday との比較でリセットされてから +1 = 1
        check_friend_gift_popup_trigger(self.player, self.today)
        streak.refresh_from_db()
        self.assertEqual(
            streak.daily_task_count, 1,
            '日跨ぎリセットが streak.daily_task_count_date に反応していない = '
            '旧 PlayerProfile.daily_task_count_date を読んでいる疑い',
        )
        self.assertEqual(streak.daily_task_count_date, self.today)
