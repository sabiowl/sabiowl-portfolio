"""【FEAT-493 (2026-07-25)】仮メモ CRUD + trash + 変換 API。

Quick Capture → Later Triage パターン。
kill-switch 付き default-ON 機能 (migration 0186 で default False → True 移行済)。
`PlayerProfile.free_memo_enabled` は「使わない人向けの非表示スイッチ」として
機能 (settings 画面から user が明示的に OFF にした場合のみ 403)。
実質、通常ユーザーは全員 True のため `free_memo_disabled` 403 は稀。

エンドポイント (2026-07-26 FEAT-500 で soft delete + trash 対応、
FEAT-502 で deleted_at semantic 分離、及び FEAT-475 error format 統一済):
  GET    /api/free-memos/                       # 通常一覧 (未削除、最大 200 件 + has_more + offset echo)
  GET    /api/free-memos/?archived=true          # trash 一覧 (削除済、offset pagination 対応)
                                                 #   ※ param 名 archived は後方互換で据置、内部 filter は deleted_at
  GET    /api/free-memos/?offset=N               # pagination (default 0、負値・非数値は 0 fallback)
  POST   /api/free-memos/                       # 新規作成 {text}
  PATCH  /api/free-memos/<id>/                  # 更新 {text}
  DELETE /api/free-memos/<id>/                  # 【FEAT-500 → FEAT-502】soft delete (deleted_at=now、trash 移動)
  POST   /api/free-memos/<id>/restore/          # 【FEAT-500 → FEAT-502】trash から復元 (deleted_at=null)
  DELETE /api/free-memos/<id>/purge/            # 【FEAT-500 → FEAT-502】完全削除 (hard、deleted_at IS NOT NULL 限定)
  POST   /api/free-memos/<id>/convert/          # 【FEAT-475 P3 #6 統合】body {to_type} でメモ削除 + EXP 付与
  POST   /api/free-memos/<id>/convert-to-event/ # 【互換 layer】旧 URL、Flutter 移行済むまで維持
  POST   /api/free-memos/<id>/convert-to-todo/  # 【互換 layer】同上
  POST   /api/free-memos/<id>/convert-to-habit/ # 【互換 layer】同上

変換 API: Flutter 側が既存の add_event_page / add_todo_page / add_habit_page で
アイテムを作成した後、本 API を呼んでメモを削除し EXP を受け取る設計。

【運用ルール (2026-07-26 codebase-functional-review §4 C-2 対応)】
本 module の endpoint 一覧を変更する FEAT では、
本 docstring の endpoint 表を必ず同じコミットで更新すること。個別修正では
3 日後にまた drift が出る (前回 memo_page.dart 冒頭コメント修正 → 翌日別
4 ファイルで再発の実測)。archived_at / deleted_at / free_memo_enabled 等の
field 意味を変える場合は models/free_memo.py の運用ルール ブロックも参照。

【FEAT-502 (2026-07-26)】user 削除 (soft delete / restore / purge / trash 一覧)
は全て deleted_at で判定する。archived_at は archive_old_memos cron 専用に温存。
"""
from django.db import transaction
from django.shortcuts import get_object_or_404
from django.utils import timezone
from ..authentication import ExpiringTokenAuthentication  # 【BUG-163】DRF 素の ExpiringTokenAuthentication は停止検査も期限も持たない
from rest_framework.response import Response
from rest_framework.views import APIView

from ..constants import GameBalance
from ..models import FreeMemo, PlayerProfile
from ._error_helpers import error_response
# 【2026-07-25 hotfix】ゲスト経路対応。Sabiowl は FEAT-188 で「ゲストでも実データで動作」
# の設計。calendar / battle / habits と同じ標準パターン (PlayerMixin +
# IsAuthenticatedOrGuest + GuestTokenAuthentication) に統一。
from ..authentication import GuestTokenAuthentication
from ..permissions import IsAuthenticatedOrGuest
from .mixins import PlayerMixin

# 変換時の少額 EXP 報酬 (「決意した瞬間」の報酬)
CONVERT_EXP_REWARD = 3

