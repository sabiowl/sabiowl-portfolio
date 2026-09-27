"""【FEAT-541 (2026-09-06)】トークン発行の**唯一の入口**と、停止の表現。

## なぜヘルパー 1 本にするのか

本 FEAT の実装前、`Token.objects.get_or_create` は **8 箇所**にあった
(`views/auth/social.py` に 7、`views/auth/guest.py` に 1)。
そこへ `if not user.is_active` を配って回るのは、
BUG-152 → BUG-153 で **2 回続けて失敗したのと同じ形**である ——
**手で数えた列挙は書いた瞬間から腐り、9 箇所目を足す人が素通りする。**

そこで発行を `issue_token()` 1 本に集約し、
**それ以外の場所での `Token.objects.get_or_create` を走査で禁じた**
(`tests/test_account_suspension.py` の §3)。新しい発行経路が増えても、
ヘルパーを通らなければ CI が落ちる。

## 🔴 なぜ 401 ではなく 403 なのか

停止を 401 (`AuthenticationFailed`) で返すと、Mobile の既存 interceptor が
**問答無用でトークンを消してログイン画面へ飛ばす** ——
ログインし直す → また 401 → …… と続き、
**「停止されました」ではなく「ログインし直してください」が延々出る。**
停止画面が表示される隙が無い。

意味論としても 403 が正しい: 401 は「認証できていない」であり、
停止は「**誰かは分かっている、その上で許可しない**」だからである。

## 🔴 停止の真実値は `User.is_active` **単独**

2 つ目のフラグ (`is_suspended` 等) を作らないこと。`is_active` は
既に認証が見ており、admin にチェックボックスがあり、Django admin への
ログインも塞ぐ。もう 1 つ足すと**必ず食い違う**。
`AccountSuspensionLog` は**履歴**であって、状態の真実値ではない。

⚠️ ゲスト (`GuestSession` → `PlayerProfile` 直結) は `User` を持たないので
対象外である。案 A の割り切りとして指示書 §6 に明記されている。
"""

from rest_framework.authtoken.models import Token
from rest_framework.exceptions import PermissionDenied

# Mobile はこの code **だけ**を見て停止と判定する。
# 🔴 403 という status だけをトリガにしてはいけない (他の 403 と混ざる)。
SUSPENDED_ERROR_CODE = 'auth_account_suspended'

# ⚠️ 停止理由をここに出さない。出すと回避方法を教えることになり、
#    文言の運用コストも常時かかる。理由は `AccountSuspensionLog.reason` に残し、
#    ユーザーには問い合わせ導線だけを示す (指示書 §3-1)。
SUSPENDED_MESSAGE = (
    'このアカウントは現在停止されています。'
    '心当たりがない場合は、お問い合わせからご連絡ください 🪶'
)


def suspended_error() -> dict:
    """403 の body。`_guest_auth_error()` と同じ作り方。

    DRF の `exception_handler` は `exc.detail` が dict のとき
    **それをそのままレスポンス body にする**ので、
    `{'error': {'code', 'message'}}` の形で返り、Mobile の
    `ApiError.fromResponse()` がそのまま parse できる。
    """
    return {'error': {'code': SUSPENDED_ERROR_CODE, 'message': SUSPENDED_MESSAGE}}


class AccountSuspended(PermissionDenied):
    """停止済アカウントからのアクセス。**403** で返る。"""

    def __init__(self):
        super().__init__(suspended_error())


def issue_token(user) -> str:
    """トークン発行の唯一の入口。停止中のユーザーには発行しない。

    ⚠️ 「発行してから止める」のではなく、**発行せずに 403** を投げる。
    発行すると端末に停止済みトークンが残り、状態が二重になる。

    Raises:
        AccountSuspended: `user.is_active` が False のとき (403)
    """
    if not user.is_active:
        raise AccountSuspended()
    token, _ = Token.objects.get_or_create(user=user)
    return token.key
