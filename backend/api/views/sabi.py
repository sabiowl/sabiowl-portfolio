import hashlib
import logging

from django.db.models import Count, Q, Sum
from django.utils import timezone  # BUG-A: サーバー TZ ではなく JST 基準で日付を扱う

# 【SEC-11】anthropic は SabiNavigateView 専用だったため、SabiNavigate(LLM 対話型
# ナビゲーション) 廃止（2026-05-15）に伴い import を撤去。requirements.txt からも削除済み。

_logger = logging.getLogger(__name__)

from ..authentication import ExpiringTokenAuthentication  # 【BUG-163】DRF 素の ExpiringTokenAuthentication は停止検査も期限も持たない
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView

from ..authentication import GuestTokenAuthentication  # FEAT-190
from ..models import Habit, HabitLog
from ..permissions import IsAuthenticatedOrGuest  # FEAT-187
from .mixins import PlayerMixin
from ..sabi_loader import load_sabi_dialogue as _load_dialogue

# ── セリフは YAML + DB (SabiMessage) を統合してロードされる ─────────────────
# 旧: モジュールロード時 1 回だけ YAML から読み (`_DLG = _load_dialogue()`)、
#     `_SABI_MESSAGES = _DLG['home']` 等の module-level 定数に固定する設計。
# 新 (2026-06-26): Django admin から SabiMessage を編集すると即時反映するよう、
#     各 helper 関数内で `_load_dialogue()` を都度呼び出す経路に変更。
#     `_load_dialogue()` 自体は 60s TTL Django cache + post_save signal で
#     キャッシュ更新されるため、コール頻度過剰でも DB 負荷は最小。
#
# 後方互換のための module-level 名前 (`_SABI_MESSAGES` 等) は dict/list の
# 動的解決プロキシで維持する。これにより既存テスト
# (`from api.views.sabi import _SABI_MESSAGES`) もそのまま動作する。


class _DictProxy:
    """`load_sabi_dialogue()` から動的に dict をたどるプロキシ。

    `_SABI_MESSAGES['no_habits']` 等の subscript / `.get()` / `__contains__`
    / `.items()` 等の dict 標準操作をサポート。返り値は呼び出し時の
    最新セリフを反映する。
    """

    def __init__(self, *path):
        self._path = path

    def _resolve(self):
        node = _load_dialogue()
        for p in self._path:
            node = node[p]
        return node

    def __getitem__(self, key):
        return self._resolve()[key]

    def __contains__(self, key):
        return key in self._resolve()

    def __iter__(self):
        return iter(self._resolve())

    def __len__(self):
        return len(self._resolve())

    def get(self, key, default=None):
        return self._resolve().get(key, default)

    def keys(self):
        return self._resolve().keys()

    def values(self):
        return self._resolve().values()

    def items(self):
        return self._resolve().items()


class _ListProxy:
    """`load_sabi_dialogue()` から動的に list をたどるプロキシ。

    `REST_DAY_MESSAGES[idx]` の subscript + `len()` + iteration をサポート。
    """

    def __init__(self, *path):
        self._path = path

    def _resolve(self):
        node = _load_dialogue()
        for p in self._path:
            node = node[p]
        return node

    def __getitem__(self, idx):
        return self._resolve()[idx]

    def __len__(self):
        return len(self._resolve())

    def __iter__(self):
        return iter(self._resolve())

    def __contains__(self, item):
        return item in self._resolve()


# 後方互換 module-level 名前 (proxy で動的解決、admin 更新が即時反映)
_SABI_MESSAGES        = _DictProxy('home')
HABIT_KNOWLEDGE       = _DictProxy('knowledge')
TIME_SEGMENT_MESSAGES = _DictProxy('time_segment')
REST_DAY_MESSAGES     = _ListProxy('contexts', 'rest_day')
COMEBACK_MESSAGES     = _ListProxy('contexts', 'comeback')
DEFAULT_MESSAGES      = _ListProxy('contexts', 'default')


