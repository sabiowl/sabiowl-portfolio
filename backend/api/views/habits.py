import calendar as _cal
import logging
from collections import defaultdict
from datetime import timedelta

from rest_framework import status
from ..authentication import ExpiringTokenAuthentication  # 【BUG-163】DRF 素の ExpiringTokenAuthentication は停止検査も期限も持たない
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView

from ..authentication import GuestTokenAuthentication  # FEAT-190
from ..constants import GameBalance  # 【FEAT-285】経路別 allocatable points + adventure rate
from ..permissions import IsAuthenticatedOrGuest  # FEAT-187

from django.db import transaction
from django.db.models import Case, Count, F, IntegerField, Q, Sum, Value, When
from django.db.models import Prefetch
from django.db.models.functions import Greatest
from django.utils import timezone

from ..models import CharacterStat, ChecklistItem, Habit, HabitLog, HabitRewardLog, PlayerProfile, RestDay
from ..serializers import HabitSerializer, PlayerProfileSerializer
from ..services.diamond_service import award_diamond_for_streak_7days  # 【FEAT-314】
from ..services.exp_service import (
    EXP_PER_COUNT, GOLD_PER_COUNT, _CATEGORY_STAT_MAP,
    calc_exp_gain, award_diamond_if_first_today,
    # 【FEAT-213】分散マッピング対応の新ヘルパー
    get_stat_allocations, calc_stat_bonus_exp,
)
from ..services.push_service import create_localized_notification  # 【FEAT-517】
from ._error_helpers import error_response  # 【FEAT-475 Phase 3c】新形式統一
from .mixins import PlayerMixin
# FEAT-139: REST_DAY_WEEKLY_LIMIT 廃止・_week_range 不要のためインポート削除

_logger = logging.getLogger(__name__)


def _check_achievements(player):
    """実績チェックを achievements モジュールから呼び出す（循環インポート回避）"""
    from .achievements import check_achievements
    return check_achievements(player)


def _check_achievements_by_pk(player_pk: int):
    """transaction.on_commit 用: pk から player を再取得して実績チェック。"""
    try:
        player = PlayerProfile.objects.get(pk=player_pk)
        _check_achievements(player)
    except PlayerProfile.DoesNotExist:
        pass


def _auto_allocate_by_ratio(player) -> tuple[dict, dict]:
    """
    直近 30 日の習慣達成比率を計算し、10pt を比例配分して各 stat へ付与する。
    既存の transaction.atomic() ブロック内から呼ぶこと（select_for_update 使用）。

    【FEAT-213】カテゴリ → 6 ステータス分散マッピング対応。
    【FEAT-379 (2026-05-29)】ステータス Lv UP 時に結晶 +1 を加算する。
    `_award_crystal_on_stat_level_up` は player (select_for_update 済) に対して直接実行。

    Returns:
        tuple:
          - {stat_name: pts} の辞書（合計 ≒ 10pt）
          - {crystal_key: count} の辞書（今回付与した結晶数、例: {'exercise': 1}）
    """
    today = timezone.now().date()
    since = today - timedelta(days=29)  # 30 日間（today 含む）

    # P0-3: N+1 を 2 クエリに集約（旧: 習慣数 × 1 クエリ）
    # カテゴリ別達成日数を 1 クエリで取得
    achieved_by_cat = dict(
        HabitLog.objects
        .filter(
            habit__player=player, habit__is_active=True,
            habit__category__in=_CATEGORY_STAT_MAP.keys(),
            date__range=(since, today), count__gt=0,
        )
        .values('habit__category')
        .annotate(c=Count('id'))
        .values_list('habit__category', 'c')
    )
    # カテゴリ別習慣数を 1 クエリで取得（期待値 = 習慣数 × 30 日）
    count_by_cat = dict(
        Habit.objects
        .filter(player=player, is_active=True, category__in=_CATEGORY_STAT_MAP.keys())
        .values('category')
        .annotate(n=Count('id'))
        .values_list('category', 'n')
    )

    # カテゴリ別達成率（達成 0 のカテゴリは除外）
    rates = {
        cat: achieved_by_cat[cat] / (count_by_cat[cat] * 30)
        for cat in count_by_cat
        if cat in achieved_by_cat and achieved_by_cat[cat] > 0
    }

    if not rates:
        return {}, {}

    # 10pt を達成率に比例配分（切り捨て後、余りは最高率カテゴリへ）
    total_rate = sum(rates.values())
    allocated = {cat: int((rate / total_rate) * 10) for cat, rate in rates.items()}
    remainder = 10 - sum(allocated.values())
    if remainder > 0:
        top_cat = max(rates, key=rates.get)
        allocated[top_cat] = allocated.get(top_cat, 0) + remainder

    # 【FEAT-213】Step 1: カテゴリ ptを 6 ステータスに分散して集約
    # 1pt = 10 EXP、分散マッピングで複数 stat に按分。同じ stat に複数カテゴリから
    # 流れ込んだら合算する。
    exp_per_stat: dict[str, int] = {}
    pts_per_stat: dict[str, int] = {}  # 戻り値用（pt 単位での加算量）
    for cat, pts in allocated.items():
        if pts <= 0:
            continue
        exp_for_cat = 10 * pts
        for stat_name, allocated_exp in get_stat_allocations(cat, exp_for_cat):
            if allocated_exp <= 0:
                continue
            exp_per_stat[stat_name] = exp_per_stat.get(stat_name, 0) + allocated_exp
            # pt 換算（戻り値の意味論を維持）
            pts_per_stat[stat_name] = pts_per_stat.get(stat_name, 0) + round(allocated_exp / 10)

    if not exp_per_stat:
        return {}, {}

    # 【FEAT-213】Step 2: 関連する CharacterStat を **pk 昇順で select_for_update**
    # でロックして取得（デッドロック回避）
    locked_stats = list(
        CharacterStat.objects
        .select_for_update()
        .filter(player=player, name__in=exp_per_stat.keys())
        .order_by('pk')
    )
    stats_by_name = {s.name: s for s in locked_stats}

    # Step 3: EXP 加算 + レベルアップ判定
    # 【FEAT-379】結晶付与フックをインポート (循環回避: lazy import は使わず直接)
    # 【2026-07-09 レビュー §5 P3】max_exp *= 1.2 の直書きを撲滅、共有 helper 経由に統一。
    from ..services.exp_service import _award_crystal_on_stat_level_up, apply_stat_level_up_step

    result: dict = {}
    crystals_awarded: dict = {}  # 【FEAT-379】今回付与した結晶 {crystal_key: count}

    for stat_name, exp_add in exp_per_stat.items():
        stat = stats_by_name.get(stat_name)
        if stat is None:
            continue
        stat.current_exp += exp_add
        while stat.current_exp >= stat.max_exp:
            # 【2026-07-09 レビュー §5 P3】level +1 / current_exp -= max_exp / max_exp *= 1.2
            # は共有 helper に集約 (真実値は exp_service.STAT_LEVEL_UP_MULTIPLIER)。
            apply_stat_level_up_step(stat)
            # 【FEAT-379 Pre-mortem #1】既存経路への回帰ゼロを確認済
            # (test_stat_balance_boundary.py + test_character_stat_level_up_contract.py)。
            crystal_key = _award_crystal_on_stat_level_up(stat, player)
            if crystal_key:
                crystals_awarded[crystal_key] = crystals_awarded.get(crystal_key, 0) + 1
        stat.save(update_fields=['level', 'current_exp', 'max_exp'])
        result[stat_name] = pts_per_stat.get(stat_name, 0)

    return result, crystals_awarded


