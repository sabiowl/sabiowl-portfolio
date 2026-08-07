import logging
from datetime import date, timedelta
from django.utils import timezone
from rest_framework import serializers
from .models import PlayerProfile, CharacterStat, Habit, HabitLog, PlayerItem, ChecklistItem, Friendship, Character, Achievement, PlayerAchievement, TimelineEvent, GoogleEventCompletion, Job, TaskSuggestion, GachaReward  # 【FEAT-467】/ 【FEAT-518】GachaReward
from .services.daily_throttle_service import current_daily_battle_count

_i18n_logger = logging.getLogger(__name__)


class I18nFieldMixin:
    """【FEAT-489 Phase 4】`_en` field への silent fallback を汎用化する Serializer mixin。

    使い方 (CharacterSerializer 例):
        class CharacterSerializer(I18nFieldMixin, serializers.ModelSerializer):
            name = serializers.SerializerMethodField()
            def get_name(self, obj): return self.get_i18n(obj, 'name')
    """

    def get_i18n(self, obj, base_field: str) -> str:
        locale = getattr(getattr(self, 'context', {}).get('request'), 'locale', 'ja')
        if locale == 'en':
            en_value = (getattr(obj, f'{base_field}_en', '') or '').strip()
            if en_value:
                return en_value
            _i18n_logger.info(
                'i18n_fallback',
                extra={
                    'model': obj.__class__.__name__,
                    'obj_id': getattr(obj, 'pk', None),
                    'field': base_field,
                    'from_locale': 'en',
                    'to_locale': 'ja',
                },
            )
        return getattr(obj, base_field, '')


def get_i18n_field(obj, base_field: str, locale: str) -> str:
    """View 層 (serializer を使わないインライン dict) 向けの i18n フィールド取得ヘルパー。"""
    if locale == 'en':
        en_value = (getattr(obj, f'{base_field}_en', '') or '').strip()
        if en_value:
            return en_value
        _i18n_logger.info(
            'i18n_fallback',
            extra={
                'model': obj.__class__.__name__,
                'obj_id': getattr(obj, 'pk', None),
                'field': base_field,
                'from_locale': 'en',
                'to_locale': 'ja',
            },
        )
    return getattr(obj, base_field, '')


def get_period_start(today: date, cycle: str) -> date:
    """【FEAT-520】`reset_cycle` / `frequency` の期間開始日を返す共通ヘルパー。

    `period_count` は `reset_cycle`、`period_done` は `frequency` で期間を求めるが、
    **境界の定義が 2 箇所に分かれると必ずずれる**ので必ず本関数を経由すること。

    週の開始は月曜 (`weekday() == 0`)。既存の `get_period_progress()` および
    Flutter 側の週表示と揃えている。

    未知の値 / `'daily'` は today を返す (= その日だけの窓)。
    """
    if cycle == 'weekly':
        return today - timedelta(days=today.weekday())
    if cycle == 'monthly':
        return today.replace(day=1)
    if cycle == 'yearly':
        return today.replace(month=1, day=1)
    return today


class ChecklistItemSerializer(serializers.ModelSerializer):
    is_done = serializers.SerializerMethodField()

    class Meta:
        model  = ChecklistItem
        fields = ['id', 'text', 'order', 'is_done']

    def get_is_done(self, obj):
        return obj.done_date == timezone.localdate()


class HabitLogSerializer(serializers.ModelSerializer):
    habit = serializers.PrimaryKeyRelatedField(read_only=True)

    class Meta:
        model = HabitLog
        fields = ['habit', 'date', 'count', 'exp_gained']


