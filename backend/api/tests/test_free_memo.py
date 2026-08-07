"""【FEAT-493 (2026-07-25) / FEAT-502 (2026-07-26)】フリーメモ API 契約テスト。

検証観点:
  1. GET /api/free-memos/             — 未削除メモのみ返す (削除済は除外)
  2. GET /api/free-memos/?archived=true — 削除済メモのみ返す (内部 filter は deleted_at)
  3. POST /api/free-memos/            — 新規作成 (バリデーション含む)
  4. PATCH /api/free-memos/<id>/      — テキスト更新
  5. DELETE /api/free-memos/<id>/     — soft delete (deleted_at=now、trash 移動)
  6. POST /api/free-memos/<id>/convert-to-event/ — EXP 付与 + メモ削除 (冪等性確認)

  追加: opt-in OFF ユーザーへの 403 ガード
  追加 (FEAT-502): archived_at → deleted_at データ移行 migration の forward 検証
"""
from django.contrib.auth import get_user_model
from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.test import TestCase, TransactionTestCase
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from api.models import FreeMemo, PlayerProfile
from api.models.player_state import PlayerBattleState
from ._error_assert import error_code, error_message  # 【FEAT-515】

User = get_user_model()


def _make_opt_in_player(username: str):
    """free_memo_enabled=True の opt-in プレイヤーを作成して返す。"""
    user   = User.objects.create_user(username=username, password='pw')
    player = PlayerProfile.objects.create(user=user, name='テスター', free_memo_enabled=True)
    token  = Token.objects.create(user=user)
    return user, player, token.key


class FreeMemoListTests(TestCase):
    """テスト 1 & 2: GET /api/free-memos/ (一覧・archived フィルター)"""

    def setUp(self):
        self.client = APIClient()
        self.user, self.player, token = _make_opt_in_player('list_tester')
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token}')

        # 未削除メモ
        self.memo_a = FreeMemo.objects.create(player=self.player, text='メモA')
        self.memo_b = FreeMemo.objects.create(player=self.player, text='メモB')
        # 削除済メモ (soft delete、FEAT-502 で deleted_at に格納)
        self.memo_c = FreeMemo.objects.create(
            player=self.player,
            text='メモC (deleted)',
            deleted_at=timezone.now(),
        )

    # ── テスト 1: 未削除一覧のみ返す ──────────────────────────────────────
    def test_list_undeleted_only(self):
        """GET /api/free-memos/ → 未削除メモのみ (削除済は除外)。"""
        res = self.client.get('/api/free-memos/')
        self.assertEqual(res.status_code, 200)

        ids = [m['id'] for m in res.data['memos']]
        self.assertIn(self.memo_a.id, ids)
        self.assertIn(self.memo_b.id, ids)
        self.assertNotIn(self.memo_c.id, ids, '削除済メモは一覧に含まれない')

        self.assertEqual(res.data['count'], 2)

    # ── テスト 2: archived=true フィルター (内部 filter は deleted_at) ────────
    def test_list_archived_only(self):
        """GET /api/free-memos/?archived=true → 削除済メモのみ。"""
        res = self.client.get('/api/free-memos/', {'archived': 'true'})
        self.assertEqual(res.status_code, 200)

        ids = [m['id'] for m in res.data['memos']]
        self.assertIn(self.memo_c.id, ids)
        self.assertNotIn(self.memo_a.id, ids, '未削除メモは含まれない')
        self.assertEqual(res.data['count'], 1)

    def test_list_with_offset_returns_paginated_window(self):
        """【FEAT-498 §2.5 (2026-07-26)】?offset=N で N 件目以降を取得、
        response には offset を echo (Flutter 側で次 offset 計算に使用)。
        offset=0 (default) と一致していることも確認。
        """
        # offset=0 (省略) の response が offset=0 echo を含む
        res = self.client.get('/api/free-memos/')
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.data['offset'], 0)

        # 不正 offset (負値・非数値) は 0 として扱う (backend try/except で吸収)
        res_neg = self.client.get('/api/free-memos/', {'offset': '-5'})
        self.assertEqual(res_neg.status_code, 200)
        self.assertEqual(res_neg.data['offset'], 0)

        res_nan = self.client.get('/api/free-memos/', {'offset': 'abc'})
        self.assertEqual(res_nan.status_code, 200)
        self.assertEqual(res_nan.data['offset'], 0)

        # offset=100 (メモが少ないので空 response、has_more=False)
        res_off = self.client.get('/api/free-memos/', {'offset': '100'})
        self.assertEqual(res_off.status_code, 200)
        self.assertEqual(res_off.data['offset'], 100)
        self.assertEqual(res_off.data['count'], 0)
        self.assertFalse(res_off.data['has_more'])