class HabitListCreateView(PlayerMixin, APIView):
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        player = self.get_player(request)
        today  = timezone.localdate()

        # 前日以前に完了済みの ToDo の pk を除外（今日完了は表示する）
        completed_todo_pks = (
            HabitLog.objects
            .filter(
                habit__player=player,
                habit__is_active=True,
                habit__habit_type='todo',
                count__gte=1,
            )
            .exclude(date=today)
            .values_list('habit_id', flat=True)
            .distinct()
        )

        # P0-4: デフォルトは直近 90 日。?period=year のみ年初から（yearly reset_cycle 用）
        #
        # 【FEAT-520 §4.4】`reset_cycle='yearly'` の習慣を 1 件でも持つ場合は
        # クエリパラメータに関係なく年初まで窓を広げる。
        #
        # `?period=year` という経路は用意されていたが **Flutter は一度も送っていない**
        # (grep 実測)。そのまま `period_count` を実装すると 1〜9 月の回数が黙って
        # 欠落する。日数表示なら違和感が薄いが、回数合計は桁が変わるため
        # ユーザーから見て明確な誤りになる。weekly / monthly は 90 日窓に収まる。
        period = request.query_params.get('period', '90d')
        has_yearly = Habit.objects.filter(
            player=player, is_active=True, reset_cycle='yearly',
        ).exists()
        if period == 'year' or has_yearly:
            range_start = today.replace(month=1, day=1)
        else:
            range_start = today - timedelta(days=89)  # 90 日分（today 含む）

        # 【FEAT-474】cursor pagination: ?cursor=<order>:<id>&limit=50
        cursor_raw = request.query_params.get('cursor', '')
        try:
            limit = min(int(request.query_params.get('limit', 50)), 100)
        except (ValueError, TypeError):
            limit = 50

        qs = (
            Habit.objects
            .filter(player=player, is_active=True)
            .exclude(pk__in=completed_todo_pks)
            .order_by('order', 'id')
            .prefetch_related(
                Prefetch(
                    'logs',
                    queryset=HabitLog.objects.filter(
                        date__gte=range_start,
                    ).order_by('date'),
                    to_attr='_year_logs',
                ),
                'checklist_items',
            )
        )

        if cursor_raw:
            try:
                cursor_order_str, cursor_id_str = cursor_raw.split(':')
                cursor_order = int(cursor_order_str)
                cursor_id    = int(cursor_id_str)
                qs = qs.filter(
                    Q(order__gt=cursor_order)
                    | (Q(order=cursor_order) & Q(id__gt=cursor_id))
                )
            except (ValueError, TypeError):
                return error_response(code='habits_list_invalid_cursor', message='ページ位置が正しくないようです。最初から表示しますね 🪶')

        rows = list(qs[:limit + 1])
        has_more  = len(rows) > limit
        results   = rows[:limit]
        next_cursor = ''
        if has_more:
            last = results[-1]
            next_cursor = f'{last.order}:{last.id}'

        return Response({
            'results':     HabitSerializer(results, many=True).data,
            'next_cursor': next_cursor,
            'has_more':    has_more,
        })

    def post(self, request):
        player = self.get_player(request)
        today  = timezone.localdate()

        new_name = (request.data.get('name') or '').strip()
        checklist_items_data = request.data.get('checklist_items', [])

        # P1-06: 同名 active 習慣の重複作成（TOCTOU レース）防止。
        # `exists()` チェックと `serializer.save()` を同一トランザクションに包み、
        # PlayerProfile を rendezvous 行として select_for_update で軽くロックする。
        # 加えて model 側にも UniqueConstraint を付けてあるので DB レベルでも防御。
        #
        # 【ユーザー要望 2026-06-22】ToDo (habit_type='todo') は ID で個別管理される
        # 1 回限りタスクであり、同名作成を許可する (例: 「買い物」を複数日登録)。
        # 完了済み ToDo も Habit.is_active=True のまま残るため、`is_active=True` 単独
        # フィルタでは完了済 ToDo と同名作成もブロックされていた。本 View 層
        # チェックでも `.exclude(habit_type='todo')` で ToDo を対象外にする。
        # DB 層の UniqueConstraint (migration 0155) と同じ condition で揃える。
        with transaction.atomic():
            PlayerProfile.objects.select_for_update().get(pk=player.pk)

            if new_name and Habit.objects.filter(
                player=player, name=new_name, is_active=True,
            ).exclude(habit_type='todo').exists():
                return error_response(
                    code='habit_create_duplicate_name',
                    message='この名前の習慣はすでに登録されています 🪶',
                    fields={'name': '別の名前を指定してください'},
                    status=status.HTTP_400_BAD_REQUEST,
                )

            # 【FEAT-434 (2026-06-14)】Habit (count/checklist) の Legendary 難易度は廃止。
            # calc_legendary_slots は常に 0 を返すため、本チェックは
            # habit_type != 'todo' かつ difficulty == 'legendary' のリクエストを
            # 構造的に常時拒否する (= Legendary 不可)。ToDo は habit_type='todo'
            # 分岐 (下記) で difficulty を 'normal' に強制するため、本チェック対象外。
            # Pre-mortem #1: select_for_update 内でカウント → TOCTOU race を構造的に遮断。
            if (request.data.get('difficulty') == 'legendary'
                    and request.data.get('habit_type') != 'todo'):
                from ..services.habit_slot_service import (
                    calc_legendary_slots,
                    count_active_legendary,
                )
                slots_total = calc_legendary_slots(player)
                slots_used  = count_active_legendary(player)
                if slots_used >= slots_total:
                    next_unlock_lv = (slots_total) * 5
                    return error_response(
                               code='habit_create_legendary_slots_exhausted',
                               message=f'伝説の習慣はあと {max(0, slots_total - slots_used)} 個までですね。'
                                f'すべてのステータスが Lv.{next_unlock_lv} を超えると、'
                                f'もう一つ枠が開きますよ 🪶',
                               status=status.HTTP_400_BAD_REQUEST,
                               extra={'legendary_slots_total': slots_total, 'legendary_slots_used': slots_used},
                           )

            max_order = Habit.objects.filter(player=player).order_by('-order').values_list(
                'order', flat=True
            ).first()
            next_order = (max_order + 1) if max_order is not None else 0

            data = {k: v for k, v in request.data.items() if k != 'checklist_items'}
            data['order'] = next_order

            # ── ToDo のデフォルト値を強制 ─────────────────────────────────────────
            if data.get('habit_type') == 'todo':
                data['difficulty']  = 'normal'      # EXP 30pt 固定（Normal × 基礎20 = 30）
                data['frequency']   = 'daily'
                data['reset_cycle'] = 'daily'
                if not data.get('due_date'):
                    data['due_date'] = str(today)   # デフォルトは作成日

            if 'reset_cycle' not in data or not data.get('reset_cycle'):
                data['reset_cycle'] = data.get('frequency', 'daily')

            serializer = HabitSerializer(data=data)
            if not serializer.is_valid():
                return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

            habit = serializer.save(player=player, order=next_order)

            if habit.habit_type == 'checklist' and isinstance(checklist_items_data, list):
                for idx, item in enumerate(checklist_items_data):
                    text = item.get('text', '') if isinstance(item, dict) else str(item)
                    if text.strip():
                        ChecklistItem.objects.create(habit=habit, text=text.strip(), order=idx)

        return Response(HabitSerializer(habit).data, status=status.HTTP_201_CREATED)


