"""【BUG-163 (2026-09-12)】停止検査が全エンドポイントに効いていなかった。

## 起点

dev 実機確認 2026-09-12。admin で `is_active` を外すと停止画面は出たが、
**「再試行」を押すとログイン画面に飛んだ。**

原因は **20 個の view ファイルが DRF 素の `TokenAuthentication` を
直接宣言していた**ことである。

    from rest_framework.authentication import TokenAuthentication
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]

`settings.py` の `DEFAULT_AUTHENTICATION_CLASSES` は
`api.authentication.ExpiringTokenAuthentication` を指しているが、
**view 側の宣言はそれを上書きする。**

## 何が壊れていたか

DRF 素の `TokenAuthentication` は 2 つとも持っていない:

| 機能 | 素の DRF | `ExpiringTokenAuthentication` |
|---|:-:|:-:|
| 停止検査 (FEAT-541、**403** + `auth_account_suspended`) | ❌ **401** を返す | ✅ |
| スライディング期限 (BUG-155、`token.created` の更新) | ❌ 期限判定すら無い | ✅ |

🔴 **401 は Mobile の既存 interceptor が捕まえ、トークンを消して
`markSessionExpired()` を呼ぶ。** `accountSuspendedProvider` も一緒に
下ろされるので、**停止画面が出る余地が消える** ——
これが実機で見えた「再試行 → ログイン画面」である。

⚠️ **FEAT-541 が 403 を選んだ理由がそのまま裏返っていた。**
指示書は「401 だと interceptor が強制ログアウトして停止画面の余地が無い」と
書いていたのに、**その 401 が view 側の宣言から入ってきていた。**

## 🔴 なぜ走査を URL から行うのか

`settings.py` の既定だけを見て「全経路を押さえた」と判断したのが
今回の誤りである。**宣言は上書きされる。**

BUG-152 (5 model) → BUG-153 (8 model) → FEAT-541 (8 トークン発行箇所) →
BUG-156 → BUG-159 → BUG-160 と**同じ形で 6 回続けて失敗している**。

🔵 **ソース文字列の grep でも「素の import が 0 件」は縛れるが、
`as TokenAuthentication` のような別名で簡単にすり抜ける。**
URL から view を解決して**実際に適用されるクラス**を見れば、
書き方に依存しない。
"""

from django.test import TestCase
from django.urls import URLPattern, URLResolver
from rest_framework.authentication import TokenAuthentication

from api.authentication import ExpiringTokenAuthentication, GuestTokenAuthentication


def _iter_view_classes(patterns, prefix=''):
    """URL パターンを辿って APIView のクラスを列挙する。

    ⚠️ `as_view()` の戻り値には `cls` が付く (DRF / Django の APIView)。
    付いていないもの (関数 view / admin) は対象外。
    """
    for entry in patterns:
        if isinstance(entry, URLResolver):
            yield from _iter_view_classes(
                entry.url_patterns, prefix + str(entry.pattern)
            )
        elif isinstance(entry, URLPattern):
            cls = getattr(entry.callback, 'cls', None)
            if cls is not None:
                yield prefix + str(entry.pattern), cls