class HabitSerializer(serializers.ModelSerializer):
    id              = serializers.IntegerField(read_only=True)
    created_at      = serializers.DateField(read_only=True)
    today_log       = serializers.SerializerMethodField()
    history         = serializers.SerializerMethodField()
    checklist_items = serializers.SerializerMethodField()
    shield_active   = serializers.SerializerMethodField()
    period_progress = serializers.SerializerMethodField()
    period_count    = serializers.SerializerMethodField()  # 【FEAT-520】
    period_done     = serializers.SerializerMethodField()  # 【FEAT-520】

    class Meta:
        model = Habit
        fields = [
            'id', 'name', 'category', 'frequency', 'reset_cycle', 'habit_type', 'difficulty', 'order',
            'streak', 'best_streak', 'total_count', 'total_exp',
            'created_at', 'is_active', 'memo', 'is_public',
            'priority', 'due_date',  # 【FEAT-205】due_time を削除（死パイプライン）
            'today_log', 'history', 'checklist_items', 'shield_active', 'period_progress',
            # 【FEAT-520】追加のみ。既存フィールドの意味は変えない (§4.2)。
            # v1.0 は launch 済で旧アプリが実機で動いているため、`period_progress`
            # の `done` / `total` / `label` を「回数」に変えると進捗バーが壊れる。
            'period_count', 'period_done',
        ]
        read_only_fields = [
            'streak', 'best_streak', 'total_count', 'total_exp',
            'is_active',  # アーカイブは専用 endpoint 経由のみ
        ]

    def validate(self, attrs):
        """frequency × reset_cycle の組合せを検証する。
        CLAUDE.md 仕様: reset_cycle は frequency 以上のサイクルのみ許可。
        ルール自体は Habit.ALLOWED_RESET_CYCLES が source of truth。
        period_progress 計算はこの不変条件に依存するため、ここで弾かないと
        get_period_progress() が None を返してフロントが表示崩壊する。
        """
        freq  = attrs.get('frequency',   getattr(self.instance, 'frequency',   None))
        cycle = attrs.get('reset_cycle', getattr(self.instance, 'reset_cycle', None))
        if freq and cycle:
            allowed = Habit.ALLOWED_RESET_CYCLES.get(freq, set())
            if cycle not in allowed:
                raise serializers.ValidationError({
                    'reset_cycle': (
                        f"frequency='{freq}' に対して reset_cycle='{cycle}' は無効です。"
                        f" 許可: {sorted(allowed)}"
                    ),
                })
        return attrs

    def _get_cached_logs(self, obj):
        """
        prefetch キャッシュ (_year_logs) があればそれを返す。
        キャッシュがない場合は DB にフォールバックして今年分を取得する。
        """
        cached = getattr(obj, '_year_logs', None)
        if cached is not None:
            return cached
        today = timezone.localdate()
        year_start = today.replace(month=1, day=1)
        return list(obj.logs.filter(date__gte=year_start).order_by('date'))

    def get_today_log(self, obj):
        """今日の HabitLog を返す。なければ null。"""
        today = timezone.localdate()
        logs = self._get_cached_logs(obj)
        for log in logs:
            if log.date == today:
                return HabitLogSerializer(log).data
        return None

    def get_history(self, obj):
        """過去30日分の { "YYYY-MM-DD": count } を返す。"""
        today = timezone.localdate()
        start = today - timedelta(days=29)
        logs = self._get_cached_logs(obj)
        return {
            str(log.date): log.count
            for log in logs
            if start <= log.date <= today
        }

    def get_checklist_items(self, obj):
        """チェックリスト項目を返す（count タイプは空リスト）。"""
        if obj.habit_type != 'checklist':
            return []
        return ChecklistItemSerializer(obj.checklist_items.all(), many=True).data

    def get_shield_active(self, obj):
        """今日ストリーク保護が有効かどうか。"""
        return obj.shield_date == timezone.localdate()

    # ── 【FEAT-520】reset_cycle / frequency を実際に機能させる 2 フィールド ──
    #
    # これまで `reset_cycle` は表示専用で、カウントの保存にも完了判定にも
    # 一切影響していなかった (BUG-34 で `period_progress.done` に繋いだが中身は
    # 「日数」、BUG-73 で `todayCount` に戻した際に「期間内の回数合計」を作らな
    # かったため実装が空のまま残っていた)。
    #
    # 役割を分離する:
    #   frequency   = やるべき頻度  → **完了判定の窓** (period_done)
    #   reset_cycle = カウンタの周期 → **バッジの集計窓** (period_count)
    #
    # 既存バリデーション `reset_cycle >= frequency` により「完了窓 ⊆ 集計窓」が
    # 常に成立する。

    def get_period_count(self, obj):
        """`reset_cycle` 期間内の `log.count` の合計を返す。

        「週に 10 回やった」を 10 として出すためのフィールド。
        既存の `period_progress.done` は **日数** なので別物 (§2.1)。
        """
        today = timezone.localdate()
        # ToDo は「1 回やって終わり」の単発タスクで期間集計の概念を持たない。
        cycle = 'daily' if obj.habit_type == 'todo' else obj.reset_cycle
        start = get_period_start(today, cycle)
        return sum(
            log.count for log in self._get_cached_logs(obj)
            if start <= log.date <= today
        )

    def get_period_done(self, obj):
        """`frequency` 期間内に `count > 0` の日が 1 日以上あるかを返す。

        `frequency='weekly'` の習慣を月曜に達成したら、その週いっぱい True。
        `frequency='daily'` (既存ユーザーの大多数) では
        `today_log.count > 0` と完全に一致するため **挙動は変わらない**。
        """
        today = timezone.localdate()
        freq = 'daily' if obj.habit_type == 'todo' else obj.frequency
        start = get_period_start(today, freq)
        return any(
            log.count > 0 for log in self._get_cached_logs(obj)
            if start <= log.date <= today
        )

    def get_period_progress(self, obj):
        """`frequency` < `reset_cycle` のときだけ、集計期間の**達成回数**進捗を返す。

        戻り値:
          `{ "done": int, "total": int, "elapsed": int,
             "label": str, "scope": str, "unit": str }`
          または **None**。

        `done` の単位は `frequency` (達成した日数 / 週数 / 月数) であり、
        **回数の合計ではない**。回数合計が欲しい場合は `period_count`
        (【FEAT-520】) を使うこと。両者は名前が似ていて中身が違う。

        | frequency | reset_cycle | done の単位 | total |
        |---|---|---|---|
        | daily   | weekly  | 達成日数   | 7 |
        | daily   | monthly | 達成日数   | その月の日数 |
        | daily   | yearly  | 達成日数   | 365 / 366 |
        | weekly  | monthly | 達成週数   | その月の月曜の数 |
        | weekly  | yearly  | 達成週数   | 52 |
        | monthly | yearly  | 達成月数   | 12 |

        **`frequency == reset_cycle` (daily+daily / weekly+weekly / monthly+monthly)
        では None を返す。** 集計期間 = 完了期間なので進捗という概念が立たない。

        > 【2026-08-06 / FEAT-520 §9】旧 docstring は daily+daily を
        > 「今日の count（done=count>0, total=1）」、weekly+weekly を
        > 「今週達成済みか」と説明していたが、実装は BUG-34 (2026-05-07) の時点から
        > 一貫して None を返しており、記述だけが乖離したまま残っていた。

        【FEAT-520 §4.5】`scope` / `unit` は表示文言を Flutter 側で組み立てるための
        構造化フィールド。`label` は日本語ハードコードで、英語 locale でもそのまま
        出てしまう (同 serializer の他フィールドは I18nFieldMixin で locale 対応済
        なのに、ここだけ FEAT-489 の網から漏れていた)。
        **`label` は旧アプリのために残す** (§4.2)。新アプリは `scope` + `unit` +
        `done` + `total` から ICU plural で組み立てる。
        """
        import calendar as _cal
        today  = timezone.localdate()
        freq   = obj.frequency
        cycle  = obj.reset_cycle
        logs   = self._get_cached_logs(obj)  # DB ヒットなし（prefetch 済み）

        # ── daily + weekly ────────────────────────────────────────────
        if freq == 'daily' and cycle == 'weekly':
            week_start = today - timedelta(days=today.weekday())  # 月曜
            done = sum(
                1 for log in logs
                if week_start <= log.date <= today and log.count > 0
            )
            total = 7
            elapsed = today.weekday() + 1  # 月=0 → 経過1日
            return {'done': done, 'total': total, 'elapsed': elapsed,
                    'label': f'今週 {done}/{total}日',
                    'scope': 'week', 'unit': 'day'}

        # ── daily + monthly ───────────────────────────────────────────
        if freq == 'daily' and cycle == 'monthly':
            month_start = today.replace(day=1)
            days_in_month = _cal.monthrange(today.year, today.month)[1]
            done = sum(
                1 for log in logs
                if month_start <= log.date <= today and log.count > 0
            )
            total = days_in_month
            return {'done': done, 'total': total, 'elapsed': today.day,
                    'label': f'今月 {done}/{total}日',
                    'scope': 'month', 'unit': 'day'}

        # ── daily + yearly ────────────────────────────────────────────
        if freq == 'daily' and cycle == 'yearly':
            year_start = today.replace(month=1, day=1)
            days_in_year = 366 if _cal.isleap(today.year) else 365
            done = sum(
                1 for log in logs
                if log.date <= today and log.count > 0
            )
            total = days_in_year
            elapsed = (today - year_start).days + 1
            return {'done': done, 'total': total, 'elapsed': elapsed,
                    'label': f'今年 {done}/{total}日',
                    'scope': 'year', 'unit': 'day'}

        # ── weekly + monthly ──────────────────────────────────────────
        if freq == 'weekly' and cycle == 'monthly':
            month_start = today.replace(day=1)
            # 今月に含まれる月曜日の数を weeks_in_month とする
            weeks_in_month = len([
                d for d in range(1, _cal.monthrange(today.year, today.month)[1] + 1)
                if date(today.year, today.month, d).weekday() == 0
                and date(today.year, today.month, d) <= today
            ])
            # 今月内で少なくとも1回達成した週の数（Python でフィルタリング）
            done_weeks = len(set(
                (log.date - timedelta(days=log.date.weekday())).isoformat()
                for log in logs
                if month_start <= log.date <= today and log.count > 0
            ))
            total_weeks = max(
                len([
                    d for d in range(1, _cal.monthrange(today.year, today.month)[1] + 1)
                    if date(today.year, today.month, d).weekday() == 0
                ]), 1
            )
            return {'done': done_weeks, 'total': total_weeks, 'elapsed': weeks_in_month,
                    'label': f'今月 {done_weeks}/{total_weeks}週',
                    'scope': 'month', 'unit': 'week'}

        # ── weekly + yearly ───────────────────────────────────────────
        if freq == 'weekly' and cycle == 'yearly':
            done_weeks = len(set(
                (log.date - timedelta(days=log.date.weekday())).isoformat()
                for log in logs
                if log.date <= today and log.count > 0
            ))
            elapsed_weeks = today.isocalendar()[1]
            total = 52
            return {'done': done_weeks, 'total': total, 'elapsed': elapsed_weeks,
                    'label': f'今年 {done_weeks}/{total}週',
                    'scope': 'year', 'unit': 'week'}

        # ── monthly + yearly ──────────────────────────────────────────
        if freq == 'monthly' and cycle == 'yearly':
            done_months = len(set(
                log.date.month
                for log in logs
                if log.date <= today and log.count > 0
            ))
            total = 12
            return {'done': done_months, 'total': total, 'elapsed': today.month,
                    'label': f'今年 {done_months}/{total}ヶ月',
                    'scope': 'year', 'unit': 'month'}

        # ── デフォルト（same as frequency）→ null を返す ──────────────
        return None


