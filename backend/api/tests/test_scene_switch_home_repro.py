"""【2026-07-09】user 報告バグ再現テスト。

「目覚めの山頂」完成 → SceneSelectionPage で「昼の城下町」の「生命を宿す」を押下 →
ホーム画面 (/api/home/ + /api/puzzle-world/) 取得 のフローが 5xx を返さないか。

user 報告フローを 5 STEP で完全再現:
S1: 新規 player 作成、morning_grassland を active に auto-set (GET /api/puzzle-world/)
S2: morning_grassland を完成させる (try_grant_quest_piece の完成分岐、3 piece 全 color 化)
S3: SceneSelectionPage を開く (GET /api/puzzle-world/scenes/)
S4: 「昼の城下町」の「生命を宿す」(POST /api/puzzle-world/active/)
S5: ホームに戻る (GET /api/home/ + GET /api/puzzle-world/)

STEP ごとに status_code=200 を assert、5xx が出た瞬間に repro 成功。
"""
from datetime import date as date_type

from django.contrib.auth import get_user_model
from django.test import override_settings
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import (
    PlayerProfile, PlayerPuzzleSceneProgress, PuzzleWorldScene,
)
from api.services.puzzle_world_service import try_grant_quest_piece

User = get_user_model()


_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'api.authentication.ExpiringTokenAuthentication',
        'api.authentication.GuestTokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': ['rest_framework.permissions.IsAuthenticated'],
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
}


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class SceneSwitchToHomeReproTest(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(username='u1', password='pw')
        self.player = PlayerProfile.objects.create(user=self.user, name='P1')
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    def test_full_flow_scene_completion_switch_home_returns_200(self):
        # ── S1: 初回 /api/puzzle-world/ で morning_grassland が active に auto-set ──
        r1 = self.client.get('/api/puzzle-world/')
        self.assertEqual(r1.status_code, 200, msg=f'S1: {r1.status_code} body={r1.data}')
        self.assertIsNotNone(r1.data['active_scene'])
        self.assertEqual(r1.data['active_scene']['key'], 'morning_grassland')

        # ── S2: morning_grassland を完成 (3 piece 全 color 化) ──
        morning = PuzzleWorldScene.objects.get(key='morning_grassland')
        progress, _ = PlayerPuzzleSceneProgress.objects.get_or_create(
            player=self.player, scene=morning,
            defaults={'piece_states': [1, 1, 1]},
        )
        # 事前準備: 3 piece すべて grey (state=1) 状態にする
        progress.piece_states = [1, 1, 1]
        progress.save(update_fields=['piece_states'])

        # 3 回連続で try_grant_quest_piece を呼ぶと 3 piece 全 color 化 = 完成発火
        # (実際の user は 3 日かけて達成、last_quest_piece_date guard を回避するため
        # 日付を毎回変えて発火させる)
        today = date_type.today()
        from datetime import timedelta
        for i in range(3):
            self.player.refresh_from_db()
            streak = self.player.streak
            streak.last_quest_piece_date = today - timedelta(days=10 - i)
            streak.save(update_fields=['last_quest_piece_date'])
            result = try_grant_quest_piece(self.player, today - timedelta(days=9 - i))
            self.assertIsNotNone(result, f'S2 iter {i}: try_grant_quest_piece が None')

        # 完成状態確認
        progress.refresh_from_db()
        self.assertEqual(progress.piece_states, [2, 2, 2], 'S2: 3 piece 全 color 化されているはず')
        self.assertIsNotNone(progress.completed_at, 'S2: completed_at が set されているはず')

        # ── S3: SceneSelectionPage GET /api/puzzle-world/scenes/ ──
        r3 = self.client.get('/api/puzzle-world/scenes/')
        self.assertEqual(r3.status_code, 200, msg=f'S3: {r3.status_code} body={r3.data}')

        # ── S4: POST /api/puzzle-world/active/ で noon_castle_town に切替 ──
        r4 = self.client.post(
            '/api/puzzle-world/active/',
            data={'scene_key': 'noon_castle_town'},
            format='json',
        )
        self.assertEqual(r4.status_code, 200, msg=f'S4: {r4.status_code} body={r4.data}')

        # ── S5-A: ホームに戻る = GET /api/home/ ──
        r5a = self.client.get('/api/home/')
        self.assertEqual(r5a.status_code, 200, msg=f'S5-A /api/home/: {r5a.status_code} body={r5a.data}')

        # ── S5-B: WorldFrame refresh = GET /api/puzzle-world/ ──
        r5b = self.client.get('/api/puzzle-world/')
        self.assertEqual(r5b.status_code, 200, msg=f'S5-B /api/puzzle-world/: {r5b.status_code} body={r5b.data}')
        # active_scene が noon_castle_town になっているはず
        self.assertEqual(r5b.data['active_scene']['key'], 'noon_castle_town')

        # ── S5-C: SceneList 再取得 = GET /api/puzzle-world/scenes/ ──
        r5c = self.client.get('/api/puzzle-world/scenes/')
        self.assertEqual(r5c.status_code, 200, msg=f'S5-C /api/puzzle-world/scenes/: {r5c.status_code} body={r5c.data}')

        # ── 【bug 調査 2026-07-09】user 報告: home で noon が active なのに
        #    morning_grassland 空状態が表示されている問題を repro する。
        #    Mobile _resolveSceneRender の branch (A) 発火に必要な 3 条件を検証。 ──
        active = r5b.data['active_scene']
        self.assertIsNotNone(active, '前提: active_scene が返却されるはず')
        self.assertEqual(active['key'], 'noon_castle_town', 'active_scene.key = noon')
        # (A) 発火に必要な条件 1: active.is_completed=False
        self.assertFalse(active['is_completed'], 'active は未完成のはず')
        # (A) 発火に必要な条件 2: background_key が Mobile の resolveMap に entry あり
        self.assertEqual(active['background_key'], 'noon_castle_town',
                         'background_key = noon_castle_town (Mobile 側で asset path 解決可能)')
        # (A) 発火に必要な条件 3: piece_states がある
        self.assertIn('piece_states', active, 'piece_states フィールドが存在')
        self.assertEqual(len(active['piece_states']), 30, 'noon の piece_states は 30 要素')
        # → 上記全て満たせば Mobile branch (A) で noon が overlay 付きで表示される

        # ── displayed_scene の追従確認 ──
        # 完成時に world.displayed_scene = morning_grassland が set された後、
        # select_active(noon) で displayed も noon に同期切替されるはず
        displayed = r5b.data['displayed_scene']
        self.assertIsNotNone(displayed, 'displayed_scene もあるはず')
        self.assertEqual(displayed['key'], 'noon_castle_town',
                         'displayed も noon に切替 (completion → select_active_scene の一貫性)')

    def test_user_explicit_displayed_override_persists(self):
        """【2026-07-09 bug repro】user が「ホームに表示」で明示的に完成 scene に
        override した際、Backend が正しく displayed_scene を切替えることを保証。

        Mobile 側の _resolveSceneRender bug (branch A が active を最優先し、
        user の explicit displayed override を無視する) の Backend regression 防止。
        """
        # ── setup: morning_grassland を 3 piece 完成 → noon に active 切替 ──
        # (test_full_flow と同じ pre-condition を再構築)
        self.client.get('/api/puzzle-world/')  # morning auto-active
        morning = PuzzleWorldScene.objects.get(key='morning_grassland')
        progress, _ = PlayerPuzzleSceneProgress.objects.get_or_create(
            player=self.player, scene=morning,
            defaults={'piece_states': [1, 1, 1]},
        )
        progress.piece_states = [1, 1, 1]
        progress.save(update_fields=['piece_states'])

        from datetime import timedelta
        today = date_type.today()
        for i in range(3):
            self.player.refresh_from_db()
            streak = self.player.streak
            streak.last_quest_piece_date = today - timedelta(days=10 - i)
            streak.save(update_fields=['last_quest_piece_date'])
            try_grant_quest_piece(self.player, today - timedelta(days=9 - i))

        # noon を active に切替
        self.client.post('/api/puzzle-world/active/',
                         data={'scene_key': 'noon_castle_town'}, format='json')

        # ── user 明示 override: displayed = morning_grassland (完成済み) ──
        r_disp = self.client.post(
            '/api/puzzle-world/displayed/',
            data={'scene_key': 'morning_grassland'},
            format='json',
        )
        self.assertEqual(r_disp.status_code, 200, msg=f'displayed 切替: {r_disp.status_code} body={r_disp.data}')

        # ── home 再取得: active = noon、displayed = morning_grassland (別々) ──
        r_home = self.client.get('/api/puzzle-world/')
        self.assertEqual(r_home.status_code, 200)
        active    = r_home.data['active_scene']
        displayed = r_home.data['displayed_scene']

        self.assertEqual(active['key'], 'noon_castle_town',
                         'active は noon のまま (未完成、user は継続作業中)')
        self.assertFalse(active['is_completed'],
                         'active noon は未完成')
        self.assertEqual(displayed['key'], 'morning_grassland',
                         'displayed は user 明示 override で morning に切替済')

        # ── Mobile 側 branch (A0) 発火条件を assert ──
        # displayed.key != active.scene.key が成立している = user override 状態
        self.assertNotEqual(displayed['key'], active['key'],
                            'displayed != active であることが Mobile branch (A0) 発火の signal')

