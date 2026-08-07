"""【FEAT-253】TimelineListView のクエリフィルタ契約テスト。

- `?has_google_event_id=true` は google_event_id を持つイベントのみ返す。
- `?unpushed_to_google=true` (FEAT-244) との独立性確認（誤マッチしない）。
- 既存の `?date=YYYY-MM-DD` 経路がフィルタ追加で退行していないことを確認。
"""
from datetime import date as date_type

from django.contrib.auth import get_user_model
from django.test import override_settings
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import PlayerProfile, TimelineEvent

User = get_user_model()


# throttle / 認証クラスの最小構成（test_habit_count_view.py を踏襲）
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
class TimelineListFilterTestCase(APITestCase):
    """`?has_google_event_id=true` と `?unpushed_to_google=true` の契約。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='tester', password='password')
        self.player = PlayerProfile.objects.create(user=self.user)
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # ── 4 種類のイベントを作成（has_google_event_id / pending_google_push の交差） ──
        # 【FEAT-256】migration 0075 の RunPython バックフィル相当を ORM 直接 create では
        # 通らないため、本来 Backend が初期化する `pending_google_push` を明示指定する。
        # production 経路では `TimelineListView.post` → `_initial_pending_google_push` が
        # 設定する流れで、状態は以下のとおり:
        #   - Google 起源 (source=google)          → pending=False（push 対象外）
        #   - Sabiowl push 済 (google_event_id 持ち) → pending=False（push 完了済）
        #   - ローカル単独                          → pending=True （未 push）
        # 1. Google → Sabiowl 取り込み済（source=google, google_event_id 持ち）
        self.imported_from_google = TimelineEvent.objects.create(
            player=self.player,
            title='import',
            date=date_type(2026, 5, 21),
            source=TimelineEvent.SOURCE_GOOGLE,
            external_id='gcal_evt_1',
            google_event_id='gcal_evt_1',
            pending_google_push=False,
        )
        # 2. Sabiowl → Google push 済（source=local, google_event_id 持ち）
        self.pushed_to_google = TimelineEvent.objects.create(
            player=self.player,
            title='pushed',
            date=date_type(2026, 5, 21),
            source=TimelineEvent.SOURCE_LOCAL,
            google_event_id='gcal_evt_2',
            pending_google_push=False,
        )
        # 3. ローカル予定（google_event_id 未設定）
        self.local_only = TimelineEvent.objects.create(
            player=self.player,
            title='local',
            date=date_type(2026, 5, 21),
            source=TimelineEvent.SOURCE_LOCAL,
            pending_google_push=True,
        )
        # 4. 別ユーザーの予定（漏洩確認用）
        other_user   = User.objects.create_user(username='other', password='password')
        other_player = PlayerProfile.objects.create(user=other_user)
        TimelineEvent.objects.create(
            player=other_player,
            title='other-user',
            date=date_type(2026, 5, 21),
            source=TimelineEvent.SOURCE_LOCAL,
            google_event_id='other_gcal',
            pending_google_push=False,
        )

    # ─────────────────────────────────────────────────────────────────────
    # `?has_google_event_id=true`
    # ─────────────────────────────────────────────────────────────────────

    def test_has_google_event_id_true_returns_only_google_linked(self):
        """google_event_id 持ちのみ返り、ローカル単独や他ユーザーは混ざらない。"""
        res = self.client.get('/api/timeline/?has_google_event_id=true')
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)

        returned_ids = sorted(e['id'] for e in res.data)
        expected_ids = sorted([
            self.imported_from_google.pk,  # Google 取り込み
            self.pushed_to_google.pk,      # Sabiowl push 済
        ])
        self.assertEqual(returned_ids, expected_ids)

        # 全レスポンスに google_event_id が含まれており空でないこと
        for e in res.data:
            self.assertIn('google_event_id', e)
            self.assertTrue(e['google_event_id'])

    def test_has_google_event_id_false_falls_back_to_date_required(self):
        """`has_google_event_id=true` 以外の値では通常経路に落ち、?date が必須になる。"""
        res = self.client.get('/api/timeline/?has_google_event_id=false')
        # date 未指定なら 400
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)

    # ─────────────────────────────────────────────────────────────────────
    # `?unpushed_to_google=true` との独立性
    # ─────────────────────────────────────────────────────────────────────

    def test_unpushed_to_google_still_works(self):
        """FEAT-244 の `?unpushed_to_google=true` 経路（FEAT-256 で
        `?pending_google_push=true` の互換エイリアスとして残存）が引き続き動作すること。"""
        res = self.client.get('/api/timeline/?unpushed_to_google=true')
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)
        ids = sorted(e['id'] for e in res.data)
        # 【FEAT-256】local_only のみが該当（pending_google_push=True）。
        # imported_from_google / pushed_to_google は production の Backend 経路で
        # pending=False になるため対象外（setUp で明示指定済）。
        self.assertEqual(ids, [self.local_only.pk])

    def test_pending_google_push_returns_same_as_unpushed_alias(self):
        """【FEAT-256】新クエリ `?pending_google_push=true` も同一結果を返す
        （旧エイリアスとの互換性確認）。"""
        res = self.client.get('/api/timeline/?pending_google_push=true')
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)
        ids = sorted(e['id'] for e in res.data)
        self.assertEqual(ids, [self.local_only.pk])

    # ─────────────────────────────────────────────────────────────────────
    # 通常の ?date= 経路の退行なし
    # ─────────────────────────────────────────────────────────────────────

    def test_date_filter_still_returns_all_for_player(self):
        """`?date=...` 経路は自プレイヤーの当日全イベントを返す（フィルタ追加で退行なし）。"""
        res = self.client.get('/api/timeline/?date=2026-05-21')
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)
        ids = sorted(e['id'] for e in res.data)
        expected = sorted([
            self.imported_from_google.pk,
            self.pushed_to_google.pk,
            self.local_only.pk,
        ])
        self.assertEqual(ids, expected)