class CharacterStatSerializer(serializers.ModelSerializer):
    id = serializers.IntegerField(read_only=True)

    class Meta:
        model = CharacterStat
        fields = ['id', 'name', 'level', 'current_exp', 'max_exp']


class PlayerItemSerializer(serializers.ModelSerializer):
    class Meta:
        model  = PlayerItem
        fields = ['item_id', 'quantity', 'purchased_at']


# 【FEAT-518 (2026-08-05)】ガチャ排出確率の開示用 serializer。
# `weight` を生で返さず **正規化済みの probability (%)** を返す。ticket_type ごとに
# weight 合計が違う (Daily 100 / Weekly 200 / Monthly 100) ため、クライアント側で
# 割り算させると実装ミスで誤表示になるリスクがある。正規化はサーバー側で完結させる。
#
# `total_weight` は context 経由で受け取る (同じ ticket_type の pool 合計)。
class GachaOddsRewardSerializer(I18nFieldMixin, serializers.ModelSerializer):
    name        = serializers.SerializerMethodField()
    detail      = serializers.SerializerMethodField()
    probability = serializers.SerializerMethodField()

    class Meta:
        model  = GachaReward
        fields = ['name', 'detail', 'rarity', 'reward_type', 'icon', 'probability']

    def get_name(self, obj):
        return self.get_i18n(obj, 'name')

    def get_detail(self, obj):
        return self.get_i18n(obj, 'detail')

    def get_probability(self, obj):
        total = self.context.get('total_weight', 0)
        if not total:
            return 0.0
        return round(obj.weight / total * 100, 2)