class HabitSummaryView(PlayerMixin, APIView):
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        player = self.get_player(request)
        today  = timezone.localdate()
        active_habits = Habit.objects.filter(player=player, is_active=True)
        total  = active_habits.count()

        today_completed = HabitLog.objects.filter(
            habit__in=active_habits, date=today, count__gte=1,
        ).count()

        total_exp_today = (
            HabitLog.objects
            .filter(habit__in=active_habits, date=today)
            .aggregate(total=Sum('exp_gained'))['total'] or 0
        )

        current_streak = (
            active_habits.order_by('-streak').values_list('streak', flat=True).first() or 0
        )

        # P0-7: 7 日ループ（7 クエリ）→ 1 クエリに集約
        week_rate = 0
        if total > 0:
            week_start = today - timedelta(days=6)
            done_by_date = {
                r['date']: r['c']
                for r in HabitLog.objects
                .filter(habit__in=active_habits, date__range=(week_start, today), count__gte=1)
                .values('date')
                .annotate(c=Count('id'))
            }
            daily_rates = [
                done_by_date.get(today - timedelta(days=i), 0) / total
                for i in range(7)
            ]
            week_rate = int(sum(daily_rates) / 7 * 100)

        return Response({
            'today_completed': today_completed,
            'today_total':     total,
            'week_rate':       week_rate,
            'current_streak':  current_streak,
            'total_exp_today': total_exp_today,
        })


# ─────────────────────────────────────────────────────────────────────────────
# 【FEAT-525 (2026-08-21)】チェックリスト項目の宣言的更新
# ─────────────────────────────────────────────────────────────────────────────
#
# `set_checklist_items` は「いまの完全なリストを順序どおりに送る」形式で、
# **追加・削除・並び替えを 1 往復で表現する**。
#
#     id あり          → 残す。text を更新し、order = 配列の index
#     id なし          → 新規作成。order = 配列の index
#     配列に現れない id → 削除
#
# ## なぜ add / delete / reorder の 3 本立てにしないのか
#
# 編集画面は「既存項目 (id 付き)」と「新規追加分 (id 未確定)」を **同じリストとして**
# 表示する。ユーザーは両者を区別せず混ぜて並べ替えるので、3 本立てにすると
# 「新規項目を id が決まる前に順序へ混ぜる」問題が残り、**追加 → 採番 → 並び替えの
# 2 往復** か、**text で新規項目を突き合わせる** かになる。後者は同じ文言の項目が
# 2 つあると壊れる。宣言的な 1 本ならどちらも要らない。冪等でもある。
#
# ## 🔴 旧 2 フィールドは残すこと
#
# v1.0.5 が公開中、1.1.0+6 が審査中で、**どちらも `add_checklist_items` /
# `delete_checklist_items` を送る**。消すと既存ユーザーの項目追加・削除が壊れる。
# `set_` への一本化は旧バージョンが十分に入れ替わってから別 FEAT で行う。
# 両方が同時に来たら 400 (意味が競合するので黙ってどちらかを優先しない)。

