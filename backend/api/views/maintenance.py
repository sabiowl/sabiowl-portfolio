"""【FEAT-463 (2026-06-22)】緊急メンテナンス状態取得 View。
【FEAT-471 (2026-07-02)】MaintenanceConfig 取得を cache 経由に変更。
"""
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from ..services.maintenance_cache import get_maintenance_config


class MaintenanceStatusView(APIView):
    """緊急メンテナンス状態を返す AllowAny endpoint。

    GET /api/maintenance/

    Mobile が起動時 / overlay の再試行ボタンタップ時に叩く。middleware で
    全 API レスポンス header `X-Maintenance: 1` も付与されるため実質二重防御だが、
    本 endpoint は「明示的に最新状態 (title/body/expires_at) を取得」する用途。

    Response:
        {
          "is_enabled": false,
          "title": "...",
          "body": "...",
          "expires_at": "2026-06-22T15:00:00Z" or null
        }
    """
    authentication_classes = []
    permission_classes = [AllowAny]

    def get(self, request):
        config = get_maintenance_config()
        if config is None or not config.is_enabled_now():
            return Response({
                'is_enabled': False,
                'title': '',
                'body': '',
                'expires_at': None,
            })
        return Response({
            'is_enabled': True,
            'title': config.title,
            'body': config.body,
            'expires_at': config.expires_at.isoformat() if config.expires_at else None,
        })