# 【FEAT-299】ジョブマスタ serializer。
# `BattleStartView.player_job` は dict 直接生成のため直接の利用箇所はまだないが、
# CharacterSerializer にネスト埋め込むことでホーム / ガチャ / 設定画面で
# 「キャラ → ジョブ」表示の準備として配置。将来 `/api/jobs/` 一覧 API も検討。
class JobSerializer(I18nFieldMixin, serializers.ModelSerializer):
    # 【FEAT-489 Phase 2F-a】locale-aware な job_name (I18nFieldMixin 経由)。
    # `job_name_en` が空なら ja に silent fallback する。
    # `job_id` は Mobile の switch key なので **絶対に locale 依存にしない**。
    job_name = serializers.SerializerMethodField()
    # 【FEAT-516 (2026-08-04)】description が Phase 2F-a の対応から漏れていた。
    # 同じ model 内で job_name だけ英語 / description は日本語という状態だった。
    description = serializers.SerializerMethodField()

    class Meta:
        model  = Job
        fields = [
            'job_id', 'job_name',
            'atb_speed_modifier', 'attack_power_modifier',
            'on_hit_effect', 'ult_cost', 'description',
        ]

    def get_job_name(self, obj):
        return self.get_i18n(obj, 'job_name')

    def get_description(self, obj):
        return self.get_i18n(obj, 'description')


class CharacterSerializer(I18nFieldMixin, serializers.ModelSerializer):
    # 【FEAT-299】キャラに紐付くジョブをネスト表示（読み取り専用、null 許容）。
    # 既存 PlayerProfileSerializer.active_character の nested 経由でも自動的に
    # job が含まれるため、Flutter は `player.active_character.job` で参照可。
    job = JobSerializer(read_only=True)
    # 【2026-06-27】「NEW」バッジ算出 (release_date 設定済 + ≤ 今日 + 30 日以内)。
    # Mobile 側で日付計算する必要をなくして UI 描画を簡素化。
    is_new = serializers.SerializerMethodField()
    # 【FEAT-489 Phase 4】locale-aware fields (I18nFieldMixin 経由)。
    name        = serializers.SerializerMethodField()
    role        = serializers.SerializerMethodField()
    tagline     = serializers.SerializerMethodField()
    description = serializers.SerializerMethodField()

    class Meta:
        model  = Character
        fields = ['id', 'key', 'name', 'role', 'description', 'tagline',
                  'image_path', 'release_date', 'is_new',
                  'price', 'unlock_level', 'is_starter', 'order', 'job']

    def get_name(self, obj):        return self.get_i18n(obj, 'name')
    def get_role(self, obj):        return self.get_i18n(obj, 'role')
    def get_tagline(self, obj):     return self.get_i18n(obj, 'tagline')
    def get_description(self, obj): return self.get_i18n(obj, 'description')

    def get_is_new(self, obj):
        """release_date が直近 30 日以内 (≤ 今日) なら True。"""
        from datetime import timedelta
        from django.utils import timezone
        rd = obj.release_date
        if rd is None:
            return False
        today = timezone.localdate()
        if rd > today:
            return False  # 未来日設定 (公開前) は NEW 扱いしない
        return (today - rd).days <= 30


