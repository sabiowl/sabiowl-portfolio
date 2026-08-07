"""【BUG-67】SocialAuthView の @transaction.atomic + IntegrityError パターンが
broken transaction を起こさず正しく 409 を返すことの契約テスト。

CLAUDE.md「既知の落とし穴」: `@transaction.atomic` 配下で IntegrityError を catch
する場合は **入れ子の `with transaction.atomic():`** で savepoint を切ること。

修正前: `test_case_b_guest_with_existing_email_returns_409_not_500` と
        `test_case_2_nonguest_with_existing_email_returns_409_not_500` は
        500 が返って FAIL する（broken transaction → InFailedSqlTransaction）。
修正後: 全 4 件 PASS。
"""
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework import status as http_status
from rest_framework.test import APITestCase

from api.models import GuestSession, PlayerProfile, SocialAccount

User = get_user_model()


# 【BUG-67 test】throttle (`social_auth: 20/hour`) を緩めて 4 件連続テストを安定化。
# 既存テストパターン（test_habit_count_view.py の FEAT-241）と同じ手法。
_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'api.authentication.ExpiringTokenAuthentication',
        'api.authentication.GuestTokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_THROTTLE_CLASSES': [],   # throttle 完全 OFF
    'DEFAULT_THROTTLE_RATES': {},
}


def _fake_verify_id_token_factory(uid, email='', email_verified=False, name=''):
    """firebase_admin.auth.verify_id_token のモック関数を返すファクトリ。"""
    payload = {
        'uid':            uid,
        'email':          email,
        'email_verified': email_verified,
        'name':           name,
    }
    def _verify(_id_token):
        return payload
    return _verify


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class SocialAuthAtomicSavepointTestCase(APITestCase):
    """Case B / Case 2 の IntegrityError 経路で 500 ではなく 409 を返すこと。"""

    def setUp(self):
        cache.clear()  # throttle カウンタ二重保険でクリア
        self.verify_url = reverse('auth-social-verify')

    # ── Case B（ゲスト + 既存 email）─────────────────────────────────────
    def test_case_b_guest_with_existing_email_returns_409_not_500(self):
        """ゲスト連携時に email が DB に既存だった場合、500 ではなく 409 を返す。

        BUG-67 の主シナリオ。`User.objects.create_user(username=email)` が
        IntegrityError を投げても、savepoint で broken transaction を回避し、
        後続の `SocialAccount.objects.filter(...)` が正常実行される。
        """
        # 既存 User（過去削除残骸を模す）
        User.objects.create_user(username='collision@example.com', email='collision@example.com')

        # 新規ゲストセッション
        guest_player = PlayerProfile.objects.create(user=None, name='ゲスト')
        guest_session = GuestSession.objects.create(player_profile=guest_player)

        with patch(
            'firebase_admin.auth.verify_id_token',
            side_effect=_fake_verify_id_token_factory(
                uid='UID_NEW_001',
                email='collision@example.com',
                email_verified=True,
            ),
        ):
            res = self.client.post(self.verify_url, {
                'id_token':    'dummy',
                'provider':    'google',
                'guest_token': guest_session.token,
            }, format='json')

        # 500 ではなく 409 が返ること（BUG-67 の中核）
        self.assertNotEqual(
            res.status_code, 500,
            f'500 reproduced (BUG-67 regression): {getattr(res, "data", None)}',
        )
        self.assertEqual(res.status_code, http_status.HTTP_409_CONFLICT)

    # ── Case B（衝突なし正常系）─────────────────────────────────────────
    def test_case_b_guest_clean_email_succeeds(self):
        """email 衝突がない通常ケースで 200 + token を返す（リグレッション確認）。"""
        guest_player = PlayerProfile.objects.create(user=None, name='ゲスト')
        guest_session = GuestSession.objects.create(player_profile=guest_player)

        with patch(
            'firebase_admin.auth.verify_id_token',
            side_effect=_fake_verify_id_token_factory(
                uid='UID_NEW_002',
                email='fresh@example.com',
                email_verified=True,
            ),
        ):
            res = self.client.post(self.verify_url, {
                'id_token':    'dummy',
                'provider':    'google',
                'guest_token': guest_session.token,
            }, format='json')

        self.assertEqual(res.status_code, http_status.HTTP_200_OK)
        self.assertEqual(res.data.get('status'), 'ok')
        self.assertTrue(SocialAccount.objects.filter(provider_uid='UID_NEW_002').exists())

    # ── Case 2（非ゲスト + 既存 email）──────────────────────────────────
    def test_case_2_nonguest_with_existing_email_returns_409_not_500(self):
        """ゲストトークンなしの新規サインインで email 衝突した場合、500 ではなく 409。"""
        User.objects.create_user(username='collision2@example.com', email='collision2@example.com')

        with patch(
            'firebase_admin.auth.verify_id_token',
            side_effect=_fake_verify_id_token_factory(
                uid='UID_NEW_003',
                email='collision2@example.com',
                email_verified=True,
            ),
        ):
            res = self.client.post(self.verify_url, {
                'id_token': 'dummy',
                'provider': 'google',
            }, format='json')

        self.assertNotEqual(
            res.status_code, 500,
            f'500 reproduced (BUG-67 regression): {getattr(res, "data", None)}',
        )
        self.assertEqual(res.status_code, http_status.HTTP_409_CONFLICT)

    # ── Case 2（衝突なし正常系）─────────────────────────────────────────
    def test_case_2_nonguest_clean_email_creates_new_user(self):
        """email 衝突がない通常ケースで 201 + token を返す（リグレッション確認）。"""
        with patch(
            'firebase_admin.auth.verify_id_token',
            side_effect=_fake_verify_id_token_factory(
                uid='UID_NEW_004',
                email='fresh2@example.com',
                email_verified=True,
            ),
        ):
            res = self.client.post(self.verify_url, {
                'id_token': 'dummy',
                'provider': 'google',
            }, format='json')

        self.assertEqual(res.status_code, http_status.HTTP_201_CREATED)
        self.assertEqual(res.data.get('status'), 'new_user')
