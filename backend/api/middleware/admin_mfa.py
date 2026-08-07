"""【2026-06-29】Django admin 画面 ログイン時のメール OTP MFA 強制 middleware。

判定ロジック:
    1. `settings.DEBUG=True` かつ `settings.ADMIN_MFA_REQUIRED=False` → bypass
       (ローカル開発時の煩雑さ回避、本番は常に強制 ON)
    2. request.path が admin 以外 → bypass
    3. 除外パス (login / logout / mfa 自身) → bypass
    4. user.is_authenticated かつ user.is_staff → MFA verified を session で確認
       4-1. session['admin_mfa_verified_at'] が有効期限内 (12 時間) → 通過
       4-2. 上記不成立 → /admin/mfa/challenge/ へ redirect

設計上の注意:
    - `_ADMIN_PATH_PREFIX` は `ADMIN_URL` 環境変数から動的に組み立てる
      (config/urls.py が `path(ADMIN_URL, admin.site.urls)` でマウントしているため、
       Render で予測困難なパス `hg-admin-xxxxxxxx/` に変えていても整合する)
    - 既存 `maintenance.py` middleware と同じパターンで `os.environ.get` 経由
    - django.contrib.auth.middleware.AuthenticationMiddleware が先に走って
      `request.user` が組み立てられている前提。settings.MIDDLEWARE の順序で保証する。

【Pre-mortem 対策】
    - DB 障害時の session 取得失敗 → 例外を握り潰さず標準挙動 (Django session middleware
      が先に handle)。本 middleware は session の読み取り or redirect のみで DB に
      直接アクセスしないため maintenance.py の defensive try/except は不要。
    - URL ループ防止: 除外パスを明示列挙、settings.LOGIN_URL も除外。
"""
import os

from django.conf import settings
from django.shortcuts import redirect
from django.utils import timezone
from django.utils.deprecation import MiddlewareMixin


# config/urls.py と同じ ADMIN_URL 環境変数を参照する (Render で予測困難なパスに
# 変更されている場合でも本 middleware が正しく gate するよう、ハードコード '/admin/' にしない)。
_ADMIN_PATH_PREFIX = '/' + os.environ.get('ADMIN_URL', 'admin/')

# MFA verified session の有効期限 (秒)。設計判断: 12 時間 = 一日作業中は再認証不要、
# 夜に切れる UX。30 分等の短い設定にしたい場合は ADMIN_MFA_SESSION_SECONDS 環境変数で上書き可。
_DEFAULT_MFA_SESSION_SECONDS = 12 * 60 * 60

# session 内のキー名 (views/admin_mfa.py と共有)
MFA_SESSION_KEY = 'admin_mfa_verified_at'


def _mfa_session_seconds() -> int:
    """環境変数 ADMIN_MFA_SESSION_SECONDS で上書き可能、未設定なら 12 時間。"""
    try:
        return int(os.environ.get('ADMIN_MFA_SESSION_SECONDS', _DEFAULT_MFA_SESSION_SECONDS))
    except (ValueError, TypeError):
        return _DEFAULT_MFA_SESSION_SECONDS


def is_mfa_fresh(request) -> bool:
    """session 内 MFA verified タイムスタンプが有効期限内か判定。

    public ユーティリティ (views/admin_mfa.py からも参照される)。
    """
    ts_iso = request.session.get(MFA_SESSION_KEY)
    if not ts_iso:
        return False
    try:
        ts = timezone.datetime.fromisoformat(ts_iso)
    except (ValueError, TypeError):
        return False
    elapsed = (timezone.now() - ts).total_seconds()
    return elapsed < _mfa_session_seconds()


class AdminMFARequiredMiddleware(MiddlewareMixin):
    """admin 画面へのアクセス時に OTP MFA を強制する middleware。

    AuthenticationMiddleware の後に登録すること (request.user が必要)。
    """

    def process_request(self, request):
        # 1. ローカル開発時の bypass (DEBUG かつ ADMIN_MFA_REQUIRED=False)
        if settings.DEBUG and not getattr(settings, 'ADMIN_MFA_REQUIRED', True):
            return None

        # 2. admin 以外のパスは bypass
        path = request.path
        if not path.startswith(_ADMIN_PATH_PREFIX):
            return None

        # 3. 除外パス: login / logout / mfa challenge / mfa verify は MFA 不要
        #    (login で未認証 → password 認証 → middleware が次回叩かれて MFA へ進む)
        excluded_suffixes = ('login/', 'logout/', 'mfa/challenge/', 'mfa/verify/')
        relative_path = path[len(_ADMIN_PATH_PREFIX):]
        if any(relative_path.startswith(s) for s in excluded_suffixes):
            return None

        # 4. 未認証 / 非 staff は Django 標準の admin login で弾かれる (本 middleware は touch しない)
        user = getattr(request, 'user', None)
        if not user or not user.is_authenticated or not user.is_staff:
            return None

        # 5. MFA verified session が有効期限内なら通過
        if is_mfa_fresh(request):
            return None

        # 6. MFA challenge view へ redirect (challenge view が GET なら自動で OTP 発行 + verify へ)
        return redirect(f'{_ADMIN_PATH_PREFIX}mfa/challenge/')
