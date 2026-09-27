"""【BUG-147 (2026-08-20)】起動時プローブが認証状態に引きずられないことを縛る。

## なぜ必要か

`permission_classes = [AllowAny]` **だけでは不十分**である。DRF は permission
より先に authentication を走らせるため、**無効な `Authorization` ヘッダが
付いていると `AllowAny` の endpoint でも 401 になる**。

Mobile の `ApiClient` は `onRequest` で全リクエストにトークンを付けるので、
端末に残った古いトークンが `AuthenticationFailed` を引き起こし、
`/api/health/` が 401 を返していた。`BootGate` は 200 以外を degraded と
判定するため「通信できませんでした」が出続け、**再試行も同じトークンを
送るため永久に回復しない**状態になっていた (2026-08-20、iOS 実機で発覚)。

iOS の Keychain は**アプリを削除しても残る**ため、再インストールでも
逃げられなかった。Android は uninstall で消えるので再インストールで復帰した
—— これが「iOS だけ壊れている」ように見えた理由である。

## 何を縛るか

起動時プローブが叩く 2 endpoint (`/api/health/` と `/api/maintenance/`) が、
**どんな `Authorization` ヘッダが付いていても認証を理由に落ちないこと**。

ヘルスチェックは**認証が壊れているときにこそ使いたい** endpoint である。
認証に引きずられる実装は、目的と正反対の挙動になる。
"""
from django.urls import reverse
from rest_framework.test import APITestCase

# 起動時に BootGate が叩く 2 経路 (mobile/lib/core/widgets/boot_gate.dart)。
_BOOT_PROBE_ROUTES = ('health', 'maintenance-status')

# 実際に踏んだ形。`GuestToken` は cleanup_guest_sessions で削除済のセッション、
# `Token` は TOKEN_EXPIRY_DAYS=30 を過ぎた失効トークンを想定している。
_BROKEN_AUTH_HEADERS = (
    ('無効なゲストトークン', 'GuestToken deadbeefdeadbeefdeadbeefdeadbeef'),
    ('無効なユーザートークン', 'Token deadbeefdeadbeefdeadbeefdeadbeef'),
    ('形式不正なゲストトークン', 'GuestToken'),
    ('未知の keyword', 'Bearer something'),
)


class BootProbeIgnoresAuthTest(APITestCase):
    """起動時プローブは認証状態に関係なく応答する。"""

    def test_responds_without_any_auth_header(self):
        """前提条件。ヘッダ無しで 200 が返ること。"""
        for route in _BOOT_PROBE_ROUTES:
            with self.subTest(route=route):
                res = self.client.get(reverse(route))
                self.assertEqual(res.status_code, 200)

    def test_never_401s_on_broken_auth_header(self):
        """🔴 本テストの本体。壊れたトークンが付いていても 401 にならない。

        ここが赤いとき、Mobile は起動直後に「通信できませんでした」から
        **自力で抜け出せない**状態になる (再試行も同じトークンを送るため)。
        """
        for route in _BOOT_PROBE_ROUTES:
            for label, header in _BROKEN_AUTH_HEADERS:
                with self.subTest(route=route, auth=label):
                    res = self.client.get(
                        reverse(route), HTTP_AUTHORIZATION=header,
                    )
                    self.assertNotEqual(
                        res.status_code, 401,
                        f'{route} が {label} で 401 を返した。'
                        ' authentication_classes = [] が外れていないか確認すること。',
                    )
                    self.assertEqual(res.status_code, 200)

    def test_declares_empty_authentication_classes(self):
        """`AllowAny` だけの実装に戻されたら落とす。

        振る舞いテストだけだと「なぜ 200 なのか」が読み取れないため、
        意図そのものを直接 assert する。
        """
        from api.views.health import HealthCheckView
        from api.views.maintenance import MaintenanceStatusView

        for view in (HealthCheckView, MaintenanceStatusView):
            with self.subTest(view=view.__name__):
                self.assertEqual(
                    list(view.authentication_classes), [],
                    f'{view.__name__}.authentication_classes は空でなければならない。'
                    ' permission_classes = [AllowAny] だけでは 401 を防げない'
                    ' (DRF は permission より先に authentication を走らせる)。',
                )
