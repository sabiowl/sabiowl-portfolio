"""サインアウト View（旧 magic_link.py から退避）。"""
from rest_framework.authentication import TokenAuthentication
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView


class LogoutView(APIView):
    """サインアウト処理。Django Token を破棄するのみ（Firebase 側は Flutter で処理）。"""

    authentication_classes = [TokenAuthentication]
    permission_classes = [IsAuthenticated]

    def post(self, request):
        try:
            request.user.auth_token.delete()
        except Exception:
            pass
        return Response({'detail': 'ログアウトしました。'})
