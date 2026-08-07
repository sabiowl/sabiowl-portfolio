"""View 共通 Mixin（FEAT-187 でゲスト対応化）。

`PlayerMixin.get_player(request)` は認証済みユーザー / ゲストセッション の
どちらからでも PlayerProfile を取得する。

- 認証済みユーザー: `request.user.player_profile`
- ゲストセッション: `request.auth.player_profile`（`GuestTokenAuthentication` 経由）

View 側で本 Mixin を継承し、`get_player(request)` を呼び出すだけで両モード対応できる。
ゲスト未対応の View（social / notifications 等）は permission_class で
`IsAuthenticated` を使えば、本 Mixin の get_player までは呼ばれない（防御深化）。
"""

from rest_framework.exceptions import NotAuthenticated

from ..models import PlayerProfile


class PlayerMixin:
    """authenticated user / guest session の双方から PlayerProfile を取得する Mixin。"""

    def get_player(self, request) -> PlayerProfile:
        # 認証済みユーザー
        if request.user and request.user.is_authenticated:
            try:
                return request.user.player_profile
            except PlayerProfile.DoesNotExist:
                raise NotAuthenticated()

        # FEAT-187: ゲストセッション
        # 遅延 import: 循環参照を避ける
        from ..models.auth import GuestSession
        if isinstance(request.auth, GuestSession):
            return request.auth.player_profile

        raise NotAuthenticated()
