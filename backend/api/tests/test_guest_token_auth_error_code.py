"""【BUG-147 Phase B-1 (2026-08-20)】無効なゲストトークンの 401 に code が載る。

## なぜこのテストが要るのか

Mobile はゲストセッションを作り直すかどうかを **`code` だけ**で判断する
(`api_client.dart`)。`401` そのものをトリガにすると、FEAT-193 が防いだ事故
——一時的な 401 でゲストトークンを破棄し、端末初期化と同等のデータロスを
起こした——に戻る。したがって

  * `auth_guest_token_invalid`   … サーバが「そんなトークンは無い」と断定した
  * `auth_guest_token_malformed` … ヘッダの形が壊れている (クライアント側の不具合かも)

の 2 つを**分けて**返せていることが、Mobile 側の安全性の前提になる。

## 401 が 403 に化けないこと

DRF の `APIView.handle_exception` は `get_authenticate_header()` が `None` を
返すと `AuthenticationFailed` の status を **403 に書き換える**。
`GuestTokenAuthentication` は `authenticate_header()` を定義していないが、
`DEFAULT_AUTHENTICATION_CLASSES` の先頭が `ExpiringTokenAuthentication`
(`keyword = 'Token'` を持つ) なので現状は 401 が保たれている。

**この成立条件は settings の並び順という間接的なもの**なので、テストで固定する。
403 になると Mobile の 401 分岐に入らず、回復経路が丸ごと死ぬ。
"""
import json

from django.contrib.auth import get_user_model
from django.urls import reverse
from rest_framework.test import APITestCase

from api.authentication import _guest_auth_error

User = get_user_model()


def _body(res) -> dict:
    return json.loads(res.content.decode())


class GuestTokenAuthErrorCodeTest(APITestCase):
    """認証必須 endpoint に壊れたゲストトークンを付けたときの 401 body。"""

    # 認証が必要で、かつ副作用の無い GET を選ぶ。
    URL_NAME = 'player-weapons'

    def _get(self, header_value):
        return self.client.get(
            reverse(self.URL_NAME), HTTP_AUTHORIZATION=header_value)

    # ── サーバが「知らない」と断定した経路 ──────────────────────────

    def test_unknown_guest_token_returns_401_with_invalid_code(self):
        res = self._get('GuestToken deadbeefdeadbeefdeadbeef')

        self.assertEqual(res.status_code, 401, res.content)
        body = _body(res)
        self.assertEqual(body['error']['code'], 'auth_guest_token_invalid')
        self.assertTrue(body['error']['message'].strip(),
                        'message が空だと Mobile が表示する文言を失う')

    def test_unknown_guest_token_does_not_become_403(self):
        """🔴 403 に化けたら Mobile の 401 分岐に入らず回復経路が死ぬ。

        DRF は `get_authenticate_header()` が None を返すと 401 → 403 に
        書き換える。成立条件が settings の並び順という間接的なものなので、
        **振る舞いとして**固定する。
        """
        res = self._get('GuestToken deadbeefdeadbeefdeadbeef')
        self.assertNotEqual(
            res.status_code, 403,
            '401 が 403 に化けている。DEFAULT_AUTHENTICATION_CLASSES の先頭が '
            'authenticate_header() を持つクラスか確認すること',
        )

    # ── ヘッダ形式が壊れている経路 ──────────────────────────────────

    def test_malformed_header_returns_malformed_code(self):
        """要素数 != 2。**invalid とは別の code** でなければならない。

        形式不正で再初期化すると、クライアント側の不具合を隠したまま
        ゲストセッションを量産することになる。
        """
        res = self._get('GuestToken')

        self.assertEqual(res.status_code, 401, res.content)
        self.assertEqual(
            _body(res)['error']['code'], 'auth_guest_token_malformed')

    def test_malformed_header_with_extra_parts(self):
        res = self._get('GuestToken aaa bbb')

        self.assertEqual(res.status_code, 401, res.content)
        self.assertEqual(
            _body(res)['error']['code'], 'auth_guest_token_malformed')

    def test_malformed_is_not_the_recovery_code(self):
        """形式不正が invalid に混ざっていない (Mobile が再初期化しない側)。"""
        for header in ('GuestToken', 'GuestToken aaa bbb'):
            with self.subTest(header=header):
                self.assertNotEqual(
                    _body(self._get(header))['error']['code'],
                    'auth_guest_token_invalid',
                )

    # ── 形式そのもの ────────────────────────────────────────────────

    def test_error_body_shape_matches_error_response_helper(self):
        """`error_response()` と同じ `{'error': {'code', 'message'}}` 形式。

        `authentication.py` は `backend/api/views/` の外なので
        `test_error_response_format.py` のソース走査に入らない。
        Mobile の parser は 1 つしかないので、ここで形を縛る。
        """
        body = _body(self._get('GuestToken deadbeef'))
        self.assertIn('error', body)
        self.assertEqual(sorted(body['error']), ['code', 'message'])

    def test_helper_returns_the_documented_shape(self):
        self.assertEqual(
            _guest_auth_error('x_code', 'x_message'),
            {'error': {'code': 'x_code', 'message': 'x_message'}},
        )