class FreeMemoCreateTests(TestCase):
    """テスト 3: POST /api/free-memos/ (新規作成)"""

    def setUp(self):
        self.client = APIClient()
        self.user, self.player, token = _make_opt_in_player('create_tester')
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token}')

    def test_create_success(self):
        """POST /api/free-memos/ {text} → 201 + created memo data。"""
        res = self.client.post('/api/free-memos/', {'text': 'テストメモ'}, format='json')
        self.assertEqual(res.status_code, 201)
        self.assertEqual(res.data['text'], 'テストメモ')
        self.assertIn('id', res.data)
        self.assertIsNone(res.data['deleted_at'])

        # DB に保存されていること
        self.assertTrue(FreeMemo.objects.filter(id=res.data['id'], player=self.player).exists())

    def test_create_text_too_long_returns_400(self):
        """501 字のテキスト → 400 (free_memo_text_too_long)。"""
        long_text = 'a' * 501
        res = self.client.post('/api/free-memos/', {'text': long_text}, format='json')
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'free_memo_text_too_long')

    def test_create_empty_text_returns_400(self):
        """空文字 → 400 (free_memo_text_required)。"""
        res = self.client.post('/api/free-memos/', {'text': ''}, format='json')
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'free_memo_text_required')


class FreeMemoUpdateTests(TestCase):
    """テスト 4: PATCH /api/free-memos/<id>/ (更新)"""

    def setUp(self):
        self.client = APIClient()
        self.user, self.player, token = _make_opt_in_player('update_tester')
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token}')
        self.memo = FreeMemo.objects.create(player=self.player, text='元のテキスト')

    def test_patch_text_success(self):
        """PATCH /api/free-memos/<id>/ {text} → 200 + updated text。"""
        res = self.client.patch(
            f'/api/free-memos/{self.memo.id}/',
            {'text': '更新後のテキスト'},
            format='json',
        )
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.data['text'], '更新後のテキスト')

        self.memo.refresh_from_db()
        self.assertEqual(self.memo.text, '更新後のテキスト')

    def test_patch_other_players_memo_returns_404(self):
        """他プレイヤーのメモは 404。"""
        other_user   = User.objects.create_user(username='other@ex.com', password='pw')
        other_player = PlayerProfile.objects.create(user=other_user, free_memo_enabled=True)
        other_memo   = FreeMemo.objects.create(player=other_player, text='他人のメモ')

        res = self.client.patch(
            f'/api/free-memos/{other_memo.id}/',
            {'text': '盗み書き'},
            format='json',
        )
        self.assertEqual(res.status_code, 404)


