"""View 共通ヘルパー関数（FEAT-187）。

ゲストモードと認証済みユーザーの両方から PlayerProfile を取得するヘルパー。
View 全体で `request.user.player_profile` 直接参照を避け、本関数を経由する。
"""

from rest_framework.exceptions import NotAuthenticated


def get_player_for_request(request):
    """認証済みユーザー or ゲストセッションから PlayerProfile を取得する。

    使い分け:
    - 認証済みユーザー: `request.user.player_profile`
    - ゲストセッション: `request.auth.player_profile`（GuestTokenAuthentication 経由）

    どちらでもない場合は NotAuthenticated を投げる（permission_class で
    弾いていれば到達しないが、防御として）。
    """
    # 遅延 import: 循環参照を避ける
    from ..models.auth import GuestSession

    if request.user and request.user.is_authenticated:
        return request.user.player_profile
    if isinstance(request.auth, GuestSession):
        return request.auth.player_profile
    raise NotAuthenticated('認証されていません。')
