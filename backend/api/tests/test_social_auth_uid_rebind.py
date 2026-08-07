"""【BUG-70】SocialAuthView Case 2 の email 衝突時 SocialAccount rebind 契約。

シナリオ:
  - 同 email + 同 provider の既存 SA があり、新 uid でサインイン:
    → 既存 SA.provider_uid を新 uid に更新 (rebind) + 既存 user の token 発行 + 200
    → PlayerProfile / 習慣 / タイムライン等の関連データを保護
  - 同 email + 同 provider の既存 SA なし (User だけ存在):
    → BUG-67 の救済経路は通らず 409 (既存挙動維持)
  - 同 email + 別 provider の既存 SA:
    → 別 provider 経由の乗っ取り防止のため rebind せず 409

セキュリティ補強: email_verified=True を必須にして Firebase 検証に委譲。
"""
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework import status as http_status
from rest_framework.test import APITestCase

from api.models import PlayerProfile, SocialAccount
from api.services.exp_service import create_default_stats

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


def _fake_verify_id_token_factory(uid, email='', email_verified=False, name=''):
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
class SocialAuthUidRebindTestCase(APITestCase):
    """BUG-70 の rebind ロジック契約テスト。"""

    def setUp(self):
        cache.clear()
        self.verify_url = reverse('auth-social-verify')

    # ── BUG-70 主シナリオ: rebind 成功 + データ保持 ────────────────────
    def test_email_collision_with_existing_sa_rebinds_uid(self):
        """同 email + 同 provider + 新 uid のサインインで SA.provider_uid が更新され、
        PlayerProfile も保持される。"""
        existing_user = User.objects.create_user(
            username='rebind@example.com',
            email='rebind@example.com',
        )
        existing_player = PlayerProfile.objects.create(
            user=existing_user, name='既存勇者', gender='f', level=10, current_exp=500,
        )
        create_default_stats(existing_player)
        SocialAccount.objects.create(
            user=existing_user,
            provider='google',
            provider_uid='OLD_UID_001',
            email='rebind@example.com',
        )

        with patch(
            'firebase_admin.auth.verify_id_token',
            side_effect=_fake_verify_id_token_factory(
                uid='NEW_UID_002',
                email='rebind@example.com',
                email_verified=True,
            ),
        ):
            res = self.client.post(self.verify_url, {
                'id_token': 'dummy',
                'provider': 'google',
            }, format='json')

        self.assertEqual(res.status_code, http_status.HTTP_200_OK)
        self.assertEqual(res.data.get('status'), 'ok')
        self.assertIn('token', res.data)

        # SA の provider_uid が新値に rebind されていること
        sa = SocialAccount.objects.get(user=existing_user, provider='google')
        self.assertEqual(sa.provider_uid, 'NEW_UID_002')

        # PlayerProfile が保持されていること (Level 10 + current_exp 500 のまま)
        existing_player.refresh_from_db()
        self.assertEqual(existing_player.level, 10)
        self.assertEqual(existing_player.current_exp, 500)

        # 既存 User が同じ ID で残っていること (新規 User が作られていない)
        self.assertEqual(User.objects.filter(email='rebind@example.com').count(), 1)

    # ── ガード 1: SA なし → rebind しない (既存挙動) ────────────────
    def test_email_collision_without_sa_returns_409(self):
        """同 email の User があっても SocialAccount がなければ rebind せず 409。"""
        User.objects.create_user(
            username='nosa@example.com',
            email='nosa@example.com',
        )

        with patch(
            'firebase_admin.auth.verify_id_token',
            side_effect=_fake_verify_id_token_factory(
                uid='NEW_UID_003',
                email='nosa@example.com',
                email_verified=True,
            ),
        ):
            res = self.client.post(self.verify_url, {
                'id_token': 'dummy',
                'provider': 'google',
            }, format='json')

        self.assertEqual(res.status_code, http_status.HTTP_409_CONFLICT)
        self.assertFalse(
            SocialAccount.objects.filter(provider_uid='NEW_UID_003').exists(),
        )

    # ── ガード 2: 別 provider の SA → rebind しない (乗っ取り防止) ──
    def test_email_collision_different_provider_returns_409(self):
        """同 email + 別 provider の SA がある場合、Google サインインで Apple SA を
        rebind しないこと（別 provider 経由の乗っ取り防止）。"""
        existing_user = User.objects.create_user(
            username='diffprov@example.com',
            email='diffprov@example.com',
        )
        existing_player = PlayerProfile.objects.create(
            user=existing_user, name='Apple ユーザー', gender='f',
        )
        create_default_stats(existing_player)
        SocialAccount.objects.create(
            user=existing_user,
            provider='apple',
            provider_uid='APPLE_UID_001',
            email='diffprov@example.com',
        )

        with patch(
            'firebase_admin.auth.verify_id_token',
            side_effect=_fake_verify_id_token_factory(
                uid='GOOGLE_UID_NEW',
                email='diffprov@example.com',
                email_verified=True,
            ),
        ):
            res = self.client.post(self.verify_url, {
                'id_token': 'dummy',
                'provider': 'google',
            }, format='json')

        self.assertEqual(res.status_code, http_status.HTTP_409_CONFLICT)
        # 既存 Apple SA が変更されていないこと
        apple_sa = SocialAccount.objects.get(user=existing_user, provider='apple')
        self.assertEqual(apple_sa.provider_uid, 'APPLE_UID_001')
        # Google SA が作られていないこと
        self.assertFalse(
            SocialAccount.objects.filter(
                user=existing_user, provider='google',
            ).exists(),
        )

    # ── ガード 3: email_verified=False → rebind しない (なりすまし防止) ──
    def test_email_collision_with_unverified_email_returns_409(self):
        """email_verified=False では rebind しない (Firebase 検証に委譲)。"""
        existing_user = User.objects.create_user(
            username='unverif@example.com',
            email='unverif@example.com',
        )
        existing_player = PlayerProfile.objects.create(
            user=existing_user, name='検証済', gender='f',
        )
        create_default_stats(existing_player)
        SocialAccount.objects.create(
            user=existing_user,
            provider='google',
            provider_uid='VERIF_UID_001',
            email='unverif@example.com',
        )

        # email_verified=False で新 uid サインイン → effective_email がダミーになる
        # ため email 衝突自体が起きず、新規 User が作られて 201 になることを確認。
        # （rebind 経路には入らない＝既存 User の SA が変わらない）
        with patch(
            'firebase_admin.auth.verify_id_token',
            side_effect=_fake_verify_id_token_factory(
                uid='UNVERIF_UID_NEW',
                email='unverif@example.com',
                email_verified=False,
            ),
        ):
            res = self.client.post(self.verify_url, {
                'id_token': 'dummy',
                'provider': 'google',
            }, format='json')

        # 既存ユーザーの SA は変更されていないこと
        sa = SocialAccount.objects.get(user=existing_user, provider='google')
        self.assertEqual(sa.provider_uid, 'VERIF_UID_001')

    # ── リグレッション: 通常ログイン (uid 一致) は影響なし ──────────
    def test_normal_login_with_matching_uid_unaffected(self):
        """uid 一致の通常ログインで rebind 経路に入らず Case 1 (existing_sa) で
        即返却されること。"""
        existing_user = User.objects.create_user(
            username='normal@example.com',
            email='normal@example.com',
        )
        existing_player = PlayerProfile.objects.create(
            user=existing_user, name='通常ユーザー', gender='f',
        )
        create_default_stats(existing_player)
        SocialAccount.objects.create(
            user=existing_user,
            provider='google',
            provider_uid='NORMAL_UID_001',
            email='normal@example.com',
        )

        with patch(
            'firebase_admin.auth.verify_id_token',
            side_effect=_fake_verify_id_token_factory(
                uid='NORMAL_UID_001',  # uid 一致 → Case 1 で即返却
                email='normal@example.com',
                email_verified=True,
            ),
        ):
            res = self.client.post(self.verify_url, {
                'id_token': 'dummy',
                'provider': 'google',
            }, format='json')

        self.assertEqual(res.status_code, http_status.HTTP_200_OK)
        self.assertEqual(res.data.get('status'), 'ok')
        # SA 内容に変化なし
        sa = SocialAccount.objects.get(user=existing_user, provider='google')
        self.assertEqual(sa.provider_uid, 'NORMAL_UID_001')