class FreeMemoDeleteTests(TestCase):
    """テスト 5: DELETE /api/free-memos/<id>/ (完全削除 hard delete)"""

    def setUp(self):
        self.client = APIClient()
        self.user, self.player, token = _make_opt_in_player('delete_tester')
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token}')
        self.memo = FreeMemo.objects.create(player=self.player, text='削除するメモ')

    def test_delete_success(self):
        """【FEAT-500 → FEAT-502 (2026-07-26) 更新】DELETE /api/free-memos/<id>/ →
        204 かつ deleted_at が set される (soft delete、trash 移動)。
        旧仕様 (hard delete) から変更、完全削除は DELETE /purge/ に分離。
        """
        memo_id = self.memo.id
        res = self.client.delete(f'/api/free-memos/{memo_id}/')
        self.assertEqual(res.status_code, 204)

        # soft delete: DB 上には残る、deleted_at が set される
        self.memo.refresh_from_db()
        self.assertIsNotNone(
            self.memo.deleted_at,
            'soft delete 後は deleted_at が set (trash に移動)',
        )
        self.assertIsNone(
            self.memo.archived_at,
            'user 削除は archived_at (auto archive 用) を触らない (FEAT-502 分離)',
        )

    def test_restore_success(self):
        """【FEAT-500 → FEAT-502 (2026-07-26)】POST /api/free-memos/<id>/restore/ →
        deleted_at=None に戻り、通常一覧に復元される。
        """
        # 事前に soft delete しておく
        from django.utils import timezone
        self.memo.deleted_at = timezone.now()
        self.memo.save(update_fields=['deleted_at'])

        res = self.client.post(f'/api/free-memos/{self.memo.id}/restore/')
        self.assertEqual(res.status_code, 200)
        self.assertIsNone(res.data['deleted_at'])

        self.memo.refresh_from_db()
        self.assertIsNone(
            self.memo.deleted_at,
            'restore 後は deleted_at=None (通常一覧に復帰)',
        )

    def test_purge_success(self):
        """【FEAT-500 → FEAT-502 (2026-07-26)】DELETE /api/free-memos/<id>/purge/ →
        204 かつ DB から物理削除 (hard、復元不可)。
        【レビュー §C3 追加】active memo に対する直接 purge は 400、必ず
        trash 経由 (先に DELETE で soft delete → その後 purge) を強制。
        """
        # 前提: deleted state (trash) に移動
        from django.utils import timezone
        self.memo.deleted_at = timezone.now()
        self.memo.save(update_fields=['deleted_at'])

        memo_id = self.memo.id
        res = self.client.delete(f'/api/free-memos/{memo_id}/purge/')
        self.assertEqual(res.status_code, 204)

        self.assertFalse(
            FreeMemo.objects.filter(id=memo_id).exists(),
            'purge 後は DB から完全消失 (hard delete)',
        )

    def test_purge_rejects_active_memo(self):
        """【レビュー §C3 → FEAT-502】active memo (deleted_at IS NULL) への直接 purge は
        400 free_memo_not_archived で拒否、必ず trash 経由を強制する。
        """
        # setUp で作成された self.memo は active state (deleted_at=None)
        memo_id = self.memo.id
        self.assertIsNone(self.memo.deleted_at)

        res = self.client.delete(f'/api/free-memos/{memo_id}/purge/')
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'free_memo_not_archived')

        # active memo は DB に残る (purge 拒否)
        self.assertTrue(
            FreeMemo.objects.filter(id=memo_id).exists(),
            'active memo は purge 拒否で DB に残る',
        )

    def test_trash_purge_all_success(self):
        """【FEAT-498 §2.6 (2026-07-31)】DELETE /api/free-memos/trash/purge-all/ →
        204 かつ trash (deleted_at IS NOT NULL) の全 memo が DB から物理削除される。
        active memo (deleted_at IS NULL) は一切影響を受けない。
        response header X-Purged-Count に削除件数が入る。
        """
        from django.utils import timezone
        now = timezone.now()
        # trash に 3 件 seed
        trashed_ids = []
        for i in range(3):
            m = FreeMemo.objects.create(
                player=self.player, text=f'trash memo {i}', deleted_at=now,
            )
            trashed_ids.append(m.id)
        # active memo 1 件 (setUp の self.memo)、追加で 1 件も active に
        active_extra = FreeMemo.objects.create(
            player=self.player, text='active memo (残る)',
        )
        active_ids = {self.memo.id, active_extra.id}

        res = self.client.delete('/api/free-memos/trash/purge-all/')
        self.assertEqual(res.status_code, 204)
        self.assertEqual(
            res.headers.get('X-Purged-Count'), '3',
            'X-Purged-Count header で削除件数が返る',
        )

        # trash の 3 件は物理削除
        self.assertEqual(
            FreeMemo.objects.filter(id__in=trashed_ids).count(), 0,
            'trash memo は全て hard delete される',
        )
        # active の 2 件は残存
        self.assertEqual(
            FreeMemo.objects.filter(id__in=active_ids).count(), 2,
            'active memo (deleted_at IS NULL) は purge-all の影響を受けない',
        )

    def test_trash_purge_all_empty_returns_204(self):
        """【FEAT-498 §2.6】trash が空でも 204 冪等返却 (X-Purged-Count=0)、
        active memo は影響を受けない。
        """
        active_id = self.memo.id  # setUp の active memo
        res = self.client.delete('/api/free-memos/trash/purge-all/')
        self.assertEqual(res.status_code, 204)
        self.assertEqual(res.headers.get('X-Purged-Count'), '0')
        self.assertTrue(
            FreeMemo.objects.filter(id=active_id).exists(),
            'active memo は purge-all の影響を受けない (冪等契約)',
        )

    def test_trash_purge_all_isolates_players(self):
        """【FEAT-498 §2.6 Pre-mortem S4】user A の purge-all が user B の trash に
        影響を及ぼさないこと (player scope 分離)。
        """
        from django.utils import timezone
        # user B の trash memo を別 player で seed
        _, other_player, _ = _make_opt_in_player('other_player_for_purge_all')
        other_trashed = FreeMemo.objects.create(
            player=other_player, text='B の trash', deleted_at=timezone.now(),
        )
        # user A (self.player) の trash memo
        my_trashed = FreeMemo.objects.create(
            player=self.player, text='A の trash', deleted_at=timezone.now(),
        )

        res = self.client.delete('/api/free-memos/trash/purge-all/')
        self.assertEqual(res.status_code, 204)
        self.assertEqual(res.headers.get('X-Purged-Count'), '1')

        # 自分の trash は消えた
        self.assertFalse(FreeMemo.objects.filter(id=my_trashed.id).exists())
        # 他 player の trash は残る (isolation)
        self.assertTrue(FreeMemo.objects.filter(id=other_trashed.id).exists())