# 【2026-07-25 codebase-functional-review 20260725 対応 (P3 #7)】
# 一覧取得の上限。archive_old_memos の cron が Render Free tier で動作しないため
# (archive_old_memos.py docstring 参照)、ヘビーユーザーのメモは単調増加する。
# 200 件の上限で「無限肥大 → 明示的な打切り」に変える防波堤 (has_more で継続あり
# を Flutter に通知)。将来 archive cron が動くようになったら不要になる保険。
FREE_MEMO_LIST_LIMIT = 200


def _check_opt_in(player) -> bool:
    """free_memo_enabled フラグを確認する。"""
    return getattr(player, 'free_memo_enabled', False)


class FreeMemoOptInMixin:
    """【2026-07-26 レビュー §C8 対応】opt-in gate の DRY 化。

    旧: 各 view で個別に `_check_opt_in(player)` + `error_response(...)` を
        6 箇所ハードコード (DRY 違反、文言変更時に全 view 修正が必要)
    新: 本 mixin の `get_opted_in_player(request)` で 1 箇所に集約。

    使用パターン:
        class SomeView(FreeMemoOptInMixin, PlayerMixin, APIView):
            def post(self, request):
                player, err = self.get_opted_in_player(request)
                if err:
                    return err
                # ... player は opted-in が保証されている

    MRO 上、PlayerMixin (get_player 提供) の前に本 mixin を並べる必要あり。
    """

    def get_opted_in_player(self, request):
        """(player, error) tuple を返す。error is not None なら即 return 推奨。"""
        player = self.get_player(request)
        if not _check_opt_in(player):
            return None, error_response(
                code='free_memo_disabled',
                message='仮メモ機能はまだ有効になっていません。設定からお試しください 🪶',
                status=403,
            )
        return player, None


def _award_convert_exp(player) -> int:
    """変換時の EXP (CONVERT_EXP_REWARD) を付与し、level up を処理して実際の付与量を返す。

    タイムライン / 習慣経路と同じパターン:
    select_for_update → battle_state を直接更新 → save。
    日次スロットルは変換 EXP が少額 (3 EXP) のため適用しない設計 (仕様意図的)。
    """
    exp_gain = CONVERT_EXP_REWARD
    with transaction.atomic():
        locked = PlayerProfile.objects.select_for_update().get(pk=player.pk)
        battle_state = locked.battle
        battle_state.current_exp += exp_gain
        while battle_state.current_exp >= battle_state.max_exp:
            battle_state.current_exp -= battle_state.max_exp
            battle_state.level       += 1
            # 🔴 【FEAT-537 (2026-08-29)】この 1 行が丸ごと欠落しており、
            # 本経路だけ「レベルは上がったのに 0pt」が確定で起きていた。
            # `update_fields` にも入っていなかったので、加算だけ足しても
            # DB には入らない —— 2 箇所とも直す必要がある。
            battle_state.allocatable_points += GameBalance.ALLOCATABLE_POINTS_PER_LEVEL
            battle_state.max_exp      = GameBalance.level_to_max_exp(battle_state.level)
        battle_state.save(update_fields=[
            'current_exp', 'level', 'max_exp', 'allocatable_points',
        ])
    return exp_gain