# ── SABI-02: 達成メッセージ生成 ──────────────────────────────────────────
def get_achievement_message(habit_category: str, habit_name: str) -> str:
    """
    習慣カテゴリと習慣名から知識ベースを引き、達成メッセージを生成する。
    カテゴリが未知の場合は DEFAULT_MESSAGES から選ぶ。
    """
    knowledge_list = HABIT_KNOWLEDGE.get(habit_category)
    if not knowledge_list:
        seed = int(hashlib.md5(habit_name.encode()).hexdigest(), 16)
        return DEFAULT_MESSAGES[seed % len(DEFAULT_MESSAGES)]

    seed = int(hashlib.md5(f"{habit_name}{timezone.localdate()}".encode()).hexdigest(), 16)
    entry = knowledge_list[seed % len(knowledge_list)]
    fact = entry['fact']
    connection = entry['connection'].format(name=habit_name)
    return f"{fact}\n{connection}"


# ── SABI-03: コンテキスト → 感情タグ マッピング ────────────────────────
CONTEXT_EMOTION_MAP = {
    'login':       'normal',
    'achievement': 'excited',
    'streak':      'sparkling',
    'comeback':    'sad',
    'rest_day':    'pity',
    'knowledge':   'wise',
    'failure':     'awkward',
    'default':     'normal',
}


def get_streak_emotion(streak: int) -> str:
    """ストリーク日数に応じて感情タグを分岐する"""
    if streak >= 30:
        return 'sparkling'
    elif streak >= 7:
        return 'excited'
    else:
        return 'happy'


# ── SABI-02: 連続記録メッセージ ──────────────────────────────────────────
def get_streak_message(streak: int) -> str:
    """連続記録日数に応じたメッセージを返す（sabi_dialogue.yaml のマイルストーン定義に従う）。"""
    dlg = _load_dialogue()  # 呼び出し時にロード (admin 更新を即時反映)
    milestones = dlg['streak']['milestones']
    for entry in sorted(milestones, key=lambda e: e['threshold'], reverse=True):
        if streak >= entry['threshold']:
            return entry['message'].replace('{streak}', str(streak))
    return dlg['streak']['default']


# ── 既存ヘルパー ───────────────────────────────────────────────────────────
def get_sabi_message(player, today_summary: dict, nonce: str = '', locale: str = 'ja') -> str:
    """サビメッセージを選択して返す。

    【新規 (2026-06-26)】`nonce` 引数を seed 計算に組み込み、Mobile からの
    pull-to-refresh 経由で異なるメッセージを返せるよう拡張。nonce 未指定 (`''`)
    のとき現状互換 (seed = player.id + today)、指定時は seed が変わるため
    プールから別の選択になる。
    【FEAT-489 Phase 4】`locale` 引数追加。locale='en' のとき en プールを使用。
    """
    completed = today_summary.get('completed', 0)
    total     = today_summary.get('total', 0)
    level     = player.battle.level

    seed_str = f"{player.id}{timezone.localdate()}{nonce}"
    seed = int(hashlib.md5(seed_str.encode()).hexdigest(), 16)

    is_pun_day = (seed % 10 == 0)
    # 【新規 (2026-06-25)】習慣化知識を ~14% (7 日に 1 回) で共有。
    # 習慣ゼロ時は no_habits の文脈優先のため発動しない。
    is_knowledge_day = (seed % 7 == 0) and total > 0

    # 【FEAT-489 Phase 4】locale-aware pool loading
    dlg = _load_dialogue(locale=locale)
    sabi_msgs = dlg.get('home', {})

    if total == 0:
        pool = sabi_msgs.get('no_habits', _SABI_MESSAGES['no_habits'])
    elif completed == total:
        pool = (sabi_msgs.get('pun', _SABI_MESSAGES['pun'])
                if is_pun_day
                else sabi_msgs.get('all_done', _SABI_MESSAGES['all_done']))
    elif completed > 0:
        pool = sabi_msgs.get('partial', _SABI_MESSAGES['partial'])
    else:
        pool = sabi_msgs.get('none_done', _SABI_MESSAGES['none_done'])

    if level >= 30 and seed % 5 == 0:
        pool = sabi_msgs.get('high_level', _SABI_MESSAGES['high_level'])
    elif level < 5 and seed % 4 == 0:
        pool = sabi_msgs.get('early_level', _SABI_MESSAGES['early_level'])
    # 【新規 (2026-06-25)】level override 不発時のみ knowledge_general を選択。
    # 「高Lv/低Lv の特別認知 (high_level/early_level)」を優先し、それ以外の
    # 通常 Lv 帯で 7 日に 1 回程度、習慣化の知見が混ざる UX。
    elif is_knowledge_day:
        pool = sabi_msgs.get('knowledge_general', _SABI_MESSAGES['knowledge_general'])

    return pool[seed % len(pool)] if pool else ''