class FreeMemoConvertTests(TestCase):
    """テスト 6: POST /api/free-memos/<id>/convert-to-event/ (EXP 付与 + メモ削除)"""

    def setUp(self):
        self.client = APIClient()
        self.user, self.player, token = _make_opt_in_player('convert_tester')
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token}')
        self.memo = FreeMemo.objects.create(player=self.player, text='変換するメモ')

    def test_convert_to_event_awards_exp_and_deletes_memo(self):
        """POST /api/free-memos/<id>/convert-to-event/ → EXP 付与 + メモ物理削除。"""
        # battle state をあらかじめ DB に作成し current_exp を確定する
        battle_before, _ = PlayerBattleState.objects.get_or_create(player=self.player)
        exp_before = battle_before.current_exp
        memo_id    = self.memo.id

        res = self.client.post(f'/api/free-memos/{memo_id}/convert-to-event/')
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.data['converted_to'], 'event')
        self.assertGreater(res.data['exp_gain'], 0, 'EXP は 1 以上付与される')

        # メモが物理削除されていること
        self.assertFalse(
            FreeMemo.objects.filter(id=memo_id).exists(),
            '変換後メモは hard delete される',
        )

        # EXP が加算されていること (cache を経由せず DB 直読みで確認)
        exp_after = PlayerBattleState.objects.get(player=self.player).current_exp
        self.assertGreater(
            exp_after, exp_before,
            'convert 後は current_exp が増加している (level up がない前提)',
        )

    def test_convert_to_todo_returns_correct_type(self):
        """POST /api/free-memos/<id>/convert-to-todo/ → converted_to='todo'。"""
        memo = FreeMemo.objects.create(player=self.player, text='ToDo 変換メモ')
        res  = self.client.post(f'/api/free-memos/{memo.id}/convert-to-todo/')
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.data['converted_to'], 'todo')

    def test_convert_to_habit_returns_correct_type(self):
        """POST /api/free-memos/<id>/convert-to-habit/ → converted_to='habit'。"""
        memo = FreeMemo.objects.create(player=self.player, text='習慣 変換メモ')
        res  = self.client.post(f'/api/free-memos/{memo.id}/convert-to-habit/')
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.data['converted_to'], 'habit')


