"""【FEAT-479 Phase 1 Step 2 (2026-07-06)】ジグソーパズル世界システム REST API view。

指示書: `doc/instructions/FEAT-479_puzzle_world_ver1.md` §3.4

## Endpoints

- `GET  /api/puzzle-world/`          — 現在のシーン状態 + アクティブ進捗 + 完成履歴
- `GET  /api/puzzle-world/scenes/`   — 全シーンの一覧 + 各 status
- `POST /api/puzzle-world/active/`   — body {scene_key} でアクティブシーン切替
- `POST /api/puzzle-world/displayed/` — body {scene_key: str or null} で額縁表示切替

## 認証

- ゲスト + 通常ユーザー両対応 (IsAuthenticatedOrGuest)
"""
from rest_framework import status
from rest_framework.authentication import TokenAuthentication
from rest_framework.response import Response
from rest_framework.views import APIView

from django.db import transaction
from django.utils import timezone

from ..authentication import GuestTokenAuthentication  # FEAT-190
from ..models import (
    PlayerProfile,
    PlayerPuzzleSceneProgress,
    PlayerPuzzleWorldHistory,
    PuzzleWorldScene,
)
from ..permissions import IsAuthenticatedOrGuest  # FEAT-187
from ..services.puzzle_world_service import (
    _ensure_active_scene_silently,
    _get_or_init_progress,
    select_active_scene,
    select_displayed_scene,
)
from ._error_helpers import error_response
from .mixins import PlayerMixin


# ─────────────────────────────────────────────────────────────────────────────
# Serializer 相当 (レスポンス構築ヘルパー、独立 serializer 不要な粒度)
# ─────────────────────────────────────────────────────────────────────────────


def _serialize_scene_basic(scene: PuzzleWorldScene) -> dict:
    return {
        'key':            scene.key,
        'name':           scene.name,
        'display_order':  scene.display_order,
        'piece_count':    scene.piece_count,
        'background_key': scene.background_key,
        'tagline':        scene.tagline,
    }


def _serialize_scene_with_status(
    scene: PuzzleWorldScene,
    progress: PlayerPuzzleSceneProgress | None,
    is_active: bool,
    is_displayed: bool,
) -> dict:
    """シーンごとの詳細レスポンス。progress あり = 着手済 / なし = 未着手。"""
    piece_states = progress.piece_states if progress else [0] * scene.piece_count
    owned = sum(1 for s in piece_states if s >= 1)
    colored = sum(1 for s in piece_states if s == 2)

    if progress is None:
        scene_status = 'unstarted'
    elif progress.completed_at is not None:
        scene_status = 'completed'
    elif is_active:
        scene_status = 'active'
    else:
        scene_status = 'in_progress'

    return {
        **_serialize_scene_basic(scene),
        'status':      scene_status,
        'is_active':   is_active,
        'is_displayed': is_displayed,
        'progress': {
            'owned':   owned,
            'colored': colored,
            'total':   scene.piece_count,
        },
    }


# ─────────────────────────────────────────────────────────────────────────────
# GET /api/puzzle-world/ — 現在の状態 (アクティブ + 進捗 + 完成履歴)
# ─────────────────────────────────────────────────────────────────────────────


