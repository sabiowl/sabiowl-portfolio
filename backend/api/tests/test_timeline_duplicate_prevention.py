"""【FEAT-370 (2026-05-28)】BUG-70 構造解消の契約テスト。

検証対象:
1. `TimelineListView.post` の二重 POST → 200 + 既存 event 返却 (IntegrityError catch 経路)
2. 同タイトル + 同日 + **異なる** start_time → 別 event として 201 (両方 DB に保存される)
3. 同タイトル + 同日 + **両方 NULL** start_time → 200 + 既存返却 (no-starttime constraint 経路)
4. `cleanup_duplicate_timeline_events --dry-run` で削除されないこと
5. `cleanup_duplicate_timeline_events --confirm` で最古 (pk 最小) を残し他を削除

migration 0100 が適用された前提。シナリオ 4-5 は Django TestCase のトランザクション
ロールバックを使って DDL (DROP INDEX) を自動復元する手法を採用するため、
テスト間の constraint 状態汚染が発生しない。
"""
from datetime import date as date_type, time as time_type
from io import StringIO

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.db import connection
from django.test import TestCase, override_settings
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import PlayerProfile, TimelineEvent

User = get_user_model()

# throttle / 認証クラスの最小構成 (test_timeline_list_filters.py を踏襲)
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


# ══════════════════════════════════════════════════════════════════════════════
# シナリオ 1-3: TimelineListView.post の IntegrityError catch 契約
# ══════════════════════════════════════════════════════════════════════════════