class FreeMemoOptInGateTests(TestCase):
    """opt-in OFF ユーザーへの 403 ガード。"""

    def setUp(self):
        self.client = APIClient()
        user   = User.objects.create_user(username='optout@ex.com', password='pw')
        # 【2026-07-25 修正】default 変更後 (kill-switch 化) の適応:
        # PlayerProfile.free_memo_enabled default は True になったため、
        # 「ユーザーが明示 OFF にした時の 403 ガード」を検証するには free_memo_enabled=False
        # を明示指定する必要がある。テスト意図は今も valid。
        PlayerProfile.objects.create(user=user, name='無効ユーザー', free_memo_enabled=False)
        token  = Token.objects.create(user=user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token.key}')

    def test_list_returns_403_when_disabled(self):
        """opt-in OFF → GET /api/free-memos/ は 403 (free_memo_disabled)。"""
        res = self.client.get('/api/free-memos/')
        self.assertEqual(res.status_code, 403)
        self.assertEqual(error_code(res), 'free_memo_disabled')

    def test_create_returns_403_when_disabled(self):
        """opt-in OFF → POST /api/free-memos/ は 403。"""
        res = self.client.post('/api/free-memos/', {'text': 'テスト'}, format='json')
        self.assertEqual(res.status_code, 403)
        self.assertEqual(error_code(res), 'free_memo_disabled')


class FreeMemoDeletedAtMigrationTests(TransactionTestCase):
    """【FEAT-502 (2026-07-26)】archived_at → deleted_at データ移行 migration 検証。

    0189 の RunPython (_migrate_archived_to_deleted) が「archived_at IS NOT NULL の
    既存行を deleted_at へ移動、archived_at をクリア」を正しく行うことを、
    実際の migration を巻き戻し → データ投入 → forward 適用の順で assert する
    (Pre-mortem S1: prod 適用前の forward-migrate 動作保証)。
    """

    APP = 'api'
    BEFORE = ('api', '0188_boss_reward_exp_monotonic')
    AFTER  = ('api', '0189_free_memo_deleted_at')

    def tearDown(self):
        # 後続テストへ schema drift を残さないよう、最新 migration state に戻す。
        executor = MigrationExecutor(connection)
        executor.migrate(executor.loader.graph.leaf_nodes())

    def test_archived_rows_forward_migrate_to_deleted(self):
        # ── 1) deleted_at 追加前 (0188) まで巻き戻す ──
        executor = MigrationExecutor(connection)
        executor.migrate([self.BEFORE])
        old_apps = executor.loader.project_state([self.BEFORE]).apps

        PlayerProfile = old_apps.get_model(self.APP, 'PlayerProfile')
        FreeMemo      = old_apps.get_model(self.APP, 'FreeMemo')

        player   = PlayerProfile.objects.create(name='移行テスター')
        archived = FreeMemo.objects.create(
            player=player, text='ユーザー削除メモ', archived_at=timezone.now(),
        )
        active = FreeMemo.objects.create(player=player, text='通常メモ')

        # ── 2) 0189 を forward 適用 (deleted_at 追加 + データ移行) ──
        executor = MigrationExecutor(connection)
        executor.migrate([self.AFTER])
        new_apps = executor.loader.project_state([self.AFTER]).apps
        FreeMemoNew = new_apps.get_model(self.APP, 'FreeMemo')

        moved = FreeMemoNew.objects.get(pk=archived.pk)
        self.assertIsNotNone(
            moved.deleted_at, 'archived_at 由来行は deleted_at に移動される',
        )
        self.assertIsNone(
            moved.archived_at, '移行後 archived_at はクリアされる (誤 auto-archive 判定を防ぐ)',
        )

        untouched = FreeMemoNew.objects.get(pk=active.pk)
        self.assertIsNone(untouched.deleted_at, '通常メモは deleted_at=None のまま')
        self.assertIsNone(untouched.archived_at, '通常メモは archived_at=None のまま')