class PlayerProfileSerializer(serializers.ModelSerializer):
    id               = serializers.IntegerField(read_only=True)
    stats            = CharacterStatSerializer(many=True, read_only=True)
    active_character = CharacterSerializer(read_only=True)
    # 【FEAT-304】PartyEditDialog で表示する現在のアクティブジョブ（read_only、
    # 更新は PATCH /api/player/active-job/ で別経路）。null = 未選択 → 初期ジョブ。
    active_job       = JobSerializer(read_only=True)
    # BUG-2026-0512-01: HomeBootstrapView / HabitCountView 等で `player` 子オブジェクトに
    # `gacha_tickets` が含まれず、ホーム画面のチケットバッジが常に 0 表示になる片肺現象を
    # 解消するため、シリアライザ自体に組み込む（旧実装は PlayerProfileView.get でのみ
    # 後付け注入していた）。many=True での利用は無いため N+1 リスクなし。
    gacha_tickets    = serializers.SerializerMethodField()
    # 【FEAT-326】現在装備中の武器 (read_only、更新は PATCH /api/player/equip-weapon/)。
    # Flutter PartyEditDialog の装備スロット表示 + バトル damage 計算で参照される。
    # 未所持・未装備時は null (Flutter 側は default atk_bonus=10 フォールバック)。
    equipped_weapon  = serializers.SerializerMethodField()
    # 【FEAT-334 (2026-05-27)】legendary 難易度スロット情報 (read_only)。
    # Flutter add_habit_page / edit_habit_page で「伝説 (残 N/M)」表示 + 上限到達 disabled 用。
    # 計算ロジックは services/habit_slot_service.py が単一真実値。
    legendary_slots_total = serializers.SerializerMethodField()
    # 【FEAT-379 (2026-05-29)】結晶インベントリ (6 結晶累積カウンター、ネスト dict で返す)
    crystals = serializers.SerializerMethodField()
    legendary_slots_used  = serializers.SerializerMethodField()
    # 【BUG-78】日付が変わった後の stale 10/10 を UI に返さない。
    daily_battle_count = serializers.SerializerMethodField()

    # 【FEAT-478 Phase 2b (2026-07-04)】以下フィールドは PlayerBattleState /
    # PlayerEconomyState (proxy 経由 = `obj.battle` / `obj.economy`) から読む。
    # 旧 PlayerProfile field への直接アクセスは Phase 2b write path 側で既に
    # NEW state へ切替済のため、OLD field は stale 値のまま残っている。Serializer
    # のみ ModelSerializer 定義に依存 → OLD field 読み → Flutter に stale 値返却
    # で「習慣達成しても battle_charges が増えない / Lv が上がらない / ダイヤが増えない」
    # という UI 断絶バグが発生していたため、SerializerMethodField で NEW state を明示参照する。
    #
    # PlayerBattleState 経由 (レベル / EXP / バトル charges):
    level                             = serializers.SerializerMethodField()
    current_exp                       = serializers.SerializerMethodField()
    max_exp                           = serializers.SerializerMethodField()
    allocatable_points                = serializers.SerializerMethodField()
    battle_charges                    = serializers.SerializerMethodField()
    daily_exp_count                   = serializers.SerializerMethodField()
    daily_battle_limit_bonus          = serializers.SerializerMethodField()
    daily_battle_limit_purchase_count = serializers.SerializerMethodField()
    # PlayerEconomyState 経由 (ダイヤ / 交換券 / ストリーク保護 / XP boost):
    diamonds                          = serializers.SerializerMethodField()
    diamonds_total                    = serializers.SerializerMethodField()
    character_exchange_tickets        = serializers.SerializerMethodField()
    streak_protection_count           = serializers.SerializerMethodField()
    streak_protection_pending         = serializers.SerializerMethodField()
    xp_boost_active_until             = serializers.SerializerMethodField()

    # 【FEAT-478 Phase 2 最終 (2026-07-06)】書き込み可能フィールド (setattr shim で
    # 対応する State モデルに diverting される、__setattr__ 経由で自動処理)。
    # 明示 field 宣言 = DRF の model introspection をスキップし、model にない field でも扱える。
    all_private                            = serializers.BooleanField(required=False)
    fcm_token                              = serializers.CharField(required=False, allow_blank=True, default='')
    reminder_enabled                       = serializers.BooleanField(required=False)
    reminder_time                          = serializers.TimeField(required=False, allow_null=True)
    mode                                   = serializers.CharField(required=False, max_length=10)
    gcal_push_enabled                      = serializers.BooleanField(required=False)
    timeline_uncompleted_reminder_enabled  = serializers.BooleanField(required=False)
    streak_protection_auto_enabled         = serializers.BooleanField(required=False)
    # 【FEAT-489 Phase 4】優先言語 (ja/en)。PATCH /api/player/ で設定変更可。
    preferred_language                     = serializers.ChoiceField(
        choices=[('ja', '日本語'), ('en', 'English')], required=False,
    )
    # 【FEAT-434 で廃止された dead field】backward-compat のため 0 固定で返却。
    legendary_slots_purchase_count = serializers.SerializerMethodField()

    class Meta:
        model = PlayerProfile
        fields = [
            'id', 'name', 'level', 'current_exp', 'max_exp',
            'allocatable_points', 'gender', 'stats',
            'diamonds', 'diamonds_total',
            'friend_id', 'all_private',
            'active_character',
            # 【FEAT-304】PartyEditDialog で参照する current active job
            'active_job',
            'created_at',
            'fcm_token',
            'reminder_enabled',
            'reminder_time',
            'mode',
            'exchange_pieces',
            'gacha_tickets',
            # 【FEAT-257】Google カレンダー push トグル（Settings で更新可能）
            'gcal_push_enabled',
            # 【FEAT-273】タイムライン予定の +15 分未完了リマインダー（Settings で更新可能）
            'timeline_uncompleted_reminder_enabled',
            # 【FEAT-295】バトル出陣チケット蓄積数 (read-only、HabitCountView で +1、BattleFinishView で -3)
            'battle_charges',
            # 【FEAT-326】PartyEditDialog 装備変更 + バトル damage 計算用
            'equipped_weapon',
            # 【FEAT-334】Legend 難易度スロット (Flutter add/edit habit page で表示)
            'legendary_slots_total',
            'legendary_slots_used',
            # 【FEAT-377】ストリーク保護 (Settings / Home 画面で表示・制御)
            'streak_protection_count',
            'streak_protection_auto_enabled',
            # 【FEAT-420】予約モード: 翌日判定待ちフラグ (Settings で表示・取消可能)
            'streak_protection_pending',
            # 【FEAT-379】結晶インベントリ (SerializerMethodField)
            'crystals',
            # 【FEAT-398】日次スロットル状態 (Flutter 側で UI 表示 / Badge 判定用)
            'daily_exp_count',
            'daily_battle_count',
            # 【FEAT-427】マンスリー天井で配布されるキャラ交換券の在庫
            'character_exchange_tickets',
            # 【FEAT-429】Shop 累進価格 (Legendary 枠拡張 / クエスト枠拡張)
            'legendary_slots_purchase_count',
            'daily_battle_limit_bonus',
            'daily_battle_limit_purchase_count',
            # 【FEAT-318 (2026-06-13 再活性化)】XP ブースト有効期限 (Flutter で残り時間表示用)
            'xp_boost_active_until',
            # 【FEAT-493 (2026-07-25 hotfix)】フリーメモ機能 opt-in flag。
            # Meta.fields に未追記だと GET でも返らず、Flutter re-fetch 時に
            # freeMemoEnabled=false で塗り替えられて toggle が OFF に戻る不具合を修正。
            'free_memo_enabled',
            # 【FEAT-489 Phase 4】優先言語 (PATCH /api/player/ で設定変更可)
            'preferred_language',
        ]
        # 【SEC-13 C-01】mass-assignment 防御の backstop。
        # 経済・成長・進行系フィールドは PATCH /api/player/ では更新不可とし、
        # 専用エンドポイント (StatAllocateView / HabitCountView / GachaPullView /
        # BattleFinishView 等) 経由でしか変動しないことを保証する。
        # ※ id / stats / active_character / active_job / gacha_tickets / equipped_weapon は
        #   既に class 属性で `read_only=True` 宣言済みのため、DRF の仕様上ここに
        #   含めるとアサーションエラーになる。明示宣言が真実値。
        read_only_fields = [
            'level', 'current_exp', 'max_exp',
            'allocatable_points',
            'diamonds', 'diamonds_total',
            'friend_id',
            'created_at',
            'exchange_pieces',
            'battle_charges',
            # 【FEAT-398】日次スロットルカウンタは専用 view でのみ更新
            'daily_exp_count',
            'daily_battle_count',
            # 【FEAT-427】GachaPullView (天井) / CharacterExchangeView でのみ増減
            'character_exchange_tickets',
            # 【FEAT-429】ShopPurchaseView でのみ増減
            'legendary_slots_purchase_count',
            'daily_battle_limit_bonus',
            'daily_battle_limit_purchase_count',
            # 【FEAT-318 (2026-06-13 再活性化)】UseXpBoostView でのみ更新
            'xp_boost_active_until',
        ]

    def get_gacha_tickets(self, obj):
        # ローカルインポートで循環参照を回避（PlayerGachaStatus は models 内）。
        from .models import PlayerGachaStatus
        status_obj, _ = PlayerGachaStatus.objects.get_or_create(player=obj)
        return {
            'daily':   status_obj.daily_tickets,
            'weekly':  status_obj.weekly_tickets,
            'monthly': status_obj.monthly_tickets,
        }

    def get_daily_battle_count(self, obj):
        return current_daily_battle_count(obj)

    # ── 【FEAT-478 Phase 2b (2026-07-04)】split state 経由の getter 群 ──────────
    # write path は既に NEW state (PlayerBattleState / PlayerEconomyState) に
    # 書き換え済 (habit_count_service / battle.py 等)、read path (本 Serializer)
    # だけ ModelSerializer 定義のまま OLD field を読んでいたバグを解消する。
    # obj.battle / obj.economy は @property で get_or_create 済 (未作成なら OLD
    # field 値で初期化)、null 不安全な直接属性アクセスは常に安全。

    def get_level(self, obj):
        return obj.battle.level

    def get_current_exp(self, obj):
        return obj.battle.current_exp

    def get_max_exp(self, obj):
        return obj.battle.max_exp

    def get_allocatable_points(self, obj):
        return obj.battle.allocatable_points

    def get_battle_charges(self, obj):
        return obj.battle.battle_charges

    def get_daily_exp_count(self, obj):
        return obj.battle.daily_exp_count

    def get_daily_battle_limit_bonus(self, obj):
        return obj.battle.daily_battle_limit_bonus

    def get_daily_battle_limit_purchase_count(self, obj):
        return obj.battle.daily_battle_limit_purchase_count

    def get_diamonds(self, obj):
        return obj.economy.diamonds

    def get_diamonds_total(self, obj):
        return obj.economy.diamonds_total

    def get_character_exchange_tickets(self, obj):
        return obj.economy.character_exchange_tickets

    def get_streak_protection_count(self, obj):
        return obj.economy.streak_protection_count

    def get_streak_protection_pending(self, obj):
        return obj.economy.streak_protection_pending

    def get_xp_boost_active_until(self, obj):
        return obj.economy.xp_boost_active_until

    def get_legendary_slots_purchase_count(self, obj):
        # 【FEAT-434 で廃止】backward-compat: 常に 0 を返却。
        return 0

    def update(self, instance, validated_data):
        """【FEAT-372 (2026-05-28)】BUG-74 構造解消: gcal_push_enabled True→False
        遷移時に、既存 pending_google_push=True 予定を False に reconcile する。

        これにより Flutter `retryPendingPushes()` が Backend の
        `?pending_google_push=true` で取得できる遺残対象が構造的にゼロになる。
        Flutter 側 defense-in-depth (Phase 3) と合わせ二重防御を形成する。

        Pre-mortem #2: 冪等 PATCH（False→False）での無駄な UPDATE を防ぐため、
        `old_value != new_value and new_value == False` の遷移のみ reconcile を発火。
        """
        old_gcal_push = instance.gcal_push_enabled
        new_gcal_push = validated_data.get('gcal_push_enabled', old_gcal_push)

        result = super().update(instance, validated_data)

        # True → False 遷移のみ reconcile (冪等 PATCH での無駄な UPDATE を防ぐ)
        if old_gcal_push and not new_gcal_push:
            from api.models import TimelineEvent
            import logging
            logger = logging.getLogger(__name__)
            updated_count = TimelineEvent.objects.filter(
                player=instance,
                pending_google_push=True,
            ).update(pending_google_push=False)
            logger.info(
                '[FEAT-372] gcal_push_enabled True→False reconcile: '
                f'player_id={instance.id} updated_count={updated_count}',
            )

        return result

    def get_legendary_slots_total(self, obj):
        """【FEAT-334 + FEAT-375、FEAT-434 (2026-06-14) で全廃】legendary 習慣の許容上限。

        【FEAT-434】Habit 難易度廃止に伴い `calc_legendary_slots` は常に 0 を返す。
        `legendary_slots_bonus` も migration 0136 で既存購入者を返金 + 0 リセット済の
        ため、本メソッドは実質常に 0 を返す (= Legendary 不可)。フィールド自体は
        互換性のため維持。
        """
        from .services.habit_slot_service import calc_legendary_slots
        base  = calc_legendary_slots(obj)
        bonus = getattr(obj, 'legendary_slots_bonus', 0) or 0
        return base + bonus

    def get_legendary_slots_used(self, obj):
        """【FEAT-334】現在 active な legendary 習慣数 (上限カウンタ用)。"""
        from .services.habit_slot_service import count_active_legendary
        return count_active_legendary(obj)

    def get_equipped_weapon(self, obj):
        """【FEAT-326】 PlayerWeapon.is_equipped=True の武器情報を返す (or None)。

        Backend では damage 計算自体は Flutter 側 BattleOrchestrator が担うため
        本フィールドは「Flutter 側のクライアント計算用」のソース of truth。
        未装備 (オンボーディング直後の極端ケース) は None、Flutter は
        `Player.equippedWeapon?.atkBonus ?? 10` で starter フォールバック。
        """
        from .models import PlayerWeapon
        # is_equipped=True を 1 件取得 (1 人 1 武器の不変条件、EquipWeaponView で担保)
        pw = (
            PlayerWeapon.objects
            .filter(player=obj, is_equipped=True)
            .select_related('weapon')
            .first()
        )
        if pw is None:
            return None
        return {
            'id':           pw.weapon.id,
            'key':          pw.weapon.key,
            'name':         pw.weapon.name,
            'atk_bonus':    pw.weapon.atk_bonus,
            # 【FEAT-379】ソケット数 (v1.0 は固定値、v1.1+ で Lv 連動)
            'socket_count': pw.weapon.socket_count,
        }

    def get_crystals(self, obj):
        """【FEAT-379 (2026-05-29)】6 結晶累積カウンターを nest dict で返す。

        キーは CATEGORY_STAT_MAP 英語キーと完全整合。Flutter 側は `Player.crystals.exercise` 等で参照。
        """
        return {
            'exercise':     getattr(obj, 'exercise_crystal_count', 0) or 0,
            'learning':     getattr(obj, 'learning_crystal_count', 0) or 0,
            'health':       getattr(obj, 'health_crystal_count', 0) or 0,
            'mental':       getattr(obj, 'mental_crystal_count', 0) or 0,
            'creation':     getattr(obj, 'creation_crystal_count', 0) or 0,
            'contribution': getattr(obj, 'contribution_crystal_count', 0) or 0,
        }