class FreeMemoListCreateView(FreeMemoOptInMixin, PlayerMixin, APIView):
    """
    GET  /api/free-memos/             — 未 archived メモ一覧 (作成日時降順)
    GET  /api/free-memos/?archived=true — archived メモ一覧
    POST /api/free-memos/             — 新規作成 {text: str}
    """

    # 【2026-07-25 hotfix】ゲスト経路対応。
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def get(self, request):
        player, err = self.get_opted_in_player(request)
        if err:
            return err

        show_archived = request.query_params.get('archived') == 'true'
        # 【FEAT-498 §2.5 (2026-07-26)】pagination offset 対応。
        # ?offset=N (default 0) で N 件目以降を取得、has_more で継続あり通知。
        # Flutter 側の「もっと読み込む」button で offset を累積して追加取得する pattern。
        try:
            offset = max(0, int(request.query_params.get('offset', '0')))
        except (TypeError, ValueError):
            offset = 0

        # 【FEAT-502 (2026-07-26)】user 削除 (trash) は deleted_at で判定。
        # query param 名 ?archived=true は後方互換で据置 (Flutter 側も本 FEAT で
        # 同時更新、旧 param 使用の外部 caller は存在しない)。
        qs = FreeMemo.objects.filter(player=player)
        if show_archived:
            qs = qs.filter(deleted_at__isnull=False)
        else:
            qs = qs.filter(deleted_at__isnull=True)

        # 【P3 #7】上限 + has_more 判定。上限 +1 件取得して超過検出、実際に返すのは上限まで。
        # 【FEAT-498 §2.5】offset を start に指定して window slice。
        rows = list(qs[offset:offset + FREE_MEMO_LIST_LIMIT + 1])
        has_more = len(rows) > FREE_MEMO_LIST_LIMIT
        rows = rows[:FREE_MEMO_LIST_LIMIT]

        data = [
            {
                'id':         m.id,
                'text':       m.text,
                'created_at': m.created_at.isoformat(),
                'updated_at': m.updated_at.isoformat(),
                # 【FEAT-502】user 削除日時。Flutter model の deletedAt に対応。
                'deleted_at': m.deleted_at.isoformat() if m.deleted_at else None,
            }
            for m in rows
        ]
        return Response({
            'memos':    data,
            'count':    len(data),
            'has_more': has_more,
            'offset':   offset,  # 【FEAT-498 §2.5】echo (Flutter 側で次 offset 計算に使用)
        })

    def post(self, request):
        player, err = self.get_opted_in_player(request)
        if err:
            return err

        text = request.data.get('text', '')
        if not isinstance(text, str) or not text.strip():
            return error_response(
                code='free_memo_text_required',
                message='メモ本文を入力してください 🪶',
                fields={'text': '本文は必須です'},
                status=400,
            )
        if len(text) > 500:
            return error_response(
                code='free_memo_text_too_long',
                message='メモは 500 字以内で入力してください 🪶',
                fields={'text': '500 字以内で入力してください'},
                status=400,
            )

        memo = FreeMemo.objects.create(player=player, text=text.strip())
        return Response(
            {
                'id':         memo.id,
                'text':       memo.text,
                'created_at': memo.created_at.isoformat(),
                'updated_at': memo.updated_at.isoformat(),
                'deleted_at': None,
            },
            status=201,
        )


class FreeMemoDetailView(FreeMemoOptInMixin, PlayerMixin, APIView):
    """
    PATCH  /api/free-memos/<id>/  — テキスト更新 {text: str}
    DELETE /api/free-memos/<id>/  — ソフト削除 (deleted_at=now、trash に移動)

    【FEAT-500 (2026-07-26)】DELETE を hard → soft delete に変更。
    旧 hard delete は POST /free-memos/<id>/purge/ に分離 (完全削除)。
    削除メモの復元は POST /free-memos/<id>/restore/ (deleted_at=null)。
    Trash 一覧は既存の GET /free-memos/?archived=true で取得可能。
    【FEAT-502 (2026-07-26)】soft delete の格納先を archived_at → deleted_at に分離。
    """

    # 【2026-07-25 hotfix】ゲスト経路対応。
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def _get_memo(self, request, pk):
        """【レビュー §C8】opt-in check + memo 解決を集約。err 非 null なら即 return。"""
        player, err = self.get_opted_in_player(request)
        if err:
            return None, err
        # 【レビュー §C7 統一】get_object_or_404 の 404 も error_response format に統一
        memo, err = _resolve_memo_or_404(player, pk)
        return memo, err

    def patch(self, request, pk):
        memo, err = self._get_memo(request, pk)
        if err:
            return err

        text = request.data.get('text', '')
        if not isinstance(text, str) or not text.strip():
            return error_response(
                code='free_memo_text_required',
                message='メモ本文を入力してください 🪶',
                fields={'text': '本文は必須です'},
                status=400,
            )
        if len(text) > 500:
            return error_response(
                code='free_memo_text_too_long',
                message='メモは 500 字以内で入力してください 🪶',
                fields={'text': '500 字以内で入力してください'},
                status=400,
            )

        memo.text = text.strip()
        memo.save(update_fields=['text', 'updated_at'])
        return Response(
            {
                'id':         memo.id,
                'text':       memo.text,
                'created_at': memo.created_at.isoformat(),
                'updated_at': memo.updated_at.isoformat(),
                'deleted_at': memo.deleted_at.isoformat() if memo.deleted_at else None,
            }
        )

    def delete(self, request, pk):
        """【FEAT-500 → FEAT-502 (2026-07-26)】ソフト削除: deleted_at=now() で trash 移動。
        既に削除済の場合は冪等 (再削除で deleted_at 更新)。
        完全削除は別 endpoint (POST /purge/) で明示的に user 操作。
        """
        memo, err = self._get_memo(request, pk)
        if err:
            return err
        memo.deleted_at = timezone.now()
        memo.save(update_fields=['deleted_at'])
        return Response(status=204)


