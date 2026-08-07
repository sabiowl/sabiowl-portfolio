"""【FEAT-467 (2026-07-02)】タスク候補一覧 View。

タスク登録画面 (予定 / ToDo / 習慣) のタイトル入力 popup に
Backend 管理の候補リストを返す。
ゲスト・正規ユーザー両方が利用可能 (IsAuthenticatedOrGuest)。
"""
from rest_framework.response import Response
from rest_framework.views import APIView

from ..models import TaskSuggestion
from ..permissions import IsAuthenticatedOrGuest  # FEAT-187
from ..serializers import TaskSuggestionSerializer
from ._error_helpers import error_response  # 【FEAT-515】


class TaskSuggestionListView(APIView):
    """GET /api/task-suggestions/?type=<event|todo|habit>

    type パラメータが有効値 (event / todo / habit) でなければ 400 を返す。
    is_active=True の候補のみを order 順で返す。
    """

    permission_classes = [IsAuthenticatedOrGuest]

    VALID_TYPES = {'event', 'todo', 'habit'}

    def get(self, request):
        type_ = request.query_params.get('type', '')
        if type_ not in self.VALID_TYPES:
            return error_response(
                       code='task_suggestion_invalid_type',
                       message=f"'type' は event / todo / habit のいずれかを指定してください。",
                       status=400,
                   )
        qs = (
            TaskSuggestion.objects
            .filter(type=type_, is_active=True)
            .order_by('order', 'id')
        )
        return Response(TaskSuggestionSerializer(qs, many=True, context={"request": request}).data)
