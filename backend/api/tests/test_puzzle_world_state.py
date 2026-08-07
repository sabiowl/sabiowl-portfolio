"""【FEAT-479 Phase 5 (2026-07-06)】ジグソーパズル世界システム 契約テスト。

指示書: doc/instructions/FEAT-479_puzzle_world_ver1.md §10 §11

契約シナリオ (12 テスト、指示書 Pre-mortem S1-S8 に対応):
1. 初回 task piece 付与 (active_scene 設定済)
2. active_scene 未設定 → task piece 発火せず
3. 同日 2 回目 → task piece None (idempotency、指示書 S2)
4. 通常 quest piece color 化 (grey → colored)
5. 完成路径 → 報酬付与 + history 作成 (指示書 S6)
6. 完成時 next_scene_hint 正確 (未着手シーンあり) (指示書 S5)
7. 完成時 next_scene_hint=None (エンドコンテンツ、全シーン完成)
8. select_active_scene 完成シーン拒否 (指示書 S6)
9. select_active_scene 非公開シーン拒否 (is_active=False)
10. select_displayed_scene 未着手シーン拒否
11. select_displayed_scene None (自動 fallback) 許容
12. シーン跨ぎで同日 task piece 制限 (指示書 S2、プレイヤー単位管理)
"""
from datetime import date, datetime, timedelta

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone as _tz

from api.models import (
    PlayerProfile,
    PlayerPuzzleSceneProgress,
    PlayerPuzzleWorld,
    PlayerPuzzleWorldHistory,
    PuzzleWorldScene,
)
from api.services.puzzle_world_service import (
    select_active_scene,
    select_displayed_scene,
    try_grant_quest_piece,
    try_grant_task_piece,
)
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

User = get_user_model()