# ChecklistItem.text の max_length。超過は Postgres では DataError = 500 になるので
# ここで 400 に落とす (SQLite だと黙って通るため、ローカルでは再現しない)。
_CHECKLIST_TEXT_MAX_LENGTH = 200


class _ChecklistPayloadError(Exception):
    """`set_checklist_items` のバリデーション失敗を 400 レスポンスに変換する。

    view から深い位置 (正規化 / 適用) で発生するので、戻り値で運ばず例外にする。
    受け側は `patch()` の `except` で、統一形式の helper を使って 400 を返す。
    (docstring に `error_response` を**呼び出しの形で書かない**こと ——
    `test_error_response_format.py` はソースを正規表現で走査するので、
    コメント内の呼び出し形が誤検出になる。)
    `transaction.atomic()` の中で送出されるとロールバックされるため、
    **習慣本体の更新だけが適用された中途半端な状態にはならない**。
    """

    def __init__(self, code: str, message: str):
        super().__init__(code)
        self.code = code
        self.message = message


def _normalize_set_checklist_items(raw) -> list[dict]:
    """`set_checklist_items` を `[{'id': int|None, 'text': str}, ...]` に正規化する。

    - list でなければ 400
    - 要素は `{'text': ...}` / `{'id': ..., 'text': ...}` の dict、
      または文字列 (= text のみの新規項目。`POST /habits/` の `checklist_items` と同じ受け口)
    - `id` は int のみ (bool は除外)。文字列 id は 400
    - **空文字 text の要素はリストから落とす** (既存 POST / PATCH と同じ「空文字は無視」)。
      `ChecklistItem.text` は必須なので「空の項目」は表現できない。id 付きで
      送られた場合も同様に落ちる → 宣言的な意味 (送ったリストに存在しない) のとおり削除される
    - **重複 id は先勝ち**。`HabitOrderView` の `dict.fromkeys` と同じ扱いに揃える
    """
    if not isinstance(raw, list):
        raise _ChecklistPayloadError(
            'habit_update_checklist_items_invalid',
            'チェックリストの項目を読み取れませんでした。'
            '少し時間をおいて、もう一度お試しください 🪶',
        )

    entries: list[dict] = []
    seen_ids: set[int] = set()
    for element in raw:
        if isinstance(element, str):
            item_id, text = None, element
        elif isinstance(element, dict):
            item_id = element.get('id')
            text = element.get('text', '')
        else:
            raise _ChecklistPayloadError(
                'habit_update_checklist_items_invalid',
                'チェックリストの項目を読み取れませんでした。'
                '少し時間をおいて、もう一度お試しください 🪶',
            )

        if item_id is not None:
            # bool は int のサブクラスなので明示的に除外する
            if isinstance(item_id, bool) or not isinstance(item_id, int):
                raise _ChecklistPayloadError(
                    'habit_update_checklist_items_invalid',
                    'チェックリストの項目を読み取れませんでした。'
                    '少し時間をおいて、もう一度お試しください 🪶',
                )
            if item_id in seen_ids:
                continue  # 重複 id は先勝ち
            seen_ids.add(item_id)

        text = (text if isinstance(text, str) else str(text)).strip()
        if not text:
            continue  # 空文字は無視 (作成しない)
        if len(text) > _CHECKLIST_TEXT_MAX_LENGTH:
            raise _ChecklistPayloadError(
                'habit_update_checklist_items_invalid',
                f'チェックリストの項目は {_CHECKLIST_TEXT_MAX_LENGTH} 文字までですね。'
                '短くしてから、もう一度お試しください 🪶',
            )
        entries.append({'id': item_id, 'text': text})

    return entries