def _resolve_memo_or_404(player, pk: int):
    """【2026-07-26 レビュー §C7 対応】get_object_or_404 の Django 標準 404 を
    error_response format (FEAT-475) に統一するための helper。
    memo が player に紐付いていない or 存在しない場合は 404 error_response を返す。
    正常時は (memo, None) tuple、エラー時は (None, error_response) を返す。
    """
    try:
        memo = FreeMemo.objects.get(pk=pk, player=player)
        return memo, None
    except FreeMemo.DoesNotExist:
        return None, error_response(
            code='free_memo_not_found',
            message='対象のメモが見つかりませんでした 🪶',
            status=404,
        )


class FreeMemoRestoreView(FreeMemoOptInMixin, PlayerMixin, APIView):
    """POST /api/free-memos/<id>/restore/ — trash から復元 (deleted_at=null)

    【FEAT-500 → FEAT-502 (2026-07-26)】ソフト削除メモの復元。deleted_at を null に戻す。
    既に非削除の場合は冪等 (何もせず 200 で response)。
    【2026-07-26 レビュー §C7】error_response format 統一 (旧 get_object_or_404
    の Django 標準 404 → error_response 化)。
    """

    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def post(self, request, pk):
        player, err = self.get_opted_in_player(request)
        if err:
            return err
        memo, err = _resolve_memo_or_404(player, pk)
        if err:
            return err
        if memo.deleted_at is not None:
            memo.deleted_at = None
            memo.save(update_fields=['deleted_at'])
        return Response({
            'id':         memo.id,
            'text':       memo.text,
            'created_at': memo.created_at.isoformat(),
            'updated_at': memo.updated_at.isoformat(),
            'deleted_at': None,
        })


class FreeMemoPurgeView(FreeMemoOptInMixin, PlayerMixin, APIView):
    """DELETE /api/free-memos/<id>/purge/ — 完全削除 (hard delete、復元不可)

    【FEAT-500 (2026-07-26)】trash 画面からの明示的な完全削除。復元 endpoint
    (POST /restore/) の対極。user は「本当に削除しますか?」の確認 dialog を
    経てから本 endpoint を叩く前提 (Flutter 側で確保)。

    【2026-07-26 レビュー §C3 → FEAT-502】削除済メモ限定 hard delete に変更。
    active memo (deleted_at IS NULL) への purge は 400 拒否、必ず trash 経由
    (先に DELETE /free-memos/<id>/ で soft delete → その後 purge) を強制。
    API 契約の露出防御 (UI 経路では発生しないが、直接叩かれても防ぐ)。

    【2026-07-26 レビュー §C7】error_response format 統一。
    """

    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def delete(self, request, pk):
        player, err = self.get_opted_in_player(request)
        if err:
            return err
        memo, err = _resolve_memo_or_404(player, pk)
        if err:
            return err
        # 【レビュー §C3 → FEAT-502】active memo (未削除) は purge 不可 = trash 経由を強制
        if memo.deleted_at is None:
            return error_response(
                code='free_memo_not_archived',
                message='完全削除する前に、まず削除してゴミ箱に移してくださいね 🪶',
                status=400,
            )
        memo.delete()
        return Response(status=204)


