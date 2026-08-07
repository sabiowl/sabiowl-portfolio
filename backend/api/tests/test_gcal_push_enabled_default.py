"""FEAT-263: gcal_push_enabled デフォルト OFF + 同意 flip の契約テスト。

migration 0077 で default を True → False に変更したことの契約 + PATCH /api/player/
での flip 経路（FEAT-254 シート同意時に Flutter から呼ばれる）の契約縛り。

関連:
- FEAT-257（migration 0076 で gcal_push_enabled を default=True で追加）
- FEAT-263（migration 0077 で default を False に変更 + 既存全プレイヤーをバックフィル）
- FEAT-259（既存 e2e の `test_gcal_push_disabled_creates_with_pending_false` は
  「OFF なら pending=False」を縛る。本テストは「default が OFF」を別途縛る）
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import PlayerProfile, SocialAccount, TimelineEvent

User = get_user_model()


_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework.authtoken.authentication.TokenAuthentication',
        'api.authentication.GuestTokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
}


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class GcalPushEnabledDefaultOffTest(APITestCase):
    """FEAT-263: gcal_push_enabled は default=False で、PATCH で True に flip できる。"""

    def setUp(self):
        cache.clear()
        self.user   = User.objects.create_user('player1', email='p1@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='Player1')
        SocialAccount.objects.create(
            user=self.user, provider='google', provider_uid='g_uid_001',
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    # ─────────────────────────────────────────────────────────────
    # 1: 新規 PlayerProfile は gcal_push_enabled=False（default 確認）
    # ─────────────────────────────────────────────────────────────
    def test_new_player_defaults_to_false(self):
        """ORM 直接生成でも `default=False` が適用される（FEAT-263 の中核契約）。"""
        new_user = User.objects.create_user('newplayer', email='new@example.com')
        new_player = PlayerProfile.objects.create(user=new_user, name='New')
        self.assertFalse(
            new_player.gcal_push_enabled,
            'FEAT-263: 新規 PlayerProfile は明示同意なしの安全側 False が default',
        )

    # ─────────────────────────────────────────────────────────────
    # 2: PATCH /api/player/ で gcal_push_enabled=True に flip できる
    #    （FEAT-254 シート同意時に Flutter から呼ばれる経路）
    # ─────────────────────────────────────────────────────────────
    def test_patch_player_flips_to_true(self):
        """PATCH /api/player/ {gcal_push_enabled: true} で flip が反映される。"""
        self.assertFalse(self.player.gcal_push_enabled, '前提: 初期は False')

        res = self.client.patch(
            reverse('player'),
            data={'gcal_push_enabled': True},
            format='json',
        )
        self.assertEqual(res.status_code, 200, res.content)
        self.assertTrue(res.data['gcal_push_enabled'])

        self.player.refresh_from_db()
        self.assertTrue(self.player.gcal_push_enabled)

    def test_patch_player_flips_back_to_false(self):
        """マイページ Switch OFF 経路: PATCH で False に戻せる。"""
        self.player.gcal_push_enabled = True
        self.player.save(update_fields=['gcal_push_enabled'])

        res = self.client.patch(
            reverse('player'),
            data={'gcal_push_enabled': False},
            format='json',
        )
        self.assertEqual(res.status_code, 200, res.content)
        self.player.refresh_from_db()
        self.assertFalse(self.player.gcal_push_enabled)

    # ─────────────────────────────────────────────────────────────
    # 3: 新デフォルト OFF 状態で予定作成 → pending_google_push=False
    #    （FEAT-257 の `_initial_pending_google_push` が False を返すこと）
    # ─────────────────────────────────────────────────────────────
    def test_create_event_with_default_off_skips_pending(self):
        """default=False のままで予定を作ると pending_google_push=False になる
        （Google に書き出されない安全側挙動）。"""
        # setUp で player を新規作成済 = gcal_push_enabled は default の False のまま
        res = self.client.post(reverse('timeline-list'), data={
            'title':      '同意前予定',
            'date':       '2026-06-10',
            'start_time': '09:00:00',
            'end_time':   '10:00:00',
        }, format='json')
        self.assertEqual(res.status_code, 201, res.content)

        event = TimelineEvent.objects.get(pk=res.data['id'])
        self.assertFalse(
            event.pending_google_push,
            'FEAT-263: default OFF 状態の予定は push 対象外（明示同意なしには書き出さない）',
        )

    # ─────────────────────────────────────────────────────────────
    # 4: 同意 flip 後に作った予定は pending_google_push=True に戻る
    #    （FEAT-254 シート同意 → 同期実行 → 以後の予定は通常 push 経路）
    # ─────────────────────────────────────────────────────────────
    def test_create_event_after_consent_flip_is_pending(self):
        """【FEAT-373 hotfix】PATCH で gcal_push_enabled=True に flip しても
        FEAT-373 で push 機能廃止のため pending=False が保存される（旧契約を更新）。

        旧挙動 (FEAT-263): gcal_push_enabled=True + Google 連携あり → pending=True
        新挙動 (FEAT-373): _initial_pending_google_push が常時 False を返す
        """
        self.client.patch(
            reverse('player'),
            data={'gcal_push_enabled': True},
            format='json',
        )

        res = self.client.post(reverse('timeline-list'), data={
            'title': '同意後予定',
            'date':  '2026-06-11',
        }, format='json')
        self.assertEqual(res.status_code, 201, res.content)

        event = TimelineEvent.objects.get(pk=res.data['id'])
        # 【FEAT-373】v1.0 で push 廃止のため gcal_push_enabled に関わらず False
        self.assertFalse(
            event.pending_google_push,
            'FEAT-373: push 機能廃止により gcal_push_enabled=True でも pending=False',
        )