class HabitDetailView(PlayerMixin, APIView):
    permission_classes = [IsAuthenticatedOrGuest]

    def _get_habit(self, request, pk):
        player = self.get_player(request)
        try:
            return Habit.objects.get(pk=pk, player=player)
        except Habit.DoesNotExist:
            return None

    def get(self, request, pk):
        habit = self._get_habit(request, pk)
        if habit is None:
            return Response({'detail': 'Not found.'}, status=status.HTTP_404_NOT_FOUND)

        data = HabitSerializer(habit).data

        today = timezone.localdate()
        month_rates = []
        for i in range(2, -1, -1):
            y = today.year
            m = today.month - i
            while m <= 0:
                m += 12
                y -= 1
            days_in_month = _cal.monthrange(y, m)[1]
            past_days = today.day if (y == today.year and m == today.month) else days_in_month
            log_count = habit.logs.filter(date__year=y, date__month=m, count__gt=0).count()
            rate = round(log_count / past_days * 100) if past_days > 0 else 0
            month_rates.append({'year': y, 'month': m, 'rate': rate})
        data['month_rates'] = month_rates

        return Response(data)

    def patch(self, request, pk):
        habit = self._get_habit(request, pk)
        if habit is None:
            return Response({'detail': 'Not found.'}, status=status.HTTP_404_NOT_FOUND)

        # 【FEAT-525】新形式 `set_checklist_items` と旧形式 `add_/delete_` の競合は
        # habit_type によらず **最初に** 弾く。意味が競合するので黙ってどちらかを
        # 優先しない (旧クライアントは `set_` を送らないので実害なく共存する)。
        has_set_items = 'set_checklist_items' in request.data
        has_legacy_items = (
            'add_checklist_items' in request.data
            or 'delete_checklist_items' in request.data
        )
        if has_set_items and has_legacy_items:
            return error_response(
                code='habit_update_checklist_payload_conflict',
                message='チェックリストの更新指定が重なっています。'
                        'アプリを最新版に更新してから、もう一度お試しください 🪶',
                status=status.HTTP_400_BAD_REQUEST,
            )

        try:
            # 【FEAT-525】習慣本体とチェックリストを 1 トランザクションにまとめる。
            # 項目側が 400 になったときに「名前だけ変わってリストは元のまま」という
            # 中途半端な状態を残さないため。
            with transaction.atomic():
                # BUG-J: ToDo の priority / due_date が PATCH で silently 無視されていた。
                # HabitSerializer.Meta.fields には含まれているが allowed の whitelist が
                # 古いまま放置されていたため、フロント編集画面の保存が成功 200 でも DB が変わらなかった。
                # habit_type は仕様上「作成後に変更不可」のため意図的に追加しない。
                # 【FEAT-205】due_time は UI 未接続 + 通知発火経路でも未参照の死パイプラインだったため削除。
                allowed = {k: v for k, v in request.data.items() if k in (
                    'name', 'category', 'frequency', 'reset_cycle', 'difficulty', 'order',
                    'memo', 'is_public',
                    'priority', 'due_date',
                )}
                serializer = HabitSerializer(habit, data=allowed, partial=True)
                if not serializer.is_valid():
                    return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)
                serializer.save()

                if habit.habit_type == 'checklist':
                    if has_set_items:
                        self._apply_set_checklist_items(
                            habit,
                            _normalize_set_checklist_items(
                                request.data.get('set_checklist_items'),
                            ),
                        )
                    else:
                        self._apply_legacy_checklist_items(habit, request.data)
        except _ChecklistPayloadError as exc:
            return error_response(
                code=exc.code,
                message=exc.message,
                status=status.HTTP_400_BAD_REQUEST,
            )

        updated = Habit.objects.prefetch_related('checklist_items').get(pk=pk)
        return Response(HabitSerializer(updated, context={'request': request}).data)

    def _apply_legacy_checklist_items(self, habit, data):
        """【後方互換】旧クライアントの `delete_checklist_items` / `add_checklist_items`。

        🔴 **消さないこと。** v1.0.5 が公開中、`1.1.0+6` が審査中で、どちらも
        この 2 フィールドを送る。挙動を変えるのも不可 (追加は必ず末尾)。
        `test_checklist_set_items.py` の後方互換テストがこの契約を縛っている。
        """
        from django.db.models import Max

        delete_ids = data.get('delete_checklist_items', [])
        if delete_ids:
            ChecklistItem.objects.filter(habit=habit, id__in=delete_ids).delete()

        add_items = data.get('add_checklist_items', [])
        if add_items:
            max_order = habit.checklist_items.aggregate(Max('order'))['order__max'] or 0
            for item_data in add_items:
                text = (item_data.get('text', '') if isinstance(item_data, dict) else str(item_data)).strip()
                if text:
                    max_order += 1
                    ChecklistItem.objects.create(habit=habit, text=text, order=max_order)

    def _apply_set_checklist_items(self, habit, entries):
        """【FEAT-525】`set_checklist_items` を適用する (id あり = 更新 / id なし = 作成)。

        ## 🔴 id あり項目は必ず `update` する

        `delete` + `create` にすると `done_date` が失われ、ユーザーから見ると
        **「並べ替えたらチェックが全部外れた」** という明確な退行になる。
        並び順だけを見るテストでは通ってしまうので、`done_date` 保持は
        `test_checklist_set_items.py` が明示的に assert している。

        ## 他 habit の id は黙って無視せず 400

        `set_checklist_items` は id を受け取るので、他 habit の id を混ぜられる。
        `habit=habit` で絞ったうえで、**取りこぼした id があれば 400** にする。
        黙って無視するとクライアント側のバグを隠す。

        ## ロック順序

        2 端末同時保存を直列化するため、対象行を **pk 昇順** で
        `select_for_update` してから書き換える (`HabitOrderView` と同じ
        レンデブー順序。CLAUDE.md「select_for_update のレンデブー順序統一」)。
        last-writer-wins でよいが、中途半端に混ざった順序にはしない。
        """
        existing = {
            item.pk: item
            for item in ChecklistItem.objects
            .select_for_update()
            .filter(habit=habit)
            .order_by('pk')
        }

        keep_ids = [e['id'] for e in entries if e['id'] is not None]
        unknown_ids = [i for i in keep_ids if i not in existing]
        if unknown_ids:
            raise _ChecklistPayloadError(
                'habit_update_checklist_item_not_found',
                'その項目は見つかりませんでした。'
                '画面を開き直してから、もう一度お試しください 🪶',
            )

        # 配列に現れなかった既存項目 = 削除
        ChecklistItem.objects.filter(habit=habit).exclude(pk__in=keep_ids).delete()

        # 項目数は数十なので Case/When 一括 UPDATE までは要らない。
        # 既存は bulk_update、新規は create で index を order に写す。
        to_update = []
        for index, entry in enumerate(entries):
            if entry['id'] is None:
                ChecklistItem.objects.create(
                    habit=habit, text=entry['text'], order=index,
                )
                continue
            item = existing[entry['id']]
            item.text = entry['text']
            item.order = index
            to_update.append(item)

        if to_update:
            ChecklistItem.objects.bulk_update(to_update, ['text', 'order'])

    def delete(self, request, pk):
        habit = self._get_habit(request, pk)
        if habit is None:
            return Response({'detail': 'Not found.'}, status=status.HTTP_404_NOT_FOUND)
        habit.is_active = False
        habit.deleted_at = timezone.now()
        habit.save(update_fields=['is_active', 'deleted_at'])
        return Response(status=status.HTTP_204_NO_CONTENT)


class HabitArchiveView(PlayerMixin, APIView):
    permission_classes = [IsAuthenticatedOrGuest]

    def post(self, request, pk):
        player = self.get_player(request)
        try:
            habit = Habit.objects.get(pk=pk, player=player)
        except Habit.DoesNotExist:
            return Response({'detail': 'Not found.'}, status=status.HTTP_404_NOT_FOUND)
        habit.is_active = False
        habit.save(update_fields=['is_active'])
        return Response({'detail': 'archived'}, status=status.HTTP_200_OK)