class SuspensionCoversEveryEndpointTest(TestCase):
    """🔴 §走査: DRF 素の `TokenAuthentication` を使っている view が無い。"""

    def _endpoints(self):
        from api import urls as api_urls
        return list(_iter_view_classes(api_urls.urlpatterns))

    def test_the_scan_actually_finds_endpoints(self):
        """空振り検出。

        🔴 走査が 0 件を返したまま緑になる形 (import 先の変更 /
        `urlpatterns` の構造変更) を防ぐ。**まず「見つかっている」ことを
        縛ってから内訳を見る。**
        """
        endpoints = self._endpoints()
        self.assertGreater(
            len(endpoints), 50,
            f'走査が view を {len(endpoints)} 件しか見つけていない。'
            'URL の構造が変わって走査が壊れている',
        )

    def test_the_scan_actually_finds_token_authenticated_endpoints(self):
        """空振り検出その 2。

        ⚠️ 「トークン認証を使っている view」が 1 件も見つからないなら、
        下の本体テストは**何も検査していない**ことになる。
        """
        hits = [
            path for path, cls in self._endpoints()
            if any(
                issubclass(a, TokenAuthentication)
                for a in getattr(cls, 'authentication_classes', ())
            )
        ]
        self.assertGreater(
            len(hits), 30,
            f'トークン認証の view が {len(hits)} 件しか見つかっていない。'
            '走査が壊れている',
        )

    def test_no_endpoint_uses_bare_drf_token_authentication(self):
        """🔴 本体。

        **素の `TokenAuthentication` を使う view は、停止されたユーザーに
        401 を返す。** Mobile はそれを「セッション失効」と解釈して
        トークンを消し、停止画面を出せなくなる。
        """
        offenders = []
        for path, cls in self._endpoints():
            for auth in getattr(cls, 'authentication_classes', ()):
                if (
                    issubclass(auth, TokenAuthentication)
                    and not issubclass(auth, ExpiringTokenAuthentication)
                ):
                    offenders.append(f'{path} -> {cls.__name__}.{auth.__name__}')

        self.assertEqual(
            offenders, [],
            '素の DRF TokenAuthentication を使っている endpoint がある。'
            '停止されたユーザーに 401 を返すので、Mobile が強制ログアウトし、'
            '停止画面が出なくなる (BUG-163)。'
            'api.authentication.ExpiringTokenAuthentication を使うこと:\n  '
            + '\n  '.join(offenders),
        )

    def test_guest_token_authentication_is_left_alone(self):
        """🔵 ゲスト側は**意図的に対象外**である。

        ゲストは `User` を持たない (`GuestSession` → `PlayerProfile` 直結) ので
        `is_active` が存在しない。**止める対象そのものが無い** (FEAT-541 案 A)。

        ⚠️ このテストは「ゲストにも停止を足すべきだ」と考えた人が
        `GuestTokenAuthentication` を `TokenAuthentication` の subclass に
        しようとしたときに落ちる —— **その変更は FEAT-541 の割り切りを
        変えるので、指示書から書き直すこと。**
        """
        self.assertFalse(
            issubclass(GuestTokenAuthentication, TokenAuthentication),
            'GuestTokenAuthentication が TokenAuthentication の subclass に'
            'なっている。ゲストは User を持たないので停止の対象外である',
        )


class SuspensionResponseShapeTest(TestCase):
    """🔴 停止されたユーザーが **403** を受け取ることを、実際に叩いて確かめる。

    ⚠️ 上の走査は「正しいクラスが宣言されている」ことしか見ていない。
    **返る status code までは保証しない**ので、代表経路で実測する。
    """

    def setUp(self):
        from django.contrib.auth.models import User
        from rest_framework.authtoken.models import Token

        from api.models import PlayerProfile

        self.user = User.objects.create_user(
            username='suspended@example.com',
            email='suspended@example.com',
            password='x',
        )
        PlayerProfile.objects.get_or_create(user=self.user, defaults={'name': 'テスト'})
        self.token = Token.objects.create(user=self.user)

    def _get(self, path):
        return self.client.get(
            path, HTTP_AUTHORIZATION=f'Token {self.token.key}'
        )

    def test_active_user_is_not_blocked(self):
        """空振り検出: 停止前は通ること。

        🔴 これが無いと「その endpoint が常に 403 を返す」実装でも
        下のテストが緑になる。
        """
        res = self._get('/api/habits/')
        self.assertNotEqual(
            res.status_code, 403,
            '停止していないのに 403 が返っている。前提が崩れている',
        )

    def test_suspended_user_gets_403_with_the_code(self):
        """🔴 停止中は **403** + `auth_account_suspended`。

        ⚠️ **401 だと Mobile が強制ログアウトする**ので、
        status code そのものが仕様である。
        """
        self.user.is_active = False
        self.user.save(update_fields=['is_active'])

        res = self._get('/api/habits/')

        self.assertEqual(
            res.status_code, 403,
            f'停止中のユーザーに {res.status_code} が返っている。'
            '401 だと Mobile がトークンを消して停止画面を出せなくなる',
        )
        body = res.json()
        code = body.get('error', {}).get('code') if isinstance(body, dict) else None
        self.assertEqual(
            code, 'auth_account_suspended',
            f'エラー code が違う (実際: {code})。'
            'Mobile はこの code だけで停止画面を出す',
        )

    def test_several_representative_endpoints_agree(self):
        """🔵 1 本だけ直して満足しないための横断確認。

        ⚠️ **手で並べたリストである。** 網羅は上の走査テストの役目で、
        ここは「走査が見ている宣言が、実際の応答と一致する」ことの
        抜き取り確認である。
        """
        self.user.is_active = False
        self.user.save(update_fields=['is_active'])

        for path in (
            '/api/habits/',
            '/api/player/',
            '/api/home/',
            '/api/timeline/',
            '/api/gacha/status/',
            '/api/notifications/',
        ):
            with self.subTest(path=path):
                res = self._get(path)
                self.assertEqual(
                    res.status_code, 403,
                    f'{path} が {res.status_code} を返している',
                )
