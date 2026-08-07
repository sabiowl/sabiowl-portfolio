"""【FEAT-511 Phase A (v1.1、2026-07-30)】ジョブ熟練度 List API。

エンドポイント: `GET /api/player/job_masteries/`
認証: TokenAuthentication / GuestTokenAuthentication (バトルと同等)
"""
from rest_framework.authentication import TokenAuthentication
from rest_framework.response import Response
from rest_framework.views import APIView

from ..authentication import GuestTokenAuthentication
from ..constants import JOB_MASTERY_MAX_LEVEL, calc_job_mastery_exp_to_next
from ..models import PlayerJobMastery
from ..permissions import IsAuthenticatedOrGuest
from .mixins import PlayerMixin


class JobMasteryListView(PlayerMixin, APIView):
    """`GET /api/player/job_masteries/`

    プレイヤーのジョブ別熟練度を全件返す (最大 13 件)。
    バトル未経験ジョブのレコードは存在しないため、その場合は空配列を返す。
    """
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        player = self.get_player(request)
        masteries = (
            PlayerJobMastery.objects
            .select_related('job')
            .filter(player=player)
            .order_by('job__id')
        )
        return Response({
            'masteries': [
                {
                    'job_id':    m.job.job_id,  # string key (e.g. 'warrior'), not PK
                    'job_name':  m.job.job_name,
                    'level':     m.level,
                    'exp':       m.exp,
                    'exp_to_next': (calc_job_mastery_exp_to_next(m.level)
                                    if m.level < JOB_MASTERY_MAX_LEVEL else 0),
                    'is_maxed':  m.is_maxed,
                }
                for m in masteries
            ],
        })