class HabitRestoreView(PlayerMixin, APIView):
    permission_classes = [IsAuthenticatedOrGuest]

    def post(self, request, pk):
        player = self.get_player(request)
        try:
            habit = Habit.objects.get(pk=pk, player=player, is_active=False)
        except Habit.DoesNotExist:
            return Response({'detail': 'Not found.'}, status=status.HTTP_404_NOT_FOUND)
        habit.is_active = True
        habit.deleted_at = None
        habit.save(update_fields=['is_active', 'deleted_at'])
        return Response(HabitSerializer(habit).data, status=status.HTTP_200_OK)


class ArchivedHabitListView(PlayerMixin, APIView):
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        player = self.get_player(request)
        habits = Habit.objects.filter(
            player=player, is_active=False, deleted_at__isnull=True
        ).order_by('-id')
        result = []
        for h in habits:
            data = HabitSerializer(h).data
            logs = list(h.logs.filter(count__gt=0).order_by('date').values_list('date', flat=True))
            best_streak = 0
            current_streak = 0
            prev = None
            for d in logs:
                if prev and (d - prev).days == 1:
                    current_streak += 1
                else:
                    current_streak = 1
                best_streak = max(best_streak, current_streak)
                prev = d
            data['best_streak'] = best_streak
            data['total_count'] = h.logs.filter(count__gt=0).count()
            result.append(data)
        return Response(result)


class TrashHabitListView(PlayerMixin, APIView):
    # FEAT-190: ゴミ箱（archived の派生表示）もゲストで参照可能にする。
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def get(self, request):
        player    = self.get_player(request)
        threshold = timezone.now() - timedelta(days=30)
        habits    = Habit.objects.filter(
            player=player,
            is_active=False,
            deleted_at__isnull=False,
            deleted_at__gte=threshold,
        ).order_by('-deleted_at')
        return Response(HabitSerializer(habits, many=True).data)


class HabitCategoriesView(PlayerMixin, APIView):
    """
    GET /api/habits/categories/
    デフォルト4種類 + プレイヤーが使用したカスタムカテゴリを返す。
    """
    permission_classes = [IsAuthenticatedOrGuest]

    _DEFAULTS = ['学習', '仕事', '運動', '体力', '美容', '健康', '精神', '創造', '社交', '休息', 'その他']  # FEAT-147

    def get(self, request):
        player = self.get_player(request)
        used = list(
            Habit.objects.filter(player=player)
            .values_list('category', flat=True)
            .distinct()
        )
        custom = [c for c in used if c not in self._DEFAULTS]
        return Response(self._DEFAULTS + custom)