class FreeMemoTrashPurgeAllView(FreeMemoOptInMixin, PlayerMixin, APIView):
    """DELETE /api/free-memos/trash/purge-all/ — trash 一括完全削除 (hard delete)

    【FEAT-498 §2.6 (2026-07-31)】trash に大量メモが溜まった時の「まとめて完全削除」
    action。1 件ずつ purge する摩擦を解消。Flutter 側は「N 件のメモを完全に削除
    します。この操作は取り消せません。」の BUG-138 準拠 confirm dialog を必ず
    経由してから叩く前提 (Pre-mortem S4「bulk purge の暴発」対策)。

    削除対象: 呼び出し player の deleted_at IS NOT NULL な全 FreeMemo。
    active memo (deleted_at IS NULL) は一切影響を受けない。冪等 (0 件でも 204 返却)。

    response: 204 No Content + `X-Purged-Count` header で削除件数を伝達
    (SnackBar 用、body 空維持で REST 慣習に整合)。
    """

    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def delete(self, request):
        player, err = self.get_opted_in_player(request)
        if err:
            return err
        # trash (deleted_at IS NOT NULL) の全 FreeMemo を hard delete。
        # queryset.delete() は 1 クエリで一括、大量件数でも O(1) round-trip。
        qs = FreeMemo.objects.filter(player=player, deleted_at__isnull=False)
        deleted_count, _ = qs.delete()
        response = Response(status=204)
        response['X-Purged-Count'] = str(deleted_count)
        return response


_CONVERT_TO_TYPES = ('event', 'todo', 'habit')


class FreeMemoConvertView(FreeMemoOptInMixin, PlayerMixin, APIView):
    """POST /api/free-memos/<id>/convert/  body {"to_type": "event"|"todo"|"habit"}

    【2026-07-25 codebase-functional-review 20260725 対応 (P3 #6)】旧 3 view
    (FreeMemoConvertToEventView / ...ToTodoView / ...ToHabitView) を統合。
    Flutter が既存の add_event_page / add_todo_page / add_habit_page でアイテムを
    保存した後に本エンドポイントを呼ぶ。メモを削除して EXP を付与し結果を返す。

    to_type 値は response の `converted_to` に echo されるが DB には保存しない
    (Sabiowl は「メモが何に化けたか」を DB 記録しない設計、PostHog
    `free_memo_converted` イベントの to_type プロパティが分析真実値)。
    将来 to_type を DB 保存したくなった時は、本 view の 1 箇所で FreeMemo に
    field 追加すれば済む (旧 3 view 時代の 3 箇所修正から解消)。

    後方互換: 旧 3 URL (`convert-to-event/` 等) も urls.py で本 view に link 済、
    to_type は URL から抽出する。Flutter 側は 20260729 review §3 C-2 対応で
    新 URL (`convert/` + body `{to_type}`) に移行済 (free_memo_service.dart:99)。
    旧 URL 互換 layer は既存 install user 対応で温存 (削除は v1.1+ で判断)。
    """

    # 【2026-07-25 hotfix】ゲスト経路対応。
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def post(self, request, pk, to_type: str | None = None):
        player, err = self.get_opted_in_player(request)
        if err:
            return err

        # to_type 解決: URL kwarg (旧 3 route の互換経路) → body の順で lookup
        resolved_type = to_type or (request.data or {}).get('to_type')
        if resolved_type not in _CONVERT_TO_TYPES:
            return error_response(
                code='free_memo_convert_invalid_type',
                message='変換先の種別が不正です 🪶',
                fields={'to_type': f'{_CONVERT_TO_TYPES} のいずれかを指定してください'},
                status=400,
            )

        # 【レビュー §C7】get_object_or_404 → error_response 統一
        memo, err = _resolve_memo_or_404(player, pk)
        if err:
            return err

        try:
            exp_gain = _award_convert_exp(player)
        except Exception:
            return error_response(
                code='free_memo_convert_failed',
                message='変換処理に失敗しました。少し時間をおいてお試しください 🪶',
                status=500,
            )

        memo.delete()

        return Response({
            'converted_to': resolved_type,
            'exp_gain':     exp_gain,
        })
