"""【2026-07-02】Admin MFA (OTP メール認証) 契約テスト。

codebase_review 20260702 §2 懸念点 3 対応:
「新規のセキュリティ機能 (管理画面 MFA) に自動テストが無い」

セキュリティ境界を守るコードほど回帰保護が重要という原則から、
最低限の 4 シナリオを契約テスト化する。

【シナリオ 4 件】
1. OTP 検証成功で MFA 通過 (session に verified タイムスタンプ、challenge used=True、
   /admin/ へ redirect)
2. 試行回数超過 (5 回失敗) でロック (used=True 強制、正しいコードでも通らない)
3. 期限切れ後の再検証拒否 (created_at + 10 分超過 → filter 外、正しいコードでも拒否)
4. 他ユーザーの challenge を参照できない (user1 が user2 の code を入力しても
   filter(user=user1) で除外され通らない、user2 の challenge に影響なし)

【範囲外 (別 PR で対応候補)】
- メール送信ロジック (Resend HTTP API 依存、mock 化コスト高)
- 再送信 throttle (60 秒) の view 経由テスト (別視点、契約テストではなく統合テスト向き)
"""
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.test import Client, TestCase, override_settings
from django.urls import reverse
from django.utils import timezone

from api.middleware.admin_mfa import MFA_SESSION_KEY
from api.models import AdminMFAChallenge

User = get_user_model()


@override_settings(
    STORAGES={
        'default': {'BACKEND': 'django.core.files.storage.FileSystemStorage'},
        'staticfiles': {'BACKEND': 'django.contrib.staticfiles.storage.StaticFilesStorage'},
    }
)
class AdminMFAVerifyContractTests(TestCase):
    """Admin MFA の verify (POST) 経路の契約テスト 4 シナリオ。"""

    def setUp(self):
        self.client = Client()
        self.user = User.objects.create_user(
            username='admin1@example.com',
            email='admin1@example.com',
            password='pw',
            is_staff=True,
        )
        # session 認証 (Django admin login と同経路)
        self.client.login(
            username='admin1@example.com', password='pw',
        )

    def _create_active_challenge(self, code='123456', user=None):
        """view を経由せず AdminMFAChallenge を直接 create。"""
        return AdminMFAChallenge.objects.create(
            user=user or self.user, code=code,
        )

    # ── シナリオ 1: OTP 検証成功で MFA 通過 ────────────────────────
    def test_verify_success_marks_session_and_used(self):
        challenge = self._create_active_challenge(code='123456')

        response = self.client.post(
            reverse('admin_mfa_verify'), {'code': '123456'},
        )

        # 成功 → /admin/ へ redirect (302)
        self.assertEqual(response.status_code, 302)
        # session に verified タイムスタンプが立つ (middleware.is_mfa_fresh が
        # 12 時間の TTL 内で True を返す)
        self.assertIn(MFA_SESSION_KEY, self.client.session)
        # challenge は used=True で使い回し不可
        challenge.refresh_from_db()
        self.assertTrue(challenge.used)

    # ── シナリオ 2: 試行回数超過 (5 回失敗) でロック ────────────────
    def test_verify_locked_after_5_attempts(self):
        challenge = self._create_active_challenge(code='123456')

        # 5 回連続で不正コードを送る (attempt_count が 0 → 5 に増える)
        for _ in range(5):
            response = self.client.post(
                reverse('admin_mfa_verify'), {'code': '000000'},
            )
            self.assertEqual(response.status_code, 200)  # form 再表示

        challenge.refresh_from_db()
        self.assertEqual(challenge.attempt_count, 5)
        self.assertFalse(challenge.used)  # まだ used=False (次 POST でロック判定)

        # 6 回目: 正しいコードでも「試行回数の上限に達しました」でロックされる
        response = self.client.post(
            reverse('admin_mfa_verify'), {'code': '123456'},
        )
        self.assertEqual(response.status_code, 200)  # form 再表示 (redirect ではない)

        challenge.refresh_from_db()
        self.assertTrue(challenge.used)  # ロック確定
        # session はまだ verified されていない
        self.assertNotIn(MFA_SESSION_KEY, self.client.session)

    # ── シナリオ 3: 期限切れ (10 分超過) の challenge は再検証拒否 ─
    def test_verify_rejects_expired_challenge(self):
        challenge = self._create_active_challenge(code='123456')
        # 11 分前に発行された状態を再現 (auto_now_add で create 時に now が入るため
        # update で強制上書き)
        AdminMFAChallenge.objects.filter(pk=challenge.pk).update(
            created_at=timezone.now() - timedelta(minutes=11),
        )

        response = self.client.post(
            reverse('admin_mfa_verify'), {'code': '123456'},  # 正しいコードでも
        )

        # 期限切れ → form 再表示 (redirect ではない、view line 193-205 の filter で除外)
        self.assertEqual(response.status_code, 200)
        # session は verified されない
        self.assertNotIn(MFA_SESSION_KEY, self.client.session)
        # 期限切れ challenge は view が読み込まない (attempt_count 変わらず、used=False)
        challenge.refresh_from_db()
        self.assertEqual(challenge.attempt_count, 0)
        self.assertFalse(challenge.used)

    # ── シナリオ 4: 他ユーザーの challenge を参照できない ────────
    def test_verify_cannot_use_other_users_code(self):
        # 別 staff user とその challenge (code='999999')
        user2 = User.objects.create_user(
            username='admin2@example.com',
            email='admin2@example.com',
            password='pw',
            is_staff=True,
        )
        other_challenge = self._create_active_challenge(code='999999', user=user2)

        # 現ユーザー (admin1) は自身の challenge を持たない状態で user2 のコードを入力
        response = self.client.post(
            reverse('admin_mfa_verify'), {'code': '999999'},
        )

        # user1 に active challenge が無いので「期限切れ」扱いで form 再表示
        # (view の filter は user=request.user で厳密に絞られる、line 193-196)
        self.assertEqual(response.status_code, 200)
        # session は verified されない
        self.assertNotIn(MFA_SESSION_KEY, self.client.session)

        # user2 の challenge は完全に影響を受けない (used=False, attempt_count=0)
        other_challenge.refresh_from_db()
        self.assertFalse(other_challenge.used)
        self.assertEqual(other_challenge.attempt_count, 0)
