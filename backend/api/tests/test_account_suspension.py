"""【FEAT-541 (2026-09-06)】アカウント停止（ban）の契約テスト。

## このファイルが守るもの

| # | 縛るもの |
|---|---|
| §1 | 🔴 停止ユーザーの API が **403 + `auth_account_suspended`**（**401 ではない**） |
| §2 | 🔴 停止ユーザーはソーシャルサインインでも**トークンが発行されない** |
| §3 | 🔴 **走査**: `Token.objects.get_or_create` がヘルパー内の 1 件以外に無い |
| §4 | admin で `is_active` を切ると `AccountSuspensionLog` が 1 行増える |
| §5 | `AccountSuspensionLog` の admin が add / change / delete すべて不可 |
| §6 | 有効ユーザーは従来どおり通る（回帰） |

## 🔴 §1 が「403 であること」を明示 assert する理由

現状は `AuthenticationFailed` = **401** である。401 のままだと、Mobile の
既存 interceptor が**問答無用でトークンを消してログイン画面へ飛ばす**ので、
停止画面が表示される隙が無い —— ログインし直す → また 401 の無限ループになる。

⚠️ ここで「拒否された」だけを見るテストを書くと、**401 に戻されても緑のまま
通る**。そのとき Mobile は黙って旧挙動（無限ループ）に戻り、
**画面は出ないのにテストは緑**という最悪の形になる。
だから `assertEqual(403)` を書き、**401 でないことも明示的に書く**。

## 🔴 §3 が走査である理由

`Token.objects.get_or_create` は本 FEAT の実装前に **8 箇所**あった
（`social.py` に 7、`guest.py` に 1）。8 箇所に `if not user.is_active` を
配って回るのは、BUG-152 → BUG-153 で**2 回続けて失敗したのと同じ形**である
（手で数えた列挙は書いた瞬間から腐る）。9 箇所目を足す人が素通りする。

ヘルパー 1 本に集約し、**それ以外の場所での発行を走査で禁じる**。
"""

import re
from pathlib import Path
from unittest.mock import patch

from django.contrib import admin as django_admin
from django.contrib.auth import get_user_model
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import AccountSuspensionLog, PlayerProfile, SocialAccount
from api.services.auth_token import SUSPENDED_ERROR_CODE
from api.services.exp_service import create_default_stats

User = get_user_model()

_BACKEND = Path(__file__).resolve().parents[2]

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

# 【FEAT-535 CI hotfix と同じ理由】staticfiles を素の storage に落とす。
_PLAIN_STATIC = override_settings(STORAGES={
    'default': {'BACKEND': 'django.core.files.storage.FileSystemStorage'},
    'staticfiles': {
        'BACKEND': 'django.contrib.staticfiles.storage.StaticFilesStorage',
    },
})


def _fake_verify_id_token_factory(uid, email='', email_verified=False, name=''):
    payload = {
        'uid': uid, 'email': email,
        'email_verified': email_verified, 'name': name,
    }

    def _verify(_id_token):
        return payload
    return _verify


# ──────────────────────────────────────────────────────────────────────────
# §1 停止ユーザーの API は 403 + code
# ──────────────────────────────────────────────────────────────────────────
@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class SuspendedTokenIsRejectedWith403Test(APITestCase):
    """認証済トークンを持ったまま停止された場合。"""

    # 認証が必要で、副作用の無い GET。
    URL_NAME = 'player-weapons'

    def setUp(self):
        self.user = User.objects.create_user(
            'suspended_user', email='suspended@example.com',
        )
        self.player = PlayerProfile.objects.create(user=self.user, name='停止対象')
        create_default_stats(self.player)
        self.token = Token.objects.create(user=self.user)

    def _get(self):
        return self.client.get(
            reverse(self.URL_NAME),
            HTTP_AUTHORIZATION=f'Token {self.token.key}',
        )

    def test_active_user_passes(self):
        """回帰: 有効なユーザーは従来どおり通る。"""
        self.assertEqual(self._get().status_code, http_status.HTTP_200_OK)

    def test_suspended_user_gets_403_not_401(self):
        """🔴 **403 であること。401 ではないこと。**

        401 に戻ると Mobile の interceptor が黙ってトークンを消し、
        「停止されました」ではなく「ログインし直してください」が
        延々出る旧挙動に戻る —— **画面は出ないのにテストは緑**になる。
        """
        self.user.is_active = False
        self.user.save(update_fields=['is_active'])
        res = self._get()
        self.assertEqual(
            res.status_code, http_status.HTTP_403_FORBIDDEN,
            msg=f'403 でなければ Mobile に停止画面を出す隙が無い (実際: {res.status_code})',
        )
        self.assertNotEqual(res.status_code, http_status.HTTP_401_UNAUTHORIZED)

    def test_suspended_response_carries_the_code(self):
        """Mobile は code だけを見て停止と判定する。"""
        self.user.is_active = False
        self.user.save(update_fields=['is_active'])
        body = self._get().json()
        self.assertEqual(body['error']['code'], SUSPENDED_ERROR_CODE)
        self.assertIn('停止', body['error']['message'])

    def test_message_does_not_leak_the_reason(self):
        """⚠️ 停止理由は画面に出さない（回避方法を教えることになる）。

        message は固定文言で、`AccountSuspensionLog.reason` を含まない。
        """
        self.user.is_active = False
        self.user.save(update_fields=['is_active'])
        AccountSuspensionLog.objects.create(
            user=self.user, action='suspend', reason='内部用の理由テキスト',
        )
        body = self._get().json()
        self.assertNotIn('内部用の理由テキスト', body['error']['message'])