class PuzzleWorldServiceTests(TestCase):
    """Backend puzzle_world_service の契約テスト (指示書 §10 準拠、12 シナリオ)。"""

    @classmethod
    def setUpTestData(cls):
        # 【FEAT-479 v1 (2026-07-07 pivot)】seed は 3 シーン (morning_grassland
        # 3 ピース / noon_castle_town 30 ピース / night_forest_camp 30 ピース)。
        # is_tutorial=False フィルタは無 rows で no-op だが、将来の tutorial 拡張に
        # 備えて残す。
        # 【piece_count 混在対応】self.scenes[0]=morning_grassland は 3 ピースに
        # なったため、以下 tests は scene.piece_count を動的に参照して piece_states
        # を組む。silent auto-activate 契約は
        # test_task_piece_no_active_scene_silent_activates_morning_grassland で個別検証。
        cls.scenes = list(
            PuzzleWorldScene.objects.filter(is_tutorial=False)
            .order_by('display_order')
        )
        assert len(cls.scenes) == 3, 'seed 3 本編シーンが必要 (is_tutorial=False)'

    def setUp(self):
        # プレイヤー 1 体 (テスト間で分離、setUp で毎回作成)
        self.user = User.objects.create_user(
            username=f'puzzle_test_{id(self)}',
            email=f'puzzle_test_{id(self)}@sabiowl.local',
        )
        self.player = PlayerProfile.objects.create(
            user=self.user, name='TestPuzzler', gender='f',
        )
        # test 定数
        self.today = date.today()

    # ─────────────────────────────────────────────────────────────────────────
    # Task piece 発火経路 (指示書 §3.2、Pre-mortem S2)
    # ─────────────────────────────────────────────────────────────────────────

    def test_task_piece_awarded_first_time(self):
        """active_scene 設定済 → 初回で piece 付与 (state=1、scene_key 正確)。"""
        select_active_scene(self.player, self.scenes[0])
        # streak flag をリセット (select_active_scene が触らないが念のため)
        self.player.streak.last_task_piece_date = None
        self.player.streak.save()

        result = try_grant_task_piece(self.player, self.today)

        self.assertIsNotNone(result)
        self.assertEqual(result['new_state'], 1)
        self.assertEqual(result['scene_key'], self.scenes[0].key)
        # 【FEAT-479 v1 pivot (2026-07-07)】scene.piece_count に対応
        # (morning_grassland=3、noon/night=30)。
        self.assertIn(result['piece_index'], range(self.scenes[0].piece_count))

    def test_status_get_auto_activates_morning_grassland_for_fresh_user(self):
        """【FEAT-479 v1 hotfix (2026-07-07 pivot)】GET /api/puzzle-world/ で
        新規ユーザーの active_scene が自動的に morning_grassland (目覚めの山頂、
        3 ピース) に set されることを契約化。

        ユーザー要求: 「最初は全ユーザ『目覚めの山頂』を選ぶ仕様にし、ワールドフレームを
        3 分割で隠してください」

        旧挙動: silent auto-activate は最初のタスク達成でのみ発火 → guest-init 直後
        の home 訪問で active_scene=null のまま返り、Mobile 側 fallback 経路で
        「かけらがすべて揃った状態」に見える bug (screenshot 事例)。

        新挙動: GET /api/puzzle-world/ でも silent auto-activate 発火 → 初回 GET で
        active_scene=morning_grassland、piece_states=[0,0,0]、is_completed=False
        を返し、Mobile 側で 3-strip overlay 描画。
        """
        # 事前は PlayerPuzzleWorld 自体が未作成
        self.assertFalse(
            PlayerPuzzleWorld.objects.filter(player=self.player).exists()
        )

        # 認証 client 経由で GET
        token, _ = Token.objects.get_or_create(user=self.user)
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION=f'Token {token.key}')
        response = client.get('/api/puzzle-world/')

        self.assertEqual(response.status_code, 200)
        data = response.json()

        # active_scene が返されていること
        self.assertIsNotNone(data['active_scene'], 'active_scene が auto-set されていない')
        self.assertEqual(data['active_scene']['key'], 'morning_grassland')
        self.assertEqual(data['active_scene']['piece_count'], 3)
        self.assertEqual(data['active_scene']['piece_states'], [0, 0, 0])
        self.assertFalse(data['active_scene']['is_completed'])

        # 履歴は空
        self.assertEqual(data['history'], [])

        # DB 側でも active_scene が backfill されていること
        world = PlayerPuzzleWorld.objects.get(player=self.player)
        self.assertEqual(world.active_scene.key, 'morning_grassland')

    def test_status_get_no_op_when_active_already_set(self):
        """既存 active_scene 設定済ユーザーは GET で no-op (副作用なし)。"""
        # 事前に noon_castle_town を active に設定
        select_active_scene(self.player, self.scenes[1])
        self.assertEqual(
            PlayerPuzzleWorld.objects.get(player=self.player).active_scene.key,
            'noon_castle_town',
        )

        token, _ = Token.objects.get_or_create(user=self.user)
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION=f'Token {token.key}')
        response = client.get('/api/puzzle-world/')

        self.assertEqual(response.status_code, 200)
        # active_scene が noon_castle_town のまま (morning_grassland に上書きされない)
        self.assertEqual(response.json()['active_scene']['key'], 'noon_castle_town')

    def test_task_piece_no_active_scene_silent_activates_morning_grassland(self):
        """【FEAT-479 v1 (2026-07-07 pivot)】active_scene 未設定でも
        silent auto-activate (morning_grassland「目覚めの山頂」、3 ピース) して piece 付与。

        設計履歴:
        - 2026-07-06 hotfix: morning_grassland (30 ピース) を default 化
        - 2026-07-07 早朝: 別チュートリアルシーン first_light (3 ピース) 案
        - 2026-07-07 pivot: 別シーンを増やさず morning_grassland 自体を 3 ピース化
          + default 復帰 (シーン数を増やさない simpler UX)
        """
        # 事前は PlayerPuzzleWorld 自体が未作成 (setUp で PlayerProfile 作成のみ)
        self.assertFalse(
            PlayerPuzzleWorld.objects.filter(player=self.player).exists()
        )

        result = try_grant_task_piece(self.player, self.today)

        # silent auto-activate 経由で piece 付与されること
        self.assertIsNotNone(result)
        self.assertEqual(result['new_state'], 1)
        self.assertEqual(result['scene_key'], 'morning_grassland')

        # active_scene が backfill されていること (get_or_create + auto-set)
        world = PlayerPuzzleWorld.objects.get(player=self.player)
        self.assertIsNotNone(world.active_scene_id)
        self.assertEqual(world.active_scene.key, 'morning_grassland')
        # 3 ピース化されていることを確認 (0178 migration 効果)
        self.assertEqual(world.active_scene.piece_count, 3)

    def test_task_piece_same_day_returns_none(self):
        """同日 2 回目 → None (Pre-mortem S2 idempotency)。"""
        select_active_scene(self.player, self.scenes[0])
        self.player.streak.last_task_piece_date = None
        self.player.streak.save()

        first = try_grant_task_piece(self.player, self.today)
        second = try_grant_task_piece(self.player, self.today)

        self.assertIsNotNone(first)
        self.assertIsNone(second)  # 同日 2 回目は None

    def test_task_piece_cross_scene_same_day_still_blocked(self):
        """シーン切替後も同日は再発火しない (Pre-mortem S2、プレイヤー単位管理)。

        指示書 §3.2 の設計:
        「シーンを切り替えても、同日 2 回目の task/quest piece は発火しない
          (= 進行を分散させても 1 日 1 枚上限は破れない)」
        """
        select_active_scene(self.player, self.scenes[0])
        self.player.streak.last_task_piece_date = None
        self.player.streak.save()
        first = try_grant_task_piece(self.player, self.today)

        # 別シーンに切替 → 同日 task_piece は発火しないはず
        select_active_scene(self.player, self.scenes[1])
        second = try_grant_task_piece(self.player, self.today)

        self.assertIsNotNone(first)
        self.assertIsNone(second)

    def test_task_piece_no_unowned_returns_none(self):
        """active_scene の全ピース取得済 → None (state=0 が 0 個)。"""
        select_active_scene(self.player, self.scenes[0])
        n = self.scenes[0].piece_count
        progress, _ = PlayerPuzzleSceneProgress.objects.get_or_create(
            player=self.player, scene=self.scenes[0],
            defaults={'piece_states': [1] * n},
        )
        progress.piece_states = [1] * n  # 全 grey (未取得 0 個)
        progress.save()
        self.player.streak.last_task_piece_date = None
        self.player.streak.save()

        result = try_grant_task_piece(self.player, self.today)
        self.assertIsNone(result)

    # ─────────────────────────────────────────────────────────────────────────
    # Quest piece 発火経路 (指示書 §3.2、Pre-mortem S5)
    # ─────────────────────────────────────────────────────────────────────────

    def test_quest_piece_colors_grey_normally(self):
        """通常 quest piece: state=1 が state=2 に、scene_completed=False。

        「完成しない範囲での color 化」を検証するため、noon_castle_town (30 ピース)
        を使う (morning_grassland は 3 ピースで、1 grey + 残り未取得だと 1 個 color
        化で `scene_completed=False` と `True` の境界を狙いにくい)。
        """
        scene = self.scenes[1]  # noon_castle_town, 30 ピース
        select_active_scene(self.player, scene)
        # 5 grey + 残り未取得 (未完成状態)
        initial_states = [1] * 5 + [0] * (scene.piece_count - 5)
        progress, _ = PlayerPuzzleSceneProgress.objects.get_or_create(
            player=self.player, scene=scene,
            defaults={'piece_states': initial_states},
        )
        progress.piece_states = initial_states
        progress.save()
        self.player.streak.last_quest_piece_date = None
        self.player.streak.save()

        result = try_grant_quest_piece(self.player, self.today)

        self.assertIsNotNone(result)
        self.assertEqual(result['new_state'], 2)
        self.assertFalse(result['scene_completed'])

    def test_quest_piece_completes_scene_with_rewards(self):
        """最後の 1 枚 grey → color 化で scene_completed=True + 報酬 + history 作成。"""
        scene = self.scenes[0]  # morning_grassland (3 ピース) でもロジックは同一
        select_active_scene(self.player, scene)
        n = scene.piece_count
        # (n-1) colored + 1 grey で「完成 1 手前」
        pre_complete = [2] * (n - 1) + [1]
        progress, _ = PlayerPuzzleSceneProgress.objects.get_or_create(
            player=self.player, scene=scene,
            defaults={'piece_states': pre_complete},
        )
        progress.piece_states = pre_complete
        progress.save()
        self.player.streak.last_quest_piece_date = None
        self.player.streak.save()

        # 経済状態の初期値記録
        eco_before = self.player.economy.diamonds
        exp_before = self.player.battle.current_exp

        result = try_grant_quest_piece(self.player, self.today)

        self.assertIsNotNone(result)
        self.assertTrue(result['scene_completed'])
        self.assertEqual(result['reward_diamonds'], scene.reward_diamonds)
        self.assertEqual(result['reward_exp'], scene.reward_exp)

        # progress.completed_at が set されている
        progress.refresh_from_db()
        self.assertIsNotNone(progress.completed_at)

        # 完成履歴 1 件作成
        self.assertEqual(
            PlayerPuzzleWorldHistory.objects.filter(
                player=self.player, scene=scene,
            ).count(),
            1,
        )

        # 経済状態に反映 (シーン報酬 = scene.reward_diamonds 分の増分)
        self.player.refresh_from_db()
        self.assertEqual(
            self.player.economy.diamonds, eco_before + scene.reward_diamonds,
        )
        # exp は level up の可能性ありのため単純増加とは限らない
        _ = exp_before

        # 【FEAT-479 v1 (2026-07-08)】完成 scene が displayed_scene に自動セット。
        # ユーザーが次に別 active_scene を選んで作業を始めても、
        # 完成した景色がワールドフレームでアニメ表示され続ける契約を担保。
        world = PlayerPuzzleWorld.objects.get(player=self.player)
        self.assertEqual(
            world.displayed_scene_id, scene.id,
            '完成時に displayed_scene が完成 scene に自動セットされていない',
        )

    def test_quest_piece_completion_overwrites_prior_displayed(self):
        """【FEAT-479 v1 (2026-07-08)】完成時 displayed 自動セットは常に上書き。

        既に別 scene が displayed に設定済 (別完成シーン or user 手動選択) でも、
        新たな完成が起きたら **直近完成が最新の体験の対象** として上書きする契約。
        user が旧 displayed に戻したい場合は SceneSelectionPage で明示再設定可能。
        """
        # scene[1] (noon_castle_town, 30 ピース) を事前に完成させて displayed に設定。
        # noon_castle_town を「以前完成した scene」役として使う (下記 scene[0] を今回
        # 完成させるため、両 scene の識別を分離)。
        prior_scene = self.scenes[1]
        prior_states = [2] * prior_scene.piece_count
        PlayerPuzzleSceneProgress.objects.create(
            player=self.player, scene=prior_scene,
            piece_states=prior_states,
            completed_at=_tz.now(),
        )
        # PlayerPuzzleWorld を作成 + prior_scene を displayed に手動設定。
        world, _ = PlayerPuzzleWorld.objects.get_or_create(player=self.player)
        select_displayed_scene(self.player, prior_scene)  # displayed=noon_castle_town
        world.refresh_from_db()
        self.assertEqual(world.displayed_scene_id, prior_scene.id)  # sanity

        # 今回完成させる scene (morning_grassland, 3 ピース) を active に。
        completing_scene = self.scenes[0]
        select_active_scene(self.player, completing_scene)
        n = completing_scene.piece_count
        pre_complete = [2] * (n - 1) + [1]
        progress, _ = PlayerPuzzleSceneProgress.objects.get_or_create(
            player=self.player, scene=completing_scene,
            defaults={'piece_states': pre_complete},
        )
        progress.piece_states = pre_complete
        progress.save()
        self.player.streak.last_quest_piece_date = None
        self.player.streak.save()

        result = try_grant_quest_piece(self.player, self.today)

        self.assertIsNotNone(result)
        self.assertTrue(result['scene_completed'])

        # displayed が prior_scene から completing_scene に上書きされている
        world.refresh_from_db()
        self.assertEqual(
            world.displayed_scene_id, completing_scene.id,
            '完成時に displayed_scene が新完成 scene に上書きされていない '
            '(prior_scene のまま残っていたら「常に上書き」契約違反)',
        )

    def test_quest_piece_completion_next_scene_hint(self):
        """完成時に未着手シーンがあれば next_scene_hint=display_order 順の 1 件を返す。"""
        scene = self.scenes[0]
        select_active_scene(self.player, scene)
        n = scene.piece_count
        pre_complete = [2] * (n - 1) + [1]
        progress, _ = PlayerPuzzleSceneProgress.objects.get_or_create(
            player=self.player, scene=scene,
            defaults={'piece_states': pre_complete},
        )
        progress.piece_states = pre_complete
        progress.save()
        self.player.streak.last_quest_piece_date = None
        self.player.streak.save()

        result = try_grant_quest_piece(self.player, self.today)

        # next_scene_hint は未着手 (progress レコード無し) シーンから display_order 最小
        # 現アクティブ (self.scenes[0]) は already started → 除外
        # 残る 2 シーン (display_order 2, 3) の 1 つ目 = display_order=2 のはず
        self.assertIsNotNone(result['next_scene_hint'])
        self.assertEqual(result['next_scene_hint']['scene_key'], self.scenes[1].key)

    def test_quest_piece_completion_no_more_scenes_end_content(self):
        """全 3 シーン完成 (最後の完成) → next_scene_hint=None (エンドコンテンツ)。"""
        # 全 3 シーンを事前に completed 状態にする (最後の 1 シーンだけ 1 枚 grey で残す)。
        # scene.piece_count が混在するため各 scene の piece_count に合わせる。
        for scene in self.scenes[:2]:
            progress = PlayerPuzzleSceneProgress.objects.create(
                player=self.player, scene=scene,
                piece_states=[2] * scene.piece_count, completed_at=_tz.now(),
            )
            PlayerPuzzleWorldHistory.objects.create(
                player=self.player, scene=scene,
                reward_exp_gained=scene.reward_exp,
                reward_diamonds_gained=scene.reward_diamonds,
            )
            _ = progress

        # 最後のシーンを active にして 1 枚 grey で残す
        last_scene = self.scenes[2]
        select_active_scene(self.player, last_scene)
        n = last_scene.piece_count
        pre_complete = [2] * (n - 1) + [1]
        last_progress, _ = PlayerPuzzleSceneProgress.objects.get_or_create(
            player=self.player, scene=last_scene,
            defaults={'piece_states': pre_complete},
        )
        last_progress.piece_states = pre_complete
        last_progress.save()
        self.player.streak.last_quest_piece_date = None
        self.player.streak.save()

        result = try_grant_quest_piece(self.player, self.today)

        # 最後の完成 → next_scene_hint=None
        self.assertIsNotNone(result)
        self.assertTrue(result['scene_completed'])
        self.assertIsNone(result['next_scene_hint'])

    def test_quest_piece_no_grey_returns_none(self):
        """grey (state=1) ピースが 0 個 → None (完成済 all 2 or 未取得 all 0)。"""
        scene = self.scenes[0]
        select_active_scene(self.player, scene)
        n = scene.piece_count
        progress, _ = PlayerPuzzleSceneProgress.objects.get_or_create(
            player=self.player, scene=scene,
            defaults={'piece_states': [0] * n},
        )
        progress.piece_states = [0] * n  # 全て未取得 (grey ピース 0 個)
        progress.save()
        self.player.streak.last_quest_piece_date = None
        self.player.streak.save()

        result = try_grant_quest_piece(self.player, self.today)
        self.assertIsNone(result)

    # ─────────────────────────────────────────────────────────────────────────
    # select_active_scene / select_displayed_scene の契約 (指示書 §3.2 §3.6)
    # ─────────────────────────────────────────────────────────────────────────

    def test_select_active_scene_completed_scene_rejects(self):
        """完成済シーンを再度 active 化しようとすると ValueError

        (指示書 S6: 「もう命が宿った景色を再度救う」概念矛盾を回避)。
        """
        # scenes[0] を完成扱いにする (piece_count に合わせた配列)
        PlayerPuzzleSceneProgress.objects.create(
            player=self.player, scene=self.scenes[0],
            piece_states=[2] * self.scenes[0].piece_count, completed_at=_tz.now(),
        )

        with self.assertRaises(ValueError) as ctx:
            select_active_scene(self.player, self.scenes[0])
        self.assertEqual(str(ctx.exception), 'scene_already_completed')

    def test_select_active_scene_inactive_rejects(self):
        """is_active=False のシーンは選択拒否 (`scene_not_active`)。"""
        self.scenes[0].is_active = False
        self.scenes[0].save(update_fields=['is_active'])

        with self.assertRaises(ValueError) as ctx:
            select_active_scene(self.player, self.scenes[0])
        self.assertEqual(str(ctx.exception), 'scene_not_active')

    def test_select_displayed_scene_unstarted_rejects(self):
        """未着手シーン (progress レコード無し) を displayed に選択拒否

        (指示書 §3.6: 「着手 = 表示解禁の報酬性を維持」)。
        """
        with self.assertRaises(ValueError) as ctx:
            select_displayed_scene(self.player, self.scenes[0])
        self.assertEqual(str(ctx.exception), 'scene_not_available')

    def test_select_displayed_scene_none_allowed(self):
        """None 指定 (自動 fallback) は常に許容 (指示書 §3.6 優先順位 3)。"""
        # None は例外を投げず、world.displayed_scene が None にリセットされる
        select_displayed_scene(self.player, None)
        world = PlayerPuzzleWorld.objects.get(player=self.player)
        self.assertIsNone(world.displayed_scene_id)

    def test_select_displayed_scene_active_allowed(self):
        """active_scene として選択済のシーンは displayed にも指定可能。"""
        select_active_scene(self.player, self.scenes[0])
        # active_scene = scenes[0] を displayed にも set → 拒否されない
        select_displayed_scene(self.player, self.scenes[0])
        world = PlayerPuzzleWorld.objects.get(player=self.player)
        self.assertEqual(world.displayed_scene_id, self.scenes[0].id)

    def test_select_displayed_scene_completed_allowed(self):
        """完成済シーンは displayed に指定可能 (指示書 §3.6、着手済のため報酬性 OK)。"""
        # scenes[1] を完成扱いに (progress + completed_at set)
        PlayerPuzzleSceneProgress.objects.create(
            player=self.player, scene=self.scenes[1],
            piece_states=[2] * 30, completed_at=_tz.now(),
        )

        # active は別シーンに設定、displayed は完成済シーンを指定 → 許容
        select_active_scene(self.player, self.scenes[0])
        select_displayed_scene(self.player, self.scenes[1])
        world = PlayerPuzzleWorld.objects.get(player=self.player)
        self.assertEqual(world.displayed_scene_id, self.scenes[1].id)