class FriendPlayerSerializer(serializers.ModelSerializer):
    """フレンドリスト・プロフィール用の軽量シリアライザ"""
    public_habits = serializers.SerializerMethodField()
    best_streak   = serializers.SerializerMethodField()
    monthly_rate  = serializers.SerializerMethodField()
    # 【BUG-100 (2026-06-14)】フレンド検索 / プロフィール表示で設定キャラ画像を
    # 出すための軽量フィールド。CharacterSerializer 全フィールドは出さず
    # (privacy + payload 最小化)、key / name / image_path のみ。
    # CharacterAsset.circleWidget(identifier=image_path, keyFallback=key) が動く最小集合。
    active_character = serializers.SerializerMethodField()
    # 【2026-06-27】フレンドプロフィール画面のステータスカード表示用。6 stat
    # (運動 / 学習 / 健康 / 精神 / 創造 / 貢献) の Lv + currentExp + maxExp を返す。
    # FEAT-396「習慣内容は非公開」原則との整合: ステータスは集計値で個別行動が
    # 推察できないため公開可。フレンド機能の「成長を共有する」モチベ源を強化。
    stats = serializers.SerializerMethodField()

    # 【FEAT-478 Phase 2b hotfix (2026-07-05、codebase_review 20260704 P1-新)】
    # PlayerProfile.level (旧 field) は Phase 2b 以降どこからも書き込まれない孤立
    # フィールドになったため、`SerializerMethodField` で NEW state (`obj.battle.level`)
    # を参照する。PlayerProfileSerializer は同じ理由で既に 14 フィールドを Method
    # Field 化済 (前 hotfix commit d28841d) だったが、FriendPlayerSerializer は
    # 対応範囲から漏れており、フレンドから見えるレベルが Phase 2b デプロイ時点で
    # 凍結される「成長を共有する」設計哲学に反する状態になっていた。
    level = serializers.SerializerMethodField()

    class Meta:
        model  = PlayerProfile
        fields = ['id', 'name', 'level', 'friend_id', 'public_habits',
                  'best_streak', 'monthly_rate', 'active_character', 'stats']

    def get_level(self, obj):
        """【FEAT-478 Phase 2b】PlayerBattleState (NEW state proxy) から読む。"""
        return obj.battle.level

    def get_active_character(self, obj):
        char = obj.active_character
        if not char:
            return None
        return {
            'key': char.key,
            'name': char.name,
            'image_path': char.image_path,
        }

    def get_stats(self, obj):
        """【2026-06-27】6 ステータス (Mobile StatusOverviewCard 表示用)。
        CharacterStat は player 単位で 6 行存在。`order_by('pk')` で安定順序を保証
        (Mobile 側は CharacterStat.name で並び替えるため順序非依存だが、Backend の
        慣例として pk 順)。Mobile CharacterStat.fromJson と完全一致するフィールド構成
        (id / name / level / current_exp / max_exp)。
        """
        from .models import CharacterStat
        stats = CharacterStat.objects.filter(player=obj).order_by('pk')
        return CharacterStatSerializer(stats, many=True).data

    def _get_active_habits(self, obj):
        """FriendListView が Prefetch(to_attr='active_habits_list') を設定済みならそれを使う。
        未設定時（FriendProfileView など）は DB を直接クエリ（N+1 は発生するが単件なので許容）。
        BUG-06: フレンドリスト画面での N+1 クエリを解消。
        """
        prefetched = getattr(obj, 'active_habits_list', None)
        if prefetched is not None:
            return prefetched
        return list(obj.habits.filter(is_active=True))

    def get_public_habits(self, obj):
        """【FEAT-396 (2026-05-31)】習慣の内容は常に非公開固定。
        旧: all_private=False のとき habit リスト返却、is_public=True のものだけ
        新: 常に空 list (フレンドには習慣の内容を一切共有しない)。
        理由: Sabi プロダクトミッション「自分を肯定してくれる静かな聖域」と整合、
        ユーザーの「自分の習慣内容が他人に見えてる?」という疑惑を構造的にゼロ化。
        フレンド機能のモチベーション源は best_streak (継続日数) のみで担保する。
        """
        return []

    def get_best_streak(self, obj):
        """【FEAT-396 (2026-05-31)】継続日数は常に公開 (フレンド機能の唯一のモチベーション源)。
        旧: all_private=True のとき 0 返却 = all-or-nothing で streak も消えていた
        新: all_private 無視で常に実値を返す (継続日数はモチベーション源として公開、
        習慣の中身は get_public_habits で常に非公開化済)。
        """
        habits = self._get_active_habits(obj)
        return max((h.best_streak for h in habits), default=0)

    def get_monthly_rate(self, obj):
        """【FEAT-396 (2026-05-31)】月間達成率は常に非公開固定 (案 D-1)。
        旧: all_private=False のとき計算結果を返却
        新: 常に 0 (率からの内容推察 = 「30% = 飽きやすい習慣?」を防ぐため)。
        get_public_habits の「内容隠す」哲学と一貫させる。
        """
        return 0