# ──────────────────────────────────────────────────────────────────────────
# §2 停止ユーザーはサインインでもトークンを得られない
# ──────────────────────────────────────────────────────────────────────────
@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class SuspendedUserCannotSignInTest(APITestCase):
    """⚠️ 「成功してから止める」のではなく、**発行せずに 403**。

    発行すると端末に停止済みトークンが残り、状態が二重になる。
    """

    def setUp(self):
        self.url = reverse('auth-social-verify')
        self.user = User.objects.create_user(
            'banned@example.com', email='banned@example.com', is_active=False,
        )
        player = PlayerProfile.objects.create(user=self.user, name='停止済')
        create_default_stats(player)
        SocialAccount.objects.create(
            user=self.user, provider='google',
            provider_uid='BANNED_UID', email='banned@example.com',
        )

    def _sign_in(self, uid='BANNED_UID', email='banned@example.com'):
        with patch(
            'firebase_admin.auth.verify_id_token',
            side_effect=_fake_verify_id_token_factory(
                uid=uid, email=email, email_verified=True,
            ),
        ):
            return self.client.post(
                self.url, {'id_token': 'dummy', 'provider': 'google'},
                format='json',
            )

    def test_sign_in_is_refused_with_403(self):
        res = self._sign_in()
        self.assertEqual(res.status_code, http_status.HTTP_403_FORBIDDEN)
        self.assertEqual(res.json()['error']['code'], SUSPENDED_ERROR_CODE)

    def test_no_token_is_issued(self):
        """🔴 拒否されただけでなく、**トークンが 1 件も作られていない**。"""
        self._sign_in()
        self.assertFalse(Token.objects.filter(user=self.user).exists())

    def test_active_user_still_signs_in(self):
        """回帰: 停止されていないユーザーは従来どおり入れる。"""
        ok_user = User.objects.create_user(
            'ok@example.com', email='ok@example.com',
        )
        player = PlayerProfile.objects.create(user=ok_user, name='通常')
        create_default_stats(player)
        SocialAccount.objects.create(
            user=ok_user, provider='google',
            provider_uid='OK_UID', email='ok@example.com',
        )
        res = self._sign_in(uid='OK_UID', email='ok@example.com')
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)
        self.assertIn('token', res.data)
        self.assertTrue(Token.objects.filter(user=ok_user).exists())


# ──────────────────────────────────────────────────────────────────────────
# §3 🔴 走査: トークン発行はヘルパー 1 本だけ
# ──────────────────────────────────────────────────────────────────────────
class TokenIssuanceIsFunneledThroughOneHelperTest(TestCase):
    """🔴 発行経路を**列挙で守らない**。

    実装前は `Token.objects.get_or_create` が 8 箇所にあった
    （`social.py` 7 / `guest.py` 1）。そこに停止チェックを配って回ると、
    **9 箇所目を足す人が素通りする** —— BUG-152 → BUG-153 で
    2 回続けて同じ形で失敗している。

    ⚠️ 走査は**空振りしうる**ので、下限と「実際に 1 件拾えること」も見る
    （`app_version_no_literal_test.dart` の B と同じ役割）。
    """

    HELPER = 'api/services/auth_token.py'

    def _python_sources(self):
        for path in (_BACKEND / 'api').rglob('*.py'):
            if 'migrations' in path.parts or 'tests' in path.parts:
                continue
            yield path

    @staticmethod
    def _issuance_calls(source: str) -> int:
        """`Token.objects.get_or_create(...)` の**呼び出し**を数える。

        ⚠️ 文字列走査では**コメントと docstring を拾う** —— 最初にこれを踏んだ。
        ヘルパー自身の docstring が「8 箇所にあった」と**説明している**ので、
        素朴な正規表現だと 1 件のはずが 3 件になった。
        見たいのは文章ではなく呼び出しなので AST で数える。
        """
        import ast

        count = 0
        for node in ast.walk(ast.parse(source)):
            if not isinstance(node, ast.Call):
                continue
            func = node.func
            if (isinstance(func, ast.Attribute) and func.attr == 'get_or_create'
                    and isinstance(func.value, ast.Attribute)
                    and func.value.attr == 'objects'
                    and isinstance(func.value.value, ast.Name)
                    and func.value.value.id == 'Token'):
                count += 1
        return count

    def test_issuance_appears_only_in_the_helper(self):
        offenders = []
        for path in self._python_sources():
            rel = path.relative_to(_BACKEND).as_posix()
            if rel == self.HELPER:
                continue
            if self._issuance_calls(path.read_text(encoding='utf-8')):
                offenders.append(rel)
        self.assertEqual(
            offenders, [],
            msg='トークン発行がヘルパーの外にあります: '
                f'{offenders} —— `api.services.auth_token.issue_token()` を'
                '通してください（停止チェックがそこにしかありません）',
        )

    def test_the_scan_is_not_vacuous(self):
        """🔴 空振り検出。

        走査対象が 0 ファイルでも、走査が何も拾えなくても
        上のテストは緑になる。**走査が生きていること**を別に縛る。
        """
        scanned = list(self._python_sources())
        self.assertGreaterEqual(
            len(scanned), 50,
            msg=f'走査対象が {len(scanned)} ファイルしかない。走査が壊れている',
        )
        helper = (_BACKEND / self.HELPER).read_text(encoding='utf-8')
        self.assertEqual(
            self._issuance_calls(helper), 1,
            msg='ヘルパー内に発行が 1 件だけあることを確認できない。'
                '走査が何も拾えていない可能性がある',
        )

    def test_helper_refuses_suspended_users(self):
        from rest_framework.exceptions import PermissionDenied

        from api.services.auth_token import issue_token

        user = User.objects.create_user(
            'helper_banned', email='helper_banned@example.com', is_active=False,
        )
        with self.assertRaises(PermissionDenied):
            issue_token(user)
        self.assertFalse(Token.objects.filter(user=user).exists())

    def test_helper_issues_for_active_users(self):
        from api.services.auth_token import issue_token

        user = User.objects.create_user('helper_ok', email='helper_ok@example.com')
        key = issue_token(user)
        self.assertTrue(key)
        self.assertEqual(Token.objects.get(user=user).key, key)