@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class TimelineDuplicatePostTest(APITestCase):
    """TimelineListView.post の重複 POST 防止 (FEAT-370 migration 0100 経由)。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='dup_tester', password='password')
        self.player = PlayerProfile.objects.create(user=self.user)
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    def _post_event(self, **overrides):
        """テスト用 POST ヘルパー。overrides で個別フィールドを上書き可能。"""
        payload = {
            'title':      '読書',
            'date':       '2026-06-15',
            'start_time': '09:00:00',
            'end_time':   '09:30:00',
            'category':   '学習',
            'icon_key':   'menu_book',
        }
        payload.update(overrides)
        # start_time=None の場合キーを削除 (JSON で null として送信しない)
        if 'start_time' in payload and payload['start_time'] is None:
            del payload['start_time']
        if 'end_time' in payload and payload['end_time'] is None:
            del payload['end_time']
        return self.client.post('/api/timeline/', data=payload, format='json')

    # ─────────────────────────────────────────────────────────────────────
    # シナリオ 1: 同 (player, date, title, start_time) の 2 度目 POST は 200 + 既存返却
    # ─────────────────────────────────────────────────────────────────────
    def test_duplicate_post_returns_existing_200(self):
        """2 度目の重複 POST は 200 + 既存 event を返却し、DB には 1 件のみ存在する。"""
        first = self._post_event()
        self.assertEqual(first.status_code, http_status.HTTP_201_CREATED)
        first_id = first.data['id']

        second = self._post_event()  # 全く同じ payload
        self.assertEqual(
            second.status_code, http_status.HTTP_200_OK,
            msg='2 度目の重複 POST は 200 + 既存 event を返すべき',
        )
        self.assertEqual(
            second.data['id'], first_id,
            msg='返却 event は 1 度目で作成した既存 event であるべき',
        )
        # DB には 1 件のみ
        self.assertEqual(
            TimelineEvent.objects.filter(
                player=self.player, date=date_type(2026, 6, 15), title='読書',
            ).count(),
            1,
        )

    # ─────────────────────────────────────────────────────────────────────
    # シナリオ 2: 同タイトル + 同日 + 異なる start_time は両方 201 で許容
    # ─────────────────────────────────────────────────────────────────────
    def test_same_title_different_start_time_allowed(self):
        """異なる start_time は別 event として 201 で保存される。"""
        morning = self._post_event(start_time='09:00:00', end_time='09:30:00')
        evening = self._post_event(start_time='21:00:00', end_time='21:30:00')

        self.assertEqual(morning.status_code, http_status.HTTP_201_CREATED)
        self.assertEqual(
            evening.status_code, http_status.HTTP_201_CREATED,
            msg='同タイトル + 同日でも異なる start_time なら別 event として 201 で通るべき',
        )
        self.assertNotEqual(morning.data['id'], evening.data['id'])
        self.assertEqual(
            TimelineEvent.objects.filter(
                player=self.player, date=date_type(2026, 6, 15), title='読書',
            ).count(),
            2,
        )

    # ─────────────────────────────────────────────────────────────────────
    # シナリオ 3: 同タイトル + 同日 + 両方 start_time=NULL は 200 で既存返却
    # ─────────────────────────────────────────────────────────────────────
    def test_same_title_both_null_start_time_blocked(self):
        """start_time=NULL 同士の重複も 200 + 既存返却 (no-starttime partial constraint 経路)。"""
        # start_time を省略 (NULL) で作成
        first = self._post_event(start_time=None, end_time=None)
        self.assertEqual(first.status_code, http_status.HTTP_201_CREATED)
        first_id = first.data['id']

        second = self._post_event(start_time=None, end_time=None)
        self.assertEqual(
            second.status_code, http_status.HTTP_200_OK,
            msg='start_time=NULL 同士の重複は 200 + 既存返却で blocked にすべき',
        )
        self.assertEqual(second.data['id'], first_id)
        # DB には 1 件のみ
        self.assertEqual(
            TimelineEvent.objects.filter(
                player=self.player, date=date_type(2026, 6, 15), title='読書',
                start_time__isnull=True,
            ).count(),
            1,
        )


# ══════════════════════════════════════════════════════════════════════════════
# シナリオ 4-5: cleanup_duplicate_timeline_events management command 契約
# ══════════════════════════════════════════════════════════════════════════════

def _drop_unique_constraints():
    """テスト用: FEAT-370 の 2 partial unique constraint を一時的に削除する。

    Django TestCase はテスト全体を 1 トランザクション内に包み、終了時に ROLLBACK するため
    DDL (DROP INDEX) も自動で元に戻る (SQLite / PostgreSQL 両対応)。
    したがって constraint の手動 restore は不要。

    【2026-05-30 hotfix】PostgreSQL の partial unique constraint
    (UniqueConstraint(condition=Q(...))) は内部的に partial unique index として
    実装され、`pg_constraint` ではなく `pg_index` のみに登録される。
    そのため `DROP CONSTRAINT IF EXISTS` は no-op (silent failure) で
    制約が削除されず、テスト setUp の重複 INSERT で IntegrityError が発生していた。
    SQLite と同じく `DROP INDEX IF EXISTS` を使うように統一して解消する。
    元の bug は FEAT-370 (migration 0100) 起源、BUG-76 (migration 0113) でも継続、
    Neon 移行 (FEAT-394) の test 検証で発覚。
    """
    vendor = connection.vendor
    with connection.cursor() as cursor:
        # SQLite / PostgreSQL 両方で DROP INDEX を使用 (partial unique index は
        # 両方で index 経路で管理されるため)。
        cursor.execute(
            'DROP INDEX IF EXISTS unique_timeline_event_with_starttime',
        )
        cursor.execute(
            'DROP INDEX IF EXISTS unique_timeline_event_no_starttime',
        )


class CleanupDuplicateTimelineEventsCommandTest(TestCase):
    """cleanup_duplicate_timeline_events management command の契約。

    setUp で FEAT-370 の partial unique index を一時削除し、重複行を直接 INSERT する。
    Django TestCase が各テストをトランザクションでラップするため、DDL は ROLLBACK で
    自動復元され、テスト間の constraint 状態汚染が発生しない。
    """

    def setUp(self):
        self.user   = User.objects.create_user(
            username='cleanup_tester', password='password',
        )
        self.player = PlayerProfile.objects.create(user=self.user)

        # ── Unique index を一時削除 (TestCase rollback で自動復元) ──────────
        _drop_unique_constraints()

        # ── 重複行 3 件を作成 (同一 player / date / title / start_time) ──────
        self.original_ids = []
        for _ in range(3):
            e = TimelineEvent.objects.create(
                player=self.player,
                title='重複テスト',
                date=date_type(2026, 6, 10),
                start_time=time_type(8, 0),
            )
            self.original_ids.append(e.pk)

        # ── 重複なし行 1 件 (cleanup 対象外の正当 event) ─────────────────
        self.unique_event = TimelineEvent.objects.create(
            player=self.player,
            title='ユニーク',
            date=date_type(2026, 6, 10),
            start_time=time_type(12, 0),
        )

    # ─────────────────────────────────────────────────────────────────────
    # シナリオ 4: --dry-run では削除されない
    # ─────────────────────────────────────────────────────────────────────
    def test_cleanup_command_dry_run_no_delete(self):
        """--dry-run では重複グループを報告するだけで削除されない。"""
        before = TimelineEvent.objects.filter(player=self.player).count()
        self.assertEqual(before, 4, msg='setUp で 3 dup + 1 unique = 4 件のはず')

        out = StringIO()
        call_command('cleanup_duplicate_timeline_events', '--dry-run', stdout=out)
        output = out.getvalue()

        self.assertIn('重複グループ数: 1', output)
        self.assertIn('削除対象件数:   2', output)
        self.assertIn('--dry-run なので削除はスキップしました', output)

        after = TimelineEvent.objects.filter(player=self.player).count()
        self.assertEqual(after, 4, msg='--dry-run では件数が変わらないはず')

    # ─────────────────────────────────────────────────────────────────────
    # シナリオ 5: --confirm で最古 (pk 最小) を残し他を削除
    # ─────────────────────────────────────────────────────────────────────
    def test_cleanup_command_confirm_deletes_oldest_kept(self):
        """--confirm で最古 (pk 最小) を残し、残りの重複行を削除する。"""
        oldest_pk = min(self.original_ids)

        out = StringIO()
        call_command('cleanup_duplicate_timeline_events', '--confirm', stdout=out)
        output = out.getvalue()

        self.assertIn('削除完了: TimelineEvent 2 件', output)

        # 重複グループから 1 件 (最古) のみ残る
        remaining_dup = list(
            TimelineEvent.objects.filter(player=self.player, title='重複テスト')
        )
        self.assertEqual(len(remaining_dup), 1)
        self.assertEqual(
            remaining_dup[0].pk, oldest_pk,
            msg='最古 (pk 最小) の event が残るべき',
        )

        # 重複なし行は影響なし
        self.assertTrue(
            TimelineEvent.objects.filter(pk=self.unique_event.pk).exists(),
            msg='重複なし行 (ユニーク) は cleanup 対象外のため残るべき',
        )