def period_summary(player, *, total: int | None = None) -> dict:
    """【BUG-145】`frequency` の期間で「達成済み」を数えた summary を返す。

    `get_sabi_message` に渡す用。`today_summary()` を渡してはいけない。

    ## なぜ分けるか (実際に起きたこと)

    `today_summary()` は **今日 1 日** の `HabitLog` しか見ない。一方で習慣カードの
    完了表示は **`frequency` の期間** で判定している
    (`HabitSerializer.get_period_done`、FEAT-520)。このため

        週次習慣を月曜に達成 → 火曜以降もカードは「完了」
                             → サビは completed=0 を見て `home.none_done` を選ぶ

    となり、**同じ習慣をカードは「完了」・サビは「達成ゼロ」と読む**状態だった。
    ユーザーは 2026-06-26 にこれに気付き、`home_none_done` プールを admin から
    一括無効化して抑えようとしたが、DB が空のプールは YAML にフォールバックする
    ため日本語では効かず、**英語だけが日本語に落ちる** 2 次症状を生んだ。

    ## 判定条件

    `get_period_done` と **同一** (`count > 0` の日が期間内に 1 日以上)。
    ToDo (`habit_type='todo'`) は `frequency` に関わらず `daily` 扱いにする点も
    揃えている。条件が 2 箇所に分かれると必ずずれるため、期間の起点は
    `serializers.get_period_start` を経由すること。

    ## 戻り値の意味

    `completed == total` は「**すべての習慣が、それぞれの周期の中で達成済み**」。
    日次習慣のみのユーザー (大多数) では `today_summary()` と一致するため、
    **挙動は変わらない**。

    `total` は呼び出し側が既に数えている場合に渡せる (ホーム bootstrap は
    `active_habits.count()` を先に持っているため、重複クエリを避ける)。
    """
    # serializers は models と service しか import しないため循環しない。
    from ..serializers import get_period_start

    today  = timezone.localdate()
    active = Habit.objects.filter(player=player, is_active=True)

    # ToDo は「1 回やって終わり」の単発タスクなので frequency を持たない扱い
    # (get_period_count / get_period_done と同じ)。daily バケットへ寄せる。
    #
    # 【2026-08-16 機能レビュー P2】初版は 3 バケットを別々に COUNT していたが、
    # 「期間の起点が違うだけの同じ COUNT」なので **OR 1 本に畳める**。
    # ホーム bootstrap は起動時に必ず叩かれるので 3 本 → 1 本の差は効く。
    #
    # 3 バケットは相互排他かつ全 habit を覆う (todo は daily のみ、
    # 非 todo は frequency ちょうど 1 つ)。この排他性が崩れると `distinct()` が
    # 効いていても **バケット間**で二重計上が起きるため、
    # `test_buckets_are_mutually_exclusive_and_total` で明示的に縛っている。
    is_todo = Q(habit__habit_type='todo')
    in_period = (
        (is_todo & Q(date__gte=get_period_start(today, 'daily')))
        | (~is_todo & Q(habit__frequency='daily',
                        date__gte=get_period_start(today, 'daily')))
        | (~is_todo & Q(habit__frequency='weekly',
                        date__gte=get_period_start(today, 'weekly')))
        | (~is_todo & Q(habit__frequency='monthly',
                        date__gte=get_period_start(today, 'monthly')))
    )

    completed = (
        HabitLog.objects
        .filter(in_period, habit__in=active, count__gte=1, date__lte=today)
        .values('habit_id')
        .distinct()
        .count()
    )

    return {
        'completed': completed,
        'total':     active.count() if total is None else total,
    }