class HabitCountView(PlayerMixin, APIView):
    """【FEAT-289】 service 抽出後の薄い view layer (旧 240 LOC → 約 50 LOC)。

    実体は `services.habit_count_service.apply_count_change(... is_checklist=False)`。
    本 view はリクエスト解釈 + レスポンス組み立てに専念し、ロック / EXP /
    streak / 報酬連動の業務ロジックはすべて service に集約。
    """
    permission_classes = [IsAuthenticatedOrGuest]
    throttle_classes   = [ScopedRateThrottle]
    throttle_scope     = 'habit_action'

    def post(self, request, pk):
        from ..services.habit_count_service import apply_count_change

        action = request.data.get('action')
        if action not in ('plus', 'minus'):
            return Response(
                {'detail': '"action" must be "plus" or "minus".'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        player = self.get_player(request)
        try:
            habit = Habit.objects.get(pk=pk, player=player, is_active=True)
        except Habit.DoesNotExist:
            return Response({'detail': 'Not found.'}, status=status.HTTP_404_NOT_FOUND)

        delta = 1 if action == 'plus' else -1
        result = apply_count_change(player, habit, delta, is_checklist=False)

        # service が内部で player/habit を更新済 → DB から fresh 取得
        player.refresh_from_db()
        habit.refresh_from_db()

        # BUG-2026-01: minus で取り消し対象が無い場合は冪等な空 response を返す
        if result.no_op:
            return Response({
                'player':              PlayerProfileSerializer(player, context={"request": request}).data,
                'habit':               HabitSerializer(habit).data,
                'diamond_earned':      False,
                'exp_gain':            0,
                'bonus_exp':           0,
                'is_comeback':         False,
                'auto_allocations':    {},
                'auto_shield_type':    None,
                'streak_diamond_days': None,
                'monthly_ticket_awarded': False,
            })

        # 【BUG-66】level_up は self-triggered event。skip_push=True で
        # in-app DB row のみ作成 (ダイアログ二重表示 + dispose race 回避)。
        if result.leveled_up:
            _logger.info(
                'Level UP: player=%s %s -> %s points=%s',
                player.id, result.old_level, result.new_level, player.battle.allocatable_points,
            )
            create_localized_notification(
                player, 'level_up',
                # 【FEAT-449 (2026-06-20)】サビ口調統一: 旧「レベルアップ！ 🎉」(感嘆符 +
                # 🎉) は CLAUDE.md「システム文も同トーンで統一」方針から外れていたため、
                # サビ規約 (感嘆符なし、🪶 マーカー、丁寧体) に揃える。gameplay_review
                # 20260620 §3-C-1 の唯一の例外指摘の解消。
                # 【FEAT-517】文面は api/i18n_messages.py が宛先の言語で組み立てる。
                'level_up',
                new_level=result.new_level,
                old_level=result.old_level,
                skip_push=True,
            )

        # P0-2: 実績チェック (5 集計クエリ) をコミット後に非同期発火
        _player_pk = player.pk
        transaction.on_commit(lambda: _check_achievements_by_pk(_player_pk))

        return Response({
            'player':              PlayerProfileSerializer(player, context={"request": request}).data,
            'habit':               HabitSerializer(habit).data,
            'diamond_earned':      result.diamond_earned,
            # 既存契約: plus 経路のみ exp_gain を返し minus 経路は 0
            'exp_gain':            result.exp_gain if action == 'plus' else 0,
            # 既存契約: minus 経路でも実値を返す (HabitCountView レガシー挙動)
            'bonus_exp':           result.bonus_exp,
            'is_comeback':         result.is_comeback if action == 'plus' else False,
            'auto_allocations':    result.auto_allocations,
            'auto_shield_type':    result.auto_shield_type if action == 'plus' else None,
            # 【FEAT-314】 7 倍数 streak 到達時のみ int、それ以外 null
            'streak_diamond_days': result.streak_diamond_days,
            # 【FEAT-377】ストリーク保護発動時のみ True (UI 通知用)
            'streak_protected': result.streak_protected if action == 'plus' else False,
            # 【FEAT-379】今回付与した結晶 {crystal_key: count} (stat Lv UP 時のみ非空)
            'crystals_awarded': result.crystals_awarded if action == 'plus' else {},
            # 【FEAT-398】日次 EXP 閾値 (25 件目) 到達直後のみ True (Flutter が SnackBar 表示)
            'daily_throttle_triggered': result.daily_throttle_triggered if action == 'plus' else False,
            # 【FEAT-420】予約していたストリーク保護が今回の達成で消費された場合のみ True
            'streak_protection_pending_consumed': result.streak_protection_pending_consumed if action == 'plus' else False,
            # 【FEAT-420】予約消費時のメッセージ (Flutter SnackBar 表示用、非消費時は null)
            'streak_protection_message': result.streak_protection_message if action == 'plus' else None,
            # 【FEAT-433】当月 21 日達成で SSR 確定チケットを配布した場合のみ True
            'monthly_ticket_awarded': result.monthly_ticket_awarded if action == 'plus' else False,
            # 【BUG-122 (2026-06-14)】その日初回タスク達成ボーナス。non-null なら
            # Mobile が 7 日カレンダー + スタンプ演出を表示する。
            'today_login_bonus': result.today_login_bonus if action == 'plus' else None,
            # 【FEAT-452 (2026-06-20)】当日 3 回目のタスク達成でフレンドプレゼント
            # popup 候補。non-null なら Mobile が確認ダイアログを表示する。
            'friend_gift_candidate':
                result.friend_gift_candidate if action == 'plus' else None,
            # 【FEAT-479 (2026-07-06)】その日初回タスク達成でパズルピース (grey) 付与。
            # non-null なら Mobile が Task piece 演出モーダルを表示する。
            'puzzle_piece_awarded':
                result.puzzle_piece_awarded if action == 'plus' else None,
        })


class TodoDoneListView(PlayerMixin, APIView):
    """
    GET /api/habits/todos/done/
    完了済みのToDoを日付グループで返す（当日分を含む）。
    レスポンス:
    [
      {
        "date": "2026-05-07",
        "todos": [ HabitSerializer data, ... ]
      },
      ...
    ]
    """
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        from collections import defaultdict

        player = self.get_player(request)
        today  = timezone.localdate()

        # 完了済みの HabitLog（todo タイプのみ）— 当日分を含む
        logs = (
            HabitLog.objects
            .filter(
                habit__player=player,
                habit__is_active=True,
                habit__habit_type='todo',
                count__gte=1,
            )
            # .exclude(date=today) を削除 — 当日完了分を含める
            .select_related('habit')
            .order_by('-date')
        )

        # 日付でグループ化（同じ ToDo の複数 log は最新のみ）
        grouped: dict = defaultdict(list)
        seen_habits: set = set()

        for log in logs:
            habit = log.habit
            if habit.id in seen_habits:
                continue
            seen_habits.add(habit.id)
            grouped[str(log.date)].append(HabitSerializer(habit).data)

        result = [
            {'date': d, 'todos': todos}
            for d, todos in sorted(grouped.items(), reverse=True)
        ]
        return Response(result)


class HabitOrderView(PlayerMixin, APIView):
    permission_classes = [IsAuthenticatedOrGuest]

    def post(self, request):
        order_ids = request.data.get('order')
        if not isinstance(order_ids, list):
            return Response(
                {'detail': '"order" must be a list of habit IDs.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        player = self.get_player(request)

        # P2-09: 旧実装は要素ごとに UPDATE 文を発行していたため 50 件並べ替えで
        # 50 クエリの N+1 が発生し、atomic で囲まれてもいなかった。
        # Case/When で一括 UPDATE に変更し、atomic で全部成功 or 何もしないを保証する。
        # 重複 ID は dict_fromkeys で先勝ち優先（後の index で意図せず上書きされない）。
        unique_ids = list(dict.fromkeys(order_ids))  # 重複除去・順序保持
        if not unique_ids:
            return Response({'status': 'ok'})

        with transaction.atomic():
            # BUG-2026-10: 同一ユーザーが 2 端末で同時に並べ替えた場合の
            # last-writer-wins を直列化するため、対象 Habit 行を pk 昇順で
            # ロックしてから一括 UPDATE する。デッドロックを避けるため必ず
            # pk__in を昇順 sort してから select_for_update する。
            list(
                Habit.objects
                .select_for_update()
                .filter(pk__in=unique_ids, player=player)
                .order_by('pk')
                .values_list('pk', flat=True)
            )

            when_clauses = [
                When(pk=habit_id, then=Value(index))
                for index, habit_id in enumerate(unique_ids)
            ]
            Habit.objects.filter(pk__in=unique_ids, player=player).update(
                order=Case(*when_clauses, output_field=IntegerField()),
            )
        return Response({'status': 'ok'})


class ChecklistItemToggleView(PlayerMixin, APIView):
    """【FEAT-289】 service 抽出後の薄い view layer (旧 160 LOC → 約 50 LOC)。

    実体は `services.habit_count_service.apply_count_change(... is_checklist=True)`。
    checklist 経路の差分挙動 (comeback / auto_shield / streak_diamond /
    HabitRewardLog はスキップ、battle_charges は count 同等加算 / BUG-96) は
    service 内部の分岐で吸収。本 view では追加で `ChecklistItem.done_date` の
    toggle を担当する。
    """
    permission_classes = [IsAuthenticatedOrGuest]

    def post(self, request, pk, item_pk):
        from ..services.habit_count_service import apply_count_change

        player = self.get_player(request)

        try:
            habit = Habit.objects.get(pk=pk, player=player, is_active=True)
        except Habit.DoesNotExist:
            return Response({'detail': 'Not found.'}, status=status.HTTP_404_NOT_FOUND)

        try:
            item = ChecklistItem.objects.get(pk=item_pk, habit=habit)
        except ChecklistItem.DoesNotExist:
            return Response({'detail': 'Checklist item not found.'}, status=status.HTTP_404_NOT_FOUND)

        today = timezone.localdate()
        was_checked = (item.done_date == today)
        delta = -1 if was_checked else 1
        result = apply_count_change(player, habit, delta, is_checklist=True)

        # ChecklistItem の done_date toggle は本 view 側の責務 (service は habit 全体の
        # 増減のみ扱うため、UI 状態である done_date は呼び出し側で更新)。
        if was_checked:
            item.done_date = None
        else:
            item.done_date = today
        item.save(update_fields=['done_date'])

        # service 内部で player/habit を更新済 → DB から fresh 取得
        player.refresh_from_db()
        habit.refresh_from_db()

        if result.leveled_up:
            _logger.info(
                'Level UP: player=%s %s -> %s', player.id, result.old_level, result.new_level,
            )
            # 【BUG-66】level_up は self-triggered event (skip_push=True)
            create_localized_notification(
                player, 'level_up',
                # 【FEAT-449 (2026-06-20)】サビ口調統一: 旧「レベルアップ！ 🎉」(感嘆符 +
                # 🎉) は CLAUDE.md「システム文も同トーンで統一」方針から外れていたため、
                # サビ規約 (感嘆符なし、🪶 マーカー、丁寧体) に揃える。gameplay_review
                # 20260620 §3-C-1 の唯一の例外指摘の解消。
                # 【FEAT-517】文面は api/i18n_messages.py が宛先の言語で組み立てる。
                'level_up',
                new_level=result.new_level,
                old_level=result.old_level,
                skip_push=True,
            )

        # BUG-K: HabitCountView と非対称な実績通知発火漏れを解消済 (plus / minus 双方で呼ぶ)。
        # P0-2: on_commit 化 (5 集計クエリをホットパスから除去)
        _player_pk = player.pk
        transaction.on_commit(lambda: _check_achievements_by_pk(_player_pk))

        # BUG-B: HabitCountView と整合性を取り、reward toast / Lv.UP 演出に
        # 必要なフィールドを返す。BUG-2026-0512-02: check ON 経路で bonus_exp 実値。
        # 既存契約: check OFF (minus) 経路では exp_gain / bonus_exp とも 0 (演出抑止)、
        # check ON (plus) 経路では実値を返す。
        is_check_on = (delta == 1)
        return Response({
            'player':            PlayerProfileSerializer(player, context={"request": request}).data,
            'habit':             HabitSerializer(habit).data,
            'diamond_earned':    result.diamond_earned,
            'exp_gain':          result.exp_gain if is_check_on else 0,
            'bonus_exp':         result.bonus_exp if is_check_on else 0,
            'is_comeback':       False,  # チェックリストは comeback 未判定 (既存契約)
            'auto_shield_type':  None,
            'auto_allocations':  result.auto_allocations,
            # 【FEAT-433】当月 21 日達成で SSR 確定チケットを配布した場合のみ True
            'monthly_ticket_awarded': result.monthly_ticket_awarded if is_check_on else False,
            # 【BUG-122 (2026-06-14)】その日初回タスク達成ボーナス。
            'today_login_bonus': result.today_login_bonus if is_check_on else None,
            # 【FEAT-452 (2026-06-20)】当日 3 回目のタスク達成でフレンドプレゼント
            # popup 候補。non-null なら Mobile が確認ダイアログを表示する。
            'friend_gift_candidate':
                result.friend_gift_candidate if is_check_on else None,
            # 【FEAT-479 (2026-07-06)】その日初回タスク達成でパズルピース (grey) 付与。
            # non-null なら Mobile が Task piece 演出モーダルを表示する。
            'puzzle_piece_awarded':
                result.puzzle_piece_awarded if is_check_on else None,
        })


class ShieldActivateView(PlayerMixin, APIView):
    permission_classes = [IsAuthenticatedOrGuest]

    def post(self, request, pk):
        player = self.get_player(request)

        try:
            habit = Habit.objects.get(pk=pk, player=player, is_active=True)
        except Habit.DoesNotExist:
            return Response({'detail': 'Not found.'}, status=status.HTTP_404_NOT_FOUND)

        today = timezone.localdate()

        with transaction.atomic():
            # Habit を先にロックして shield_date の二重チェックを防ぐ
            habit = Habit.objects.select_for_update().get(pk=habit.pk)
            if habit.shield_date == today:
                return error_response(
                           code='habit_streak_protect_already_active',
                           message='すでに今日の保護が有効です',
                           status=status.HTTP_400_BAD_REQUEST,
                       )

            player = PlayerProfile.objects.select_for_update().get(pk=player.pk)
            locked_eco = player.economy
            if locked_eco.diamonds < 1:
                return error_response(
                           code='habit_streak_protect_not_enough_diamonds',
                           message='ダイヤモンドが不足しています',
                           status=status.HTTP_400_BAD_REQUEST,
                       )
            locked_eco.diamonds -= 1
            locked_eco.save(update_fields=['diamonds'])

            # habit.save も同一トランザクション内で行う
            habit.shield_date = today
            habit.save(update_fields=['shield_date'])

        return Response({
            'player': PlayerProfileSerializer(player, context={"request": request}).data,
            'habit':  HabitSerializer(habit).data,
        })
