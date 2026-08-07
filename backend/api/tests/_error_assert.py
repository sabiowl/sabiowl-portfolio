"""【FEAT-515】テストからエラーレスポンスを読むための小ヘルパー。

## なぜ必要か

Backend のエラー形式は 3 つ並存している:

| 形式 | 例 | 由来 |
|---|---|---|
| 新 | `{'error': {'code': 'x', 'message': '…'}}` | `error_response()` |
| 旧 A | `{'error': 'x', 'message': '…'}` | 手書きの過渡形 |
| 旧 B | `{'error': '日本語の文言'}` | 最初期 |

テストが `res.data['error']` を直接読むと、**形式を移した瞬間に落ちる**。
落ちるだけならまだよいが、`data['error'] == 'not_ssr'` のような比較は
新形式で `dict == str` になり **例外も出さずに False** になる。
Mobile 側で実際に起きていたのと同じ形 (`battle_service.dart`)。

そこで **形式に依存しない読み方**をここに 1 つだけ用意する。

## 使い方

```python
from ._error_assert import error_code, error_message

self.assertEqual(error_code(res), 'gacha_pull_not_enough_tickets')
self.assertIn('チケット', error_message(res))
```
"""


def _body(response):
    return getattr(response, 'data', None) or {}


def error_code(response) -> str:
    """レスポンスからエラー code を取り出す (3 形式対応)。

    旧 B (日本語文言のみ) には code が無いので、その場合は文言をそのまま返す
    —— 移行前のテストが `data['error']` を文言として比較していた挙動と一致する。
    """
    err = _body(response).get('error')
    if isinstance(err, dict):
        return str(err.get('code', ''))
    return str(err) if err is not None else ''


def error_message(response) -> str:
    """レスポンスから user 向け文言を取り出す (3 形式対応)。"""
    body = _body(response)
    err = body.get('error')
    if isinstance(err, dict):
        return str(err.get('message', ''))
    # 旧 A は top-level の message / detail に文言がある
    for key in ('message', 'detail'):
        if body.get(key):
            return str(body[key])
    return str(err) if err is not None else ''


def error_fields(response) -> dict:
    """field 単位のバリデーションエラーを取り出す。"""
    body = _body(response)
    err = body.get('error')
    if isinstance(err, dict) and isinstance(err.get('fields'), dict):
        return err['fields']
    return body.get('errors') or {}