class FriendshipSerializer(serializers.ModelSerializer):
    friend = serializers.SerializerMethodField()

    class Meta:
        model  = Friendship
        fields = ['id', 'status', 'created_at', 'friend']

    def get_friend(self, obj):
        current = self.context.get('current_player')
        other = obj.to_player if obj.from_player == current else obj.from_player
        return FriendPlayerSerializer(other).data


# 【FEAT-446 (2026-06-20)】MessageSerializer 削除: フレンド間メッセージ機能廃止に伴う。
# Message モデル本体は residual data 保全のため残置 (FEAT-250 反省遵守)。


class AchievementSerializer(I18nFieldMixin, serializers.ModelSerializer):
    unlocked    = serializers.SerializerMethodField()
    is_claimed  = serializers.SerializerMethodField()
    unlocked_at = serializers.SerializerMethodField()
    # 【FEAT-516 (2026-08-04)】locale-aware fields。`key` は Mobile の識別子なので
    # **絶対に locale 依存にしない** (CharacterSerializer / JobSerializer と同規律)。
    name        = serializers.SerializerMethodField()
    description = serializers.SerializerMethodField()

    class Meta:
        model  = Achievement
        fields = [
            'id', 'key', 'name', 'description', 'icon',
            'condition_type', 'condition_value', 'reward_diamonds',
            'unlocked', 'is_claimed', 'unlocked_at',
        ]

    def get_name(self, obj):        return self.get_i18n(obj, 'name')
    def get_description(self, obj): return self.get_i18n(obj, 'description')

    def get_unlocked(self, obj):
        player_achievements = self.context.get('player_achievements')
        if player_achievements is not None:
            return obj.id in player_achievements
        # フォールバック（player_achievements が渡されない場合）
        player = self.context.get('player')
        if not player:
            return False
        return PlayerAchievement.objects.filter(player=player, achievement=obj).exists()

    def get_is_claimed(self, obj):
        player_achievements = self.context.get('player_achievements')
        if player_achievements is not None:
            pa = player_achievements.get(obj.id)
            return pa.is_claimed if pa else False
        # フォールバック
        player = self.context.get('player')
        if not player:
            return False
        pa = PlayerAchievement.objects.filter(player=player, achievement=obj).first()
        return pa.is_claimed if pa else False

    def get_unlocked_at(self, obj):
        player_achievements = self.context.get('player_achievements')
        if player_achievements is not None:
            pa = player_achievements.get(obj.id)
            return pa.unlocked_at.isoformat() if pa and pa.unlocked_at else None
        # フォールバック
        player = self.context.get('player')
        if not player:
            return None
        pa = PlayerAchievement.objects.filter(player=player, achievement=obj).first()
        return pa.unlocked_at.isoformat() if pa else None


