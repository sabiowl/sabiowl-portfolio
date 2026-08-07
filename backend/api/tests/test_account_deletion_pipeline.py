"""【FEAT-245】アカウント削除パイプラインの 3 段階完全化テスト。

PlayerProfileView.delete が Firebase Auth ユーザー削除 + PostHog identity 削除を
**両方呼び出す** ことを契約として縛る。実際の外部 API 呼び出しは Mock。

修正前: `_delete_firebase_users` が存在しなかった（Firebase 残置バグ）
修正後: Firebase + PostHog 両方が呼ばれ、片方が失敗しても他方は呼ばれる
"""
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import PlayerProfile, SocialAccount

User = get_user_model()


# 【FEAT-245 test】既存テスト（test_social_auth_atomic 等）と同じく throttle を
# 完全 OFF + cache.clear() で安定化させる。テスト独立性を担保。
_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework.authentication.TokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
}


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class AccountDeletionPipelineTestCase(APITestCase):
    """アカウント削除時に Firebase Auth + PostHog が呼ばれる契約。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(
            username='deletetest@example.com',
            email='deletetest@example.com',
        )
        self.player = PlayerProfile.objects.create(
            user=self.user, name='テスター', level=5,
        )
        self.sa = SocialAccount.objects.create(
            user=self.user, provider='google',
            provider_uid='UID_FB_TEST_001', email='deletetest@example.com',
        )
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        # urls.py での name は `player`（player-profile ではない）
        self.url = reverse('player')

    def _delete_payload(self):
        return {
            'reason':      'bored',
            'reason_text': '',
            'app_version': '1.0.0',
        }

    # ── 中核: Firebase + PostHog 両方呼ばれる ────────────────────────────
    @patch('api.views.player._delete_firebase_users')
    @patch('api.views.player._delete_posthog_identity')
    def test_account_deletion_invokes_firebase_and_posthog(self, mock_posthog, mock_firebase):
        """アカウント削除時に Firebase + PostHog 両方が呼ばれること（契約）。

        FEAT-245 の中核検証。修正前は `_delete_firebase_users` が存在せず、
        Firebase Auth に uid + email + display_name が残置していた。
        """
        deleted_player_id = self.player.id  # delete 後は取れないので控える

        res = self.client.delete(self.url, self._delete_payload(), format='json')

        self.assertEqual(res.status_code, http_status.HTTP_204_NO_CONTENT)
        # User 削除確認（Django CASCADE 段階）
        self.assertFalse(User.objects.filter(pk=self.user.pk).exists())
        # Firebase 削除呼び出し: 該当 uid が渡される
        mock_firebase.assert_called_once_with(['UID_FB_TEST_001'])
        # PostHog 削除呼び出し: player_id が渡される
        mock_posthog.assert_called_once_with(deleted_player_id)

    # ── best-effort: Firebase 失敗でも削除完了 ───────────────────────────
    @patch('api.views.player._delete_firebase_users', side_effect=Exception('firebase down'))
    @patch('api.views.player._delete_posthog_identity')
    def test_firebase_failure_does_not_block_deletion(self, mock_posthog, _mock_firebase):
        """Firebase 削除失敗時も 204 を返し、PostHog 削除は続行されること。

        best-effort 設計の契約。Firebase API が down していても、ユーザー側の
        「削除完了」体験を壊さない（Django CASCADE は既に成功）。
        """
        res = self.client.delete(self.url, self._delete_payload(), format='json')
        self.assertEqual(res.status_code, http_status.HTTP_204_NO_CONTENT)
        # User 削除は完了
        self.assertFalse(User.objects.filter(pk=self.user.pk).exists())
        # PostHog 呼び出しは継続（Firebase が落ちても PostHog はスキップしない）
        mock_posthog.assert_called_once()

    # ── 空 list 経路: SocialAccount を持たないユーザー ───────────────────
    @patch('api.views.player._delete_firebase_users')
    @patch('api.views.player._delete_posthog_identity')
    def test_no_social_account_skips_firebase(self, _mock_posthog, mock_firebase):
        """SocialAccount を持たないユーザー（旧 magic-link 残骸等）は空 list で呼ぶ。

        `_delete_firebase_users([])` の早期 return パスが効くことを保証。
        FEAT-178 で magic-link は完全撤去済みだが、過去データの整合性を担保。
        """
        self.sa.delete()
        res = self.client.delete(self.url, self._delete_payload(), format='json')
        self.assertEqual(res.status_code, http_status.HTTP_204_NO_CONTENT)
        mock_firebase.assert_called_once_with([])
