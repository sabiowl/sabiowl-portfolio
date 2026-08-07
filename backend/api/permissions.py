"""カスタム permission class（FEAT-187）。

ゲストモード（GuestSession）でも API アクセスを許可するための permission。
"""

from rest_framework import permissions


class IsAuthenticatedOrGuest(permissions.BasePermission):
    """認証済みユーザー、またはゲストセッションを持つリクエストを許可する。

    使用例:
        from .authentication import GuestTokenAuthentication
        from .permissions import IsAuthenticatedOrGuest
        from .views._helpers import get_player_for_request

        class HabitListCreateView(APIView):
            authentication_classes = [
                ExpiringTokenAuthentication,
                GuestTokenAuthentication,
            ]
            permission_classes = [IsAuthenticatedOrGuest]

            def get(self, request):
                player = get_player_for_request(request)
                ...
    """

    message = '認証されていません。'

    def has_permission(self, request, view):
        # 遅延 import: 循環参照を避ける
        from .models.auth import GuestSession

        # 認証済みユーザー
        if request.user and request.user.is_authenticated:
            return True
        # ゲストセッション
        if isinstance(request.auth, GuestSession):
            return True
        return False
