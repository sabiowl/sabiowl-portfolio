"""【FEAT-290】calendar.py 分割: Google Calendar 連携 view モジュール。

旧 `backend/api/views/calendar.py` (1110 LOC, 10 View 同居) を機能別に
3 モジュールへ分割した内の 1 つ。本ファイルは「外部カレンダー (Google /
Apple) の同期」を担う 2 view を集約:
    - ExternalCalendarImportView  Google/Apple イベント取り込み + 重複防止
    - GoogleCalendarUnsyncView    取り込み済 Google イベントの一括解除

import 互換性は親パッケージ `backend/api/views/calendar/__init__.py` の
re-export 経路で 100% 維持されており、`from api.views import calendar`
配下の旧 import パターンは無改修で動作する。

【FEAT-426 (2026-06-11)】設計 Y (ハイブリッド) 採用に伴い、本ファイルの 2 view は
廃止 (410 Gone) した。Google カレンダーの予定本文は Mobile ローカル DB
(`LocalGoogleEventStore`) のみに保存され、Backend には完了状態のみを
`GoogleEventCompletion` (→ `views/calendar/google_completion.py`) で保持する。

関連: FEAT-244 / FEAT-253 / FEAT-255 / FEAT-256 / FEAT-263 (旧双方向同期系、廃止)。
"""
from rest_framework import status
from rest_framework.authentication import TokenAuthentication
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from ...authentication import GuestTokenAuthentication  # FEAT-190
from ...permissions import IsAuthenticatedOrGuest  # FEAT-187


_DEPRECATED_RESPONSE = {
    'detail': 'use_local_storage',
    'message': 'Google カレンダー連携は端末内保存に切り替わりました 🪶',
}


class ExternalCalendarImportView(APIView):
    """
    POST /api/calendar/import/

    【FEAT-426 (2026-06-11)】廃止。Google/Apple イベントの取り込みは Mobile
    ローカル DB (`LocalGoogleEventStore`) で完結するため、本エンドポイントは
    410 Gone を返す。
    """
    authentication_classes = [TokenAuthentication]
    permission_classes     = [IsAuthenticated]

    def post(self, request):
        return Response(_DEPRECATED_RESPONSE, status=status.HTTP_410_GONE)


class GoogleCalendarUnsyncView(APIView):
    """【FEAT-212】Google カレンダー同期解除。

    DELETE /api/calendar/import/google/

    【FEAT-426 (2026-06-11)】廃止。Backend に Google 予定本文を保持しなく
    なったため、本エンドポイントは 410 Gone を返す。
    """
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def delete(self, request):
        return Response(_DEPRECATED_RESPONSE, status=status.HTTP_410_GONE)