# ──────────────────────────────────────────────────────────────────────────
# §4 admin から切ると履歴が残る
# ──────────────────────────────────────────────────────────────────────────
@_PLAIN_STATIC
class SuspensionIsLoggedFromAdminTest(TestCase):
    """🔴 理由・日時・実行者が残らない ban は運用できない。

    解除の判断も、問い合わせへの回答もできなくなる。
    """

    def setUp(self):
        from api.middleware.admin_mfa import MFA_SESSION_KEY

        self.admin_user = User.objects.create_user(
            'feat541_super', email='feat541super@example.com',
            is_staff=True, is_superuser=True,
        )
        self.client.force_login(self.admin_user)
        session = self.client.session
        session[MFA_SESSION_KEY] = timezone.now().isoformat()
        session.save()

        self.target = User.objects.create_user(
            'feat541_target', email='feat541target@example.com',
        )
        self.url = reverse('admin:auth_user_change', args=[self.target.pk])

    def _post(self, is_active, reason=''):
        return self.client.post(self.url, {
            'username': self.target.username,
            'email': self.target.email,
            'first_name': '', 'last_name': '',
            'date_joined_0': '2026-01-01', 'date_joined_1': '00:00:00',
            **({'is_active': 'on'} if is_active else {}),
            'suspension_reason': reason,
            '_save': '保存',
        })

    def test_suspending_writes_a_log_row(self):
        self._post(is_active=False, reason='規約違反の疑い')
        log = AccountSuspensionLog.objects.get(user=self.target)
        self.assertEqual(log.action, 'suspend')
        self.assertEqual(log.reason, '規約違反の疑い')
        self.assertEqual(log.performed_by, self.admin_user)

    def test_lifting_writes_a_log_row(self):
        self.target.is_active = False
        self.target.save(update_fields=['is_active'])
        self._post(is_active=True)
        log = AccountSuspensionLog.objects.get(user=self.target, action='lift')
        self.assertEqual(log.performed_by, self.admin_user)

    def test_a_row_is_written_even_without_a_reason(self):
        """⚠️ 理由が空でも記録は残す。

        **何も残らないより、「いつ誰が」だけでも残るほうが良い。**
        """
        self._post(is_active=False, reason='')
        log = AccountSuspensionLog.objects.get(user=self.target)
        self.assertEqual(log.reason, '')
        self.assertIsNotNone(log.created_at)

    def test_saving_without_changing_is_active_writes_nothing(self):
        """無関係な保存で履歴が増えない（遷移だけを記録する）。"""
        self._post(is_active=True)
        self.assertFalse(AccountSuspensionLog.objects.exists())


# ──────────────────────────────────────────────────────────────────────────
# §5 履歴 admin は書き換え不可
# ──────────────────────────────────────────────────────────────────────────
class SuspensionLogIsAppendOnlyTest(TestCase):
    """⚠️ 履歴を後から書き換えられると証跡の意味が無い。"""

    def test_admin_refuses_add_change_delete(self):
        from django.test import RequestFactory

        request = RequestFactory().get('/admin/')
        request.user = User(is_staff=True, is_superuser=True)
        model_admin = django_admin.site._registry[AccountSuspensionLog]
        self.assertFalse(model_admin.has_add_permission(request))
        self.assertFalse(model_admin.has_change_permission(request))
        self.assertFalse(model_admin.has_delete_permission(request))