class PuzzleWorldStatusView(PlayerMixin, APIView):
    """GET /api/puzzle-world/

    現在のプレイヤーのパズル世界状態を返す。
    - active_scene / displayed_scene
    - アクティブシーンの詳細 (piece_states + progress)
    - 完成履歴 (最新順)
    """
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def get(self, request):
        player = self.get_player(request)
        # 【FEAT-479 v1 hotfix (2026-07-07 pivot)】GET 時にも silent auto-activate
        # を発火。ユーザー要求「最初は全ユーザ『目覚めの山頂』を選ぶ仕様」を担保:
        #   - 新規ゲスト/正規ユーザー: 初回 GET で active_scene=morning_grassland
        #     (3 piece 目覚めの山頂) が自動 set され、ホーム WorldFrame も 3 分割
        #     overlay で正しく表示される。
        #   - 既存 active_scene 設定済ユーザー: no-op (副作用なし)。
        #
        # 旧挙動 (2026-07-06 hotfix) では最初のタスク達成が silent auto-activate
        # の唯一 trigger だったため、guest-init 直後の home 訪問で active_scene=null
        # が Mobile に返り、fallback 経路で「かけらがすべて揃った状態」に見える bug
        # が発生。GET 経路でも auto-activate を発火させることで構造的解消。
        #
        # transaction.atomic + select_for_update は _ensure_active_scene_silently
        # 側で必要になれば追加 (現時点では single-row UPDATE のみで race 実害無し、
        # 冪等性は if world.active_scene_id is not None: return world で担保)。
        world = _ensure_active_scene_silently(player)

        # アクティブシーン詳細 (未設定なら null)。
        # auto-activate 後は基本的に None にならないが、seed 未反映環境 (0175
        # 未適用等) では None が返る可能性があるため defensive に null 対応維持。
        active_detail: dict | None = None
        if world.active_scene_id is not None:
            active_progress = _get_or_init_progress(player, world.active_scene)
            active_detail = {
                **_serialize_scene_basic(world.active_scene),
                'piece_states': active_progress.piece_states,
                'is_completed': active_progress.completed_at is not None,
                'completed_at': (
                    active_progress.completed_at.isoformat()
                    if active_progress.completed_at else None
                ),
            }

        # ディスプレイド (null なら Mobile 側で auto fallback)
        displayed: dict | None = None
        if world.displayed_scene_id is not None:
            displayed = _serialize_scene_basic(world.displayed_scene)

        # 完成履歴 (最新順、最大 10 件)
        histories = (
            PlayerPuzzleWorldHistory.objects.filter(player=player)
            .select_related('scene')
            .order_by('-completed_at')[:10]
        )
        history_list = [
            {
                'scene_key':              h.scene.key,
                'scene_name':             h.scene.name,
                'completed_at':           h.completed_at.isoformat(),
                'reward_exp_gained':      h.reward_exp_gained,
                'reward_diamonds_gained': h.reward_diamonds_gained,
            }
            for h in histories
        ]

        return Response({
            'active_scene':    active_detail,
            'displayed_scene': displayed,
            'history':         history_list,
        })


# ─────────────────────────────────────────────────────────────────────────────
# GET /api/puzzle-world/scenes/ — 全シーンの一覧
# ─────────────────────────────────────────────────────────────────────────────


class PuzzleWorldSceneListView(PlayerMixin, APIView):
    """GET /api/puzzle-world/scenes/

    全 3 シーンをレスポンス。各シーンに progress + status を含める。
    Mobile 側の SceneSelectionPage で使用。

    【FEAT-479 v1 (2026-07-07)】is_tutorial=True (first_light 等、3 ピース成功体験用
    シーン) は SceneSelectionPage から除外。silent auto-activate 経路でのみ user に
    出現し、選択画面には出さない = 「選ぶ選択肢を増やさず、静かに始まる」体験。
    """
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def get(self, request):
        player = self.get_player(request)
        # 【FEAT-479 v1 hotfix (2026-07-07 pivot)】SceneSelectionPage 経由でも
        # silent auto-activate を発火。SceneSelectionPage から初回 GET する経路
        # でも「morning_grassland が active_scene として自動選択済」状態を
        # 担保することで、UI 表示 (isActive バッジ + 選択済表示) の一貫性を保つ。
        world = _ensure_active_scene_silently(player)

        # 全シーン (is_active=True かつ非チュートリアルのみ)
        scenes = PuzzleWorldScene.objects.filter(
            is_active=True, is_tutorial=False,
        ).order_by('display_order', 'id')

        # progress の一括取得 (N+1 回避)
        progress_map = {
            p.scene_id: p
            for p in PlayerPuzzleSceneProgress.objects.filter(
                player=player, scene__in=scenes,
            )
        }

        result = []
        for s in scenes:
            result.append(_serialize_scene_with_status(
                scene=s,
                progress=progress_map.get(s.id),
                is_active=(world.active_scene_id == s.id),
                is_displayed=(world.displayed_scene_id == s.id),
            ))

        return Response({'scenes': result})


