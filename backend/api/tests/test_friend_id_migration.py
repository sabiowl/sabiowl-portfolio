"""【FEAT-423 (2026-06-10) → 2026-07-02 拡張】friend_id 桁数の契約テスト。

沿革:
- 2026-06-10 (FEAT-423, migration 0125): 9 文字 `XXXX-XXXX` → 8 桁数字
- 2026-07-02 (migration 0167): 8 桁 → 12 桁数字 (Mobile 側で 4-4-4 表示)

契約シナリオ:
- A (history): 旧 `1234-5678` 形式が `12345678` (8 桁数字) に変換される
- B: max_length=12 制約が効く (13 文字以上は ValidationError)、旧 8 桁も valid
- C: 新規 PlayerProfile.save() で friend_id が 12 桁数字で自動生成される
- D: 検索時に `-` 入り入力でも `-` なし入力でも同じユーザーにヒットする
     (8 桁 `1234-5678` / 12 桁 `1234-5678-9012` の両方で検証)
"""
from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import PlayerProfile

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


class FriendIdAutoGenerationTest(TestCase):
    """シナリオ C: 新規 PlayerProfile の friend_id は 12 桁数字。"""

    def test_new_player_friend_id_is_12digit_numeric(self):
        user = User.objects.create_user(username='fid_c', password='pw')
        player = PlayerProfile.objects.create(user=user, name='c')
        self.assertEqual(len(player.friend_id), 12)
        self.assertTrue(player.friend_id.isdigit())


class FriendIdMaxLengthTest(TestCase):
    """シナリオ B: max_length=12 制約、旧 8 桁も互換維持で valid。"""

    def test_12digit_friend_id_is_valid(self):
        user = User.objects.create_user(username='fid_b1', password='pw')
        player = PlayerProfile.objects.create(user=user, name='b1')
        player.friend_id = '123456789012'
        player.full_clean()  # raises if invalid

    def test_13digit_friend_id_raises_validation_error(self):
        user = User.objects.create_user(username='fid_b2', password='pw')
        player = PlayerProfile.objects.create(user=user, name='b2')
        player.friend_id = '1234567890123'
        with self.assertRaises(ValidationError):
            player.full_clean()

    def test_legacy_8digit_friend_id_still_valid(self):
        """旧 8 桁 friend_id は 12 桁化後も後方互換で保持・valid。"""
        user = User.objects.create_user(username='fid_b3', password='pw')
        player = PlayerProfile.objects.create(user=user, name='b3')
        player.friend_id = '12345678'
        player.full_clean()  # raises if invalid


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class FriendIdSearchBackwardCompatTest(APITestCase):
    """シナリオ D: 検索時に `-` ありなしどちらでもヒットする (8 桁 / 12 桁両方)。"""

    def setUp(self):
        self.searcher = User.objects.create_user(username='fid_d_searcher', password='pw')
        PlayerProfile.objects.create(user=self.searcher, name='searcher')
        self.searcher_token = Token.objects.create(user=self.searcher)

        # 12 桁ターゲット (新形式)
        self.target_12 = User.objects.create_user(username='fid_d_target12', password='pw')
        t12 = PlayerProfile.objects.create(user=self.target_12, name='target12')
        t12.friend_id = '123456789012'
        t12.save(update_fields=['friend_id'])

        # 8 桁ターゲット (旧形式、後方互換)
        self.target_8 = User.objects.create_user(username='fid_d_target8', password='pw')
        t8 = PlayerProfile.objects.create(user=self.target_8, name='target8')
        t8.friend_id = '87654321'
        t8.save(update_fields=['friend_id'])

    def _search(self, friend_id):
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.searcher_token.key}')
        return self.client.get(reverse('friend-search'), {'friend_id': friend_id})

    # ── 12 桁 (新形式) ──
    def test_search_12digit_without_hyphen_hits(self):
        response = self._search('123456789012')
        self.assertEqual(response.status_code, http_status.HTTP_200_OK)
        self.assertEqual(response.data['friend_id'], '123456789012')

    def test_search_12digit_with_hyphen_also_hits(self):
        """Mobile 側の表示 `1234-5678-9012` を直接貼り付けても hit する。"""
        response = self._search('1234-5678-9012')
        self.assertEqual(response.status_code, http_status.HTTP_200_OK)
        self.assertEqual(response.data['friend_id'], '123456789012')

    # ── 8 桁 (旧形式、後方互換) ──
    def test_search_legacy_8digit_without_hyphen_hits(self):
        response = self._search('87654321')
        self.assertEqual(response.status_code, http_status.HTTP_200_OK)
        self.assertEqual(response.data['friend_id'], '87654321')

    def test_search_legacy_8digit_with_hyphen_also_hits(self):
        response = self._search('8765-4321')
        self.assertEqual(response.status_code, http_status.HTTP_200_OK)
        self.assertEqual(response.data['friend_id'], '87654321')


class FriendIdMigrationFormatConversionTest(TestCase):
    """シナリオ A: migration 0125 の `_strip_hyphen` ロジック相当の検証。

    実際の migration はアプリ起動時に適用済みのため、ここでは
    `_strip_hyphen` と同等の Replace クエリが既存データに対して
    冪等に動作することを確認する (再適用しても安全 = 0125 の
    reversible 設計の裏付け)。
    """

    def test_strip_hyphen_converts_existing_format(self):
        from django.db.models import Value
        from django.db.models.functions import Replace

        user = User.objects.create_user(username='fid_a', password='pw')
        player = PlayerProfile.objects.create(user=user, name='a')
        # 旧形式を直接 DB に書き込む (Python バリデーションをバイパスするため
        # queryset.update を使用、`-` 入り 9 文字は max_length=12 内で問題なし)
        PlayerProfile.objects.filter(pk=player.pk).update(friend_id='1234-5678')

        PlayerProfile.objects.filter(pk=player.pk, friend_id__contains='-').update(
            friend_id=Replace('friend_id', Value('-'), Value('')),
        )

        player.refresh_from_db()
        self.assertEqual(player.friend_id, '12345678')
