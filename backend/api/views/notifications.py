from rest_framework import status
from ..authentication import ExpiringTokenAuthentication  # 【BUG-163】DRF 素の ExpiringTokenAuthentication は停止検査も期限も持たない
from rest_framework.response import Response
from rest_framework.views import APIView

from ..authentication import GuestTokenAuthentication  # 【FEAT-190】
from ..models import Notification
from ..permissions import IsAuthenticatedOrGuest  # 【FEAT-187】
from .mixins import PlayerMixin


class NotificationListView(PlayerMixin, APIView):
    """【FEAT-479 hotfix (2026-07-06)】ゲストモード表示対応。

    旧 `IsAuthenticated` (通常ユーザーのみ) → `IsAuthenticatedOrGuest` に変更。
    ゲストでも自身の PlayerProfile に紐付いた通知 (お知らせ / achievement /
    ログインボーナス等) を閲覧可能に。フレンド系通知は元々ゲスト経路で
    生成されないため、実質的にゲストは "アプリからの通知 (自分宛)" のみを
    見ることになる。
    """
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def get(self, request):
        player = self.get_player(request)

        try:
            offset = max(0, int(request.query_params.get('offset', 0)))
        except (ValueError, TypeError):
            offset = 0
        limit = 20

        qs    = Notification.objects.filter(player=player, is_read=False).order_by('-created_at')
        total = qs.count()
        notifs = qs[offset:offset + limit]

        data = [
            {
                'id':         n.id,
                'notif_type': n.notif_type,
                'title':      n.title,
                'body':       n.body,
                'related_id': n.related_id,
                'is_read':    n.is_read,
                'created_at': n.created_at.isoformat(),
            }
            for n in notifs
        ]
        return Response({
            'notifications': data,
            'total':         total,
            'offset':        offset,
            'has_more':      (offset + limit) < total,
        })

    def patch(self, request):
        player = self.get_player(request)
        Notification.objects.filter(player=player, is_read=False).update(is_read=True)
        return Response({'detail': 'ok'})


class NotificationReadView(PlayerMixin, APIView):
    """【FEAT-479 hotfix (2026-07-06)】ゲストモード表示対応 (NotificationListView 同措置)。"""
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def patch(self, request, pk):
        player = self.get_player(request)
        try:
            notif = Notification.objects.get(pk=pk, player=player)
        except Notification.DoesNotExist:
            return Response({'detail': 'not_found'}, status=status.HTTP_404_NOT_FOUND)
        notif.is_read = True
        notif.save(update_fields=['is_read'])
        return Response({'detail': 'ok'})
