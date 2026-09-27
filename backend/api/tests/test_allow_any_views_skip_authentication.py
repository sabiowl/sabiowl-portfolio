"""【BUG-147 (2026-08-20)】AllowAny な view は認証を一切走らせない、という不変条件。

## なぜこのテストが要るか

DRF は **permission より先に authentication を走らせる**。したがって
`permission_classes = [AllowAny]` を書いても、**無効な `Authorization` ヘッダが
付いていれば認証が `AuthenticationFailed` を投げて 401 になる**。
「AllowAny だから誰でも通る」は誤りで、正しくは「AllowAny だから *権限* は問わない、
ただし *認証* は走る」である。

Mobile の `ApiClient` は onRequest で **全リクエスト**にトークンを付けるため、
端末に無効なトークンが 1 個残っているだけで AllowAny な endpoint が全滅する。
2026-08-20 に iOS 実機で `/api/health/` が 401 になり、`BootGate` が
「通信できませんでした」を出し続けて回復不能になったのがこの経路である。

AllowAny を選ぶ view は「認証状態に関係なく到達できる必要がある」から選んでいる。
ヘルスチェック・メンテナンス告知・ゲスト初期化・サインイン・問い合わせ —— どれも
**認証が壊れているときにこそ使いたい** endpoint である。
`authentication_classes = []` を書き忘れると、その目的が静かに失われる。

失敗は「401 が返る」という形でしか現れず、原因は認証クラスの宣言漏れなので、
ログを見ても view のコードを見ても分からない。だから宣言そのものを縛る。

## 例外を足したくなったら

足さないこと。認証情報を **見たい** だけなら AllowAny ではなく
`IsAuthenticatedOrGuest` 等を使うか、view 内で `request.META` を自前で読む。
それでも例外が必要なら `_EXEMPT` に **理由付きで**追加し、その view が
無効トークンでも 401 にならないことを別途テストすること。
"""
import importlib
import inspect
import pkgutil

from django.test import SimpleTestCase
from rest_framework.permissions import AllowAny
from rest_framework.views import APIView

# 例外は現状ゼロ。追加するときは docstring の「例外を足したくなったら」を読むこと。
_EXEMPT: dict[str, str] = {}


def _iter_view_classes():
    """`api.views` 配下の全 APIView サブクラスを (module, class) で返す。"""
    import api.views as views_pkg

    seen: set[type] = set()
    modules = [views_pkg]
    for info in pkgutil.walk_packages(views_pkg.__path__, prefix='api.views.'):
        modules.append(importlib.import_module(info.name))

    for module in modules:
        for _, obj in inspect.getmembers(module, inspect.isclass):
            if not issubclass(obj, APIView) or obj is APIView:
                continue
            # api.views 配下で定義されたものだけ (DRF 由来の import は除外)
            if not (obj.__module__ or '').startswith('api.views'):
                continue
            if obj in seen:
                continue
            seen.add(obj)
            yield obj


class AllowAnyViewsSkipAuthenticationTest(SimpleTestCase):

    def test_allow_any_views_declare_empty_authentication_classes(self):
        offenders = []
        checked = 0
        for view in _iter_view_classes():
            if AllowAny not in tuple(view.permission_classes or ()):
                continue
            if view.__name__ in _EXEMPT:
                continue
            checked += 1
            if tuple(view.authentication_classes or ()):
                offenders.append(
                    f'{view.__module__}.{view.__name__} '
                    f'-> {[c.__name__ for c in view.authentication_classes]}'
                )

        self.assertGreater(
            checked, 0,
            'AllowAny な view が 1 つも見つからない。'
            '本テストの探索が壊れている可能性が高い (BUG-147)。',
        )
        self.assertEqual(
            offenders, [],
            'AllowAny なのに authentication_classes を空にしていない view がある。\n'
            'DRF は permission より先に authentication を走らせるため、'
            '無効な Authorization ヘッダが付くと AllowAny でも 401 になる。\n'
            '`authentication_classes: list = []` を宣言すること (BUG-147):\n  '
            + '\n  '.join(offenders),
        )

    def test_boot_and_rescue_routes_are_covered(self):
        """回復経路の view が探索から漏れていないことを固定する。

        `_iter_view_classes` が壊れて 0 件になっても上のテストは
        `checked > 0` でしか気付けない。**壊れたときに一番困る view** を
        名指しで確認しておく。
        """
        required = {
            'HealthCheckView',      # BootGate の起動 probe
            'MaintenanceStatusView',  # メンテ告知
            'GuestInitView',        # ゲスト再初期化 (BUG-147 Phase B の回復経路)
            'SocialAuthView',       # サインイン = 壊れた端末の当座の回復手段
            'ContactView',          # 問い合わせ = 最後の救済経路
        }
        found = {
            v.__name__ for v in _iter_view_classes()
            if AllowAny in tuple(v.permission_classes or ())
        }
        self.assertEqual(
            required - found, set(),
            '回復経路の view が AllowAny 一覧から消えている: '
            f'{sorted(required - found)}',
        )