# ─────────────────────────────────────────────────────────────────────────────
# POST /api/puzzle-world/active/ — アクティブシーン切替
# ─────────────────────────────────────────────────────────────────────────────


class PuzzleWorldActiveSelectView(PlayerMixin, APIView):
    """POST /api/puzzle-world/active/

    body: {scene_key: str}

    - 無料・無制限 (Sabi「聖域」原則)
    - 対象は is_active=True かつ未完成のシーンのみ
    """
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def post(self, request):
        scene_key = request.data.get('scene_key')
        if not scene_key:
            return error_response(
                code='puzzle_active_missing_key',
                message='シーンキーが指定されていません 🪶',
                status=400,
            )

        try:
            scene = PuzzleWorldScene.objects.get(key=scene_key)
        except PuzzleWorldScene.DoesNotExist:
            return error_response(
                code='puzzle_active_scene_not_found',
                message='シーンが見つかりませんでした 🪶',
                status=404,
            )

        with transaction.atomic():
            player = PlayerProfile.objects.select_for_update().get(
                pk=self.get_player(request).pk,
            )
            try:
                select_active_scene(player, scene)
            except ValueError as e:
                if str(e) == 'scene_already_completed':
                    return error_response(
                        code='puzzle_active_scene_already_completed',
                        message='もう命が宿った景色です。 別のところに手を伸ばしてみましょうか 🪶',
                        status=400,
                    )
                return error_response(
                    code='puzzle_active_scene_not_selectable',
                    message='このシーンは選べません 🪶',
                    status=400,
                    fields={'scene_key': str(e)},
                )

        return Response({
            'detail':       '向き合う景色を、こちらに切り替えました 🪶',
            'active_scene': _serialize_scene_basic(scene),
        })


# ─────────────────────────────────────────────────────────────────────────────
# POST /api/puzzle-world/displayed/ — ワールドフレーム表示シーン切替
# ─────────────────────────────────────────────────────────────────────────────


class PuzzleWorldDisplayedSelectView(PlayerMixin, APIView):
    """POST /api/puzzle-world/displayed/

    body: {scene_key: str | null}

    - scene_key=null → 自動 fallback (active → 静止画)
    - scene_key 指定 → アクティブシーン or 完成済シーンのみ
    """
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def post(self, request):
        scene_key = request.data.get('scene_key')  # None も許容

        scene: PuzzleWorldScene | None = None
        if scene_key is not None:
            try:
                scene = PuzzleWorldScene.objects.get(key=scene_key)
            except PuzzleWorldScene.DoesNotExist:
                return error_response(
                    code='puzzle_displayed_scene_not_found',
                    message='シーンが見つかりませんでした 🪶',
                    status=404,
                )

        with transaction.atomic():
            player = PlayerProfile.objects.select_for_update().get(
                pk=self.get_player(request).pk,
            )
            try:
                select_displayed_scene(player, scene)
            except ValueError:
                return error_response(
                    code='puzzle_displayed_scene_not_available',
                    message='まだ一枚も集めていない景色です。 まずは救う対象に選んでみてください 🪶',
                    status=400,
                    fields={'scene_key': 'not_started'},
                )

        return Response({
            'detail': (
                '額縁の風景を、入れ替えました 🪶'
                if scene else '額縁の風景を、時間帯にお任せしました 🪶'
            ),
            'displayed_scene': _serialize_scene_basic(scene) if scene else None,
        })
