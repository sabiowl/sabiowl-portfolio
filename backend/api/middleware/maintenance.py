"""【FEAT-463 (2026-06-22)】緊急メンテナンスモードの配信用 middleware。

全 API レスポンスに `X-Maintenance: 1` header を付与し、Mobile の Dio
interceptor が検知して maintenance overlay を表示する。

【FEAT-471 (2026-07-02)】毎リクエスト MaintenanceConfig SELECT を cache 経由に変更。
1,000 ユーザー × 100 API call/日 = 10 万 SELECT/日 → 60 秒 TTL cache で大幅削減。
"""
import os

from django.conf import settings
from django.utils.deprecation import MiddlewareMixin

from ..services.maintenance_cache import get_maintenance_config

# config/urls.py と同じ ADMIN_URL 環境変数を参照する (Render で予測困難なパスに
# 変更されている場合でも bypass が機能するように、ハードコード '/admin/' にしない)。
_ADMIN_PATH_PREFIX = '/' + os.environ.get('ADMIN_URL', 'admin/')


class MaintenanceMiddleware(MiddlewareMixin):
    """全 API レスポンスに maintenance status を header で通知する middleware。

    判定:
        - DEBUG=True なら常に bypass (開発時は影響なし)
        - request.path が /admin/ で始まるなら bypass (admin が止まらないようにする)
        - 上記以外で MaintenanceConfig.is_enabled_now() == True なら header 付与

    Header:
        X-Maintenance: 1   (有効時のみ付与、無効時は付与しない)

    【Pre-mortem S1】DB 障害発生時に全リクエストが 500 化するのを防ぐため、
    DB アクセスは try/except Exception で wrap する (defense-in-depth)。
    DB 障害時は header を付与しない = 通常レスポンス扱いになる。
    """

    def process_response(self, request, response):
        if settings.DEBUG:
            return response
        if request.path.startswith(_ADMIN_PATH_PREFIX):
            return response

        try:
            config = get_maintenance_config()
            if config and config.is_enabled_now():
                response['X-Maintenance'] = '1'
        except Exception:
            # DB 障害 / cache 障害時は header 付与しない (= 通常通り扱い、defense-in-depth)
            pass
        return response