class TimelineEventSerializer(serializers.ModelSerializer):
    class Meta:
        model  = TimelineEvent
        fields = [
            'id', 'title', 'date', 'start_time', 'end_time',
            'category', 'icon_key', 'memo', 'habit', 'is_completed', 'created_at',
            # BUG-17: 外部カレンダー対応
            'source', 'external_id',
            # 【FEAT-244】Sabiowl → Google push 時に保存される Google 側イベント ID。
            # PATCH /timeline/<pk>/ では更新できず、専用 TimelineGoogleLinkView 経由のみ。
            'google_event_id',
            # 【FEAT-255】同期 timestamp 比較用（read-only）。
            # `updated_at` は auto_now で自動更新、`last_synced_at` は push / 取り込み
            # ロジックが明示書き込みする。
            'updated_at', 'last_synced_at',
            # 【FEAT-256】Google への push 未完了フラグ。pending=True の予定が
            # 起動時 auto-retry / 手動同期の対象になる。
            'pending_google_push',
        ]
        # is_completed は POST /timeline/<pk>/complete/ 経由のみで更新可能
        # source は 'local' 固定（ExternalCalendarImportView のみ google/apple を許可）
        # google_event_id は TimelineGoogleLinkView 経由のみで更新可能（FEAT-244）
        # updated_at / last_synced_at / pending_google_push は内部管理（FEAT-255/256）
        read_only_fields = [
            'id', 'created_at', 'external_id', 'is_completed', 'source',
            'google_event_id',
            'updated_at', 'last_synced_at', 'pending_google_push',
        ]

    def validate_habit(self, value):
        """habit が現在のリクエストユーザー所有か検証する"""
        request = self.context.get('request')
        if value is None or request is None:
            return value
        if value.player_id != request.user.player_profile.id:
            raise serializers.ValidationError('指定された habit は所有していません')
        return value


class GoogleEventCompletionSerializer(serializers.ModelSerializer):
    """【FEAT-426】Google カレンダー予定の完了状態（Multi-device 同期用）。

    本文 (title/start_time/memo) は Mobile ローカル DB のみに保存されるため、
    本シリアライザは completion フラグ + メタデータのみを返す。
    """
    class Meta:
        model  = GoogleEventCompletion
        fields = [
            'google_event_id', 'event_date', 'is_completed',
            'on_time_bonus_awarded', 'completed_at', 'updated_at',
        ]





class TaskSuggestionSerializer(I18nFieldMixin, serializers.ModelSerializer):
    """【FEAT-467 (2026-07-02)】タスク候補 (タイトル入力 popup の選択肢) を返す。
    【FEAT-489 Phase 4】title / hint を locale-aware に。
    """
    title = serializers.SerializerMethodField()
    hint  = serializers.SerializerMethodField()

    class Meta:
        model  = TaskSuggestion
        fields = ['id', 'type', 'title', 'category', 'emoji', 'hint', 'order']

    def get_title(self, obj): return self.get_i18n(obj, 'title')
    def get_hint(self, obj):  return self.get_i18n(obj, 'hint')