def today_summary(player) -> dict:
    """BUG-10: 同一条件の重複クエリを DB 集計 1本に統合（クエリ数: 3→2）

    【BUG-145】**サビのプール選択には使わないこと** (`period_summary` を使う)。
    本関数は「今日 1 日」の実績で、`/api/player/` の `today_summary` が
    その意味で公開している値。
    """
    today         = timezone.localdate()
    active_habits = Habit.objects.filter(player=player, is_active=True)
    total         = active_habits.count()

    agg = HabitLog.objects.filter(habit__in=active_habits, date=today).aggregate(
        completed=Count('id', filter=Q(count__gte=1)),
        exp_today=Sum('exp_gained'),
    )

    return {
        'completed': agg['completed'] or 0,
        'total':     total,
        'exp_today': agg['exp_today']  or 0,
    }


_TIME_GREETINGS = _DictProxy('greetings')


def _apply_greeting(message: str, time_segment: str, locale: str = 'ja') -> str:
    """時間帯挨拶をメッセージ先頭に付与する。

    【FEAT-489 Phase 4 hotfix (2026-08-02)】`locale` 引数追加。

    greetings は `_POOL_TO_YAML_PATH` に無い構造化プールで DB 上書きの対象外
    なので、`SabiMessage.content_en` 経路では英語化できない。YAML の
    `greetings_en` を直接引く。未定義 locale / キー欠落時は ja にフォールバック
    (英語ユーザーに空文字を返すより、日本語でも挨拶が出る方が実害が小さい)。
    """
    if locale == 'en':
        greetings = _load_dialogue(locale=locale).get('greetings_en') or {}
        greeting = greetings.get(time_segment) or _TIME_GREETINGS.get(time_segment)
    else:
        greeting = _TIME_GREETINGS.get(time_segment)
    if greeting:
        return f'{greeting}\n{message}'
    return message


# ── SabiMessageView ───────────────────────────────────────────────────────
class SabiMessageView(PlayerMixin, APIView):
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        player       = self.get_player(request)
        today        = timezone.localdate()
        time_segment = request.query_params.get('time_segment', '')
        context      = request.query_params.get('context', '')
        # 【新規 (2026-06-26)】pull-to-refresh 用 nonce (Mobile が refresh 毎に
        # インクリメントして送信)。default context (= ホーム画面常用) の seed
        # 計算に組み込み、同日でも refresh ごとに異なるメッセージを返す。
        nonce        = request.query_params.get('nonce', '')
        # 【FEAT-489 Phase 4】I18nMiddleware が確定した locale を読む (default 'ja')
        locale       = getattr(request, 'locale', 'ja')

        # ── SABI-02 / SABI-03: context ディスパッチ ──────────────────
        #
        # 【2026-08-02】以下の context 分岐 5 種は **Mobile から呼ばれていない**。
        # `context` を送る経路は sabi_provider.dart の
        # `sabiAchievementMessageProvider` / `sabiStreakMessageProvider` の
        # 2 つだけで、そのどちらも定義箇所以外に参照が無い
        # (20260802 functional review §4 C-1、PM が独立に再確認)。
        # 通常のホーム表示で走るのは views/home.py の bootstrap 経路のみ。
        #
        # 紐づく get_achievement_message / get_streak_message / get_streak_emotion、
        # YAML の knowledge / streak プールも同様に到達不能。これらは
        # `_POOL_TO_YAML_PATH` に無く SabiMessage にも入っていないため、
        # **英訳の投入経路にも乗っていない** (= reviewer 発注の対象外)。
        if context == 'achievement':
            habit_category = request.query_params.get('habit_category', '')
            habit_name     = request.query_params.get('habit_name', '')
            message = get_achievement_message(habit_category, habit_name)
            return Response({
                'message':    message,
                'is_rest_day': False,
                'context':    'achievement',
                'emotion':    CONTEXT_EMOTION_MAP['achievement'],
            })

        if context == 'streak':
            try:
                streak = int(request.query_params.get('streak', '0'))
            except (ValueError, TypeError):
                streak = 0
            message = get_streak_message(streak)
            emotion = get_streak_emotion(streak)
            return Response({
                'message':    message,
                'is_rest_day': False,
                'context':    'streak',
                'emotion':    emotion,
            })

        if context == 'rest_day':
            seed = int(hashlib.md5(f"{player.id}{today}".encode()).hexdigest(), 16)
            pool = _load_dialogue(locale=locale).get('contexts', {}).get('rest_day', REST_DAY_MESSAGES)
            message = pool[seed % len(pool)] if pool else ''
            return Response({
                'message':    message,
                'is_rest_day': True,
                'context':    'rest_day',
                'emotion':    CONTEXT_EMOTION_MAP['rest_day'],
            })

        if context == 'comeback':
            seed = int(hashlib.md5(f"{player.id}{today}".encode()).hexdigest(), 16)
            pool = _load_dialogue(locale=locale).get('contexts', {}).get('comeback', COMEBACK_MESSAGES)
            message = pool[seed % len(pool)] if pool else ''
            return Response({
                'message':    message,
                'is_rest_day': True,
                'context':    'comeback',
                'emotion':    CONTEXT_EMOTION_MAP['comeback'],
            })

        if context == 'default':
            seed = int(hashlib.md5(f"{player.id}{today}".encode()).hexdigest(), 16)
            pool = _load_dialogue(locale=locale).get('contexts', {}).get('default', DEFAULT_MESSAGES)
            message = pool[seed % len(pool)] if pool else ''
            return Response({
                'message':    message,
                'is_rest_day': False,
                'context':    'default',
                'emotion':    CONTEXT_EMOTION_MAP['default'],
            })

        # ── 通常判定（既存ロジック）──────────────────────────────────
        # 【FEAT-424 (2026-06-11)】休息日チェック（最優先判定）は廃止。
        # RestDay table は既存データ参照用に残置するが、sabi メッセージへの
        # 反映は機能停止する。
        # 【BUG-145】今日 1 日ではなく frequency の期間で達成を数える
        # (ホーム bootstrap 側と同じ判定にする)。
        summary = period_summary(player)
        message = _apply_greeting(
            get_sabi_message(player, summary, nonce=nonce, locale=locale),
            time_segment,
            locale=locale,
        )
        return Response({
            'message':    message,
            'is_rest_day': False,
            'context':    'default',
            'emotion':    CONTEXT_EMOTION_MAP['default'],
        })


# ── SABI-04: 対話型ナビゲーション機能は SEC-11 で完全廃止 ────────────────
# Anthropic Claude API 経由の LLM ナビゲーションは月額数万円のコストと API 失敗時の
# UX 低下リスクが回収できないため、機能レビュー 20260515 P0-2 で「廃止」判定。
# 関連: speech_to_text Flutter 依存も同時撤去（pubspec.yaml）。
# 廃止対象だった内容:
#   - SabiNavigateView クラス（POST /api/sabi/navigate/）
#   - AVAILABLE_ROUTES / AVAILABLE_ACTIONS / NAVIGATE_SYSTEM_PROMPT / _NAVIGATE_FALLBACK
#   - anthropic import + クライアント呼び出し
