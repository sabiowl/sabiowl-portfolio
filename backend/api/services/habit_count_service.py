"""【FEAT-289】HabitCountView / ChecklistItemToggleView 中央化 service。

過去 4 ヶ月で 5 件のバグ起源 (FEAT-229 / FEAT-239 / BUG-A / BUG-2026-0512-02 /
BUG-K) になっていた 2 view の対称コピーを構造解決する単一エントリポイント。
両 view から `apply_count_change(player, habit, delta, is_checklist=...)` を
呼び、戻り値の `CountChangeResult` から view-specific レスポンス Map を組み立てる。

設計判断:
    - **単一エントリポイント**: `is_checklist` フラグで差分を吸収。
      checklist 経路は comeback / auto_shield / streak_diamond / HabitRewardLog を
      スキップ (BUG-K で「機能差は意図的」と確認済の現状を保持)。
      battle_charges のみ【BUG-96 (2026-06-12)】で count 経路と完全同等加算に変更
      (旧 FEAT-289 の「checklist は battle_charges もスキップ」は撤回済み)。
      timeline_event 連動 (FEAT-295 hotfix の TimelineCompleteView 経由) は
      本 service の対象外 (FEAT-289 Pre-mortem #3 で scope 明示)。
    - **rendezvous order**: CLAUDE.md「`select_for_update` のレンデブー順序統一」
      遵守。`PlayerProfile → Habit → HabitLog` の確定的順序で 3 ロックを一括取得し、
      後段で重複ロックを取らない (FEAT-229 + FEAT-239 の確定形)。
    - **冪等性**: minus 経路で log が無い / count=0 の場合は no_op=True で
      早期 return (旧 BUG-2026-01 の minus 連打データ破壊を解消済)。
    - **対称性**: plus の `+= delta_exp`, minus の `-= delta_exp` を構造的に
      対称化 (BUG-A の EXP 増殖を契約テストで縛る)。

関連: `doc/instructions/FEAT-289_habit_count_service_extraction.md`
"""
from dataclasses import dataclass, field
from datetime import date as date_t, timedelta
from typing import Optional

from django.db import transaction
from django.db.models import F
from django.db.models.functions import Greatest
from django.utils import timezone

from ..constants import GameBalance
from ..models import Habit, HabitLog, HabitRewardLog, PlayerProfile, RestDay
from .challenge_progress_service import increment_challenge_progress  # 【FEAT-465】
from .daily_throttle_service import (  # 【FEAT-398 / FEAT-406】
    apply_daily_exp_throttle,
    reset_battle_charges_if_new_day,
)
from .posthog_capture import capture_for_player  # 【FEAT-408】EXP スロットル計測
from .diamond_service import award_diamond_for_streak_7days  # 【FEAT-314】
from .exp_service import (
    apply_xp_boost_if_active,  # 【FEAT-318 (2026-06-13 再活性化)】
    award_diamond_if_first_today,
    calc_exp_gain,
    calc_stat_bonus_exp,
)


def calc_habit_base_exp(habit: Habit) -> int:
    """【FEAT-434 (2026-06-14)】Habit (count/checklist) の基本 EXP 計算。

    旧 `EXP_PER_COUNT * DIFFICULTY_MULTIPLIER` (難易度倍率方式) を廃止し、
    継続日数 (`habit.streak`) ベースの継続ボーナス方式に置換する。

    式: `10 + (habit.streak // 30) * 3`、上限 46 (365 日継続、30 日 step × 12)。
    難易度フィールド (`difficulty`) は本関数で参照しない (v1.0 で Habit の難易度
    UI は非表示化、field 自体は維持して v1.1+ の再利用余地を残す)。ToDo
    (`habit_type == 'todo'`) は引き続き既存の `calc_exp_gain` (難易度倍率方式)
    を使う。

    Args:
        habit: Habit インスタンス (`.streak` field を参照)
    Returns:
        int: 獲得 EXP (10〜46)
    """
    base = 10
    bonus_steps = min(habit.streak // 30, 12)  # 365 日 = 12 step (12*30=360) で上限
    return base + bonus_steps * 3  # 最大 10 + 36 = 46


# ─────────────────────────────────────────────────────────────────────────────
# 戻り値データクラス
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class CountChangeResult:
    """`apply_count_change` の戻り値。view 側でレスポンス Map にマップする。

    フィールドはすべて plus / minus / no_op の全経路を網羅し、各経路で意味のない
    フィールドは 0 / False / None / {} の安全 default を返す (view 側の defensive
    アクセス簡略化)。
    """

    # ── 共通 ──────────────────────────────────────────────────────────
    no_op: bool = False                # minus が log 不在 / count=0 で早期 return した
    exp_gain: int = 0                  # base EXP (plus 時のみ正値、minus 時 0)
    bonus_exp: int = 0                 # bonus EXP (plus 時のみ正値、minus 時 0、レスポンス表示用)
    old_level: int = 0
    new_level: int = 0
    leveled_up: bool = False
    auto_allocations: dict = field(default_factory=dict)  # {stat_name: pts}

    # ── plus 経路のみ意味あり ─────────────────────────────────────────
    diamond_earned: bool = False       # 当日初の習慣達成 +1 ダイヤ (`award_diamond_if_first_today`)
    is_comeback: bool = False          # 手動休息日明けの達成 (count 経路のみ True 可能性)
    auto_shield_type: Optional[str] = None  # 'fruit' or None (count 経路のみ可能性)
    streak_diamond_days: Optional[int] = None  # 【FEAT-314】 7 倍数達成時のみ (count 経路のみ)
    # 【FEAT-377】ストリーク保護発動フラグ (count 経路 + 自動保護 ON + 在庫あり のときのみ True)
    streak_protected: bool = False
    # 【FEAT-420】予約 (streak_protection_pending) からの保護発動で True
    # (streak_protected も同時に True になる。SnackBar 文言の出し分け用)
    streak_protection_pending_consumed: bool = False
    # 【FEAT-420】予約消費時のメッセージ (Flutter SnackBar 表示用、非消費時は None)
    streak_protection_message: Optional[str] = None
    # 【FEAT-379】今回付与した結晶 {crystal_key: count} (例: {'exercise': 1})
    crystals_awarded: dict = field(default_factory=dict)
    # 【FEAT-398】今回の達成で初めて日次 EXP 閾値 (25 件) に達した場合 True
    # Flutter 側で サビ口調 SnackBar を 1 日 1 回表示するためのシグナル
    daily_throttle_triggered: bool = False
    # 【FEAT-433】今回の達成で当月 21 日目の達成日になり SSR 確定チケットを
    # 配布した場合のみ True (count / checklist 両経路で判定)
    monthly_ticket_awarded: bool = False
    # 【BUG-122 (2026-06-14)】その日初回タスク達成ボーナス。
    # {amount, days_count, granted_daily_tickets, granted_weekly_tickets} or None
    # None = 当日既処理 or エラー (Mobile 側で演出表示しない)
    today_login_bonus: Optional[dict] = None
    # 【FEAT-452 (2026-06-20)】フレンドプレゼント popup 候補。
    # 当日 3 回目のタスク達成 + 対象フレンドあり時のみ非 None。
    # {id, name, level, friend_id, active_character_image_path, active_character_key}
    friend_gift_candidate: Optional[dict] = None
    # 【FEAT-479 (2026-07-06)】その日初回タスク達成でパズルピース (grey) 付与時のみ非 None。
    # {piece_index, new_state=1, scene_key}
    puzzle_piece_awarded: Optional[dict] = None

    # ── 内部状態 (view が log_count_after 等を使う場合の参考値) ────────
    log_count_after: int = 0           # apply 後の log.count


# ─────────────────────────────────────────────────────────────────────────────
# 内部ヘルパー
# ─────────────────────────────────────────────────────────────────────────────


def _lock_player_habit_log(player_pk: int, habit_pk: int, today: date_t):
    """rendezvous order: PlayerProfile → Habit → HabitLog の確定的順序でロック取得。

    Returns: (player, habit, log)  log は None 可 (今日のログがまだ無い場合)。
    呼び出し側で transaction.atomic() 配下である前提。
    """
    player = PlayerProfile.objects.select_for_update().get(pk=player_pk)
    habit = Habit.objects.select_for_update().get(pk=habit_pk)
    log = (
        HabitLog.objects
        .select_for_update()
        .filter(habit=habit, date=today)
        .first()
    )
    return player, habit, log


def _ensure_log(habit: Habit, today: date_t) -> HabitLog:
    """ロック付きで今日の HabitLog を取得 or 新規作成して返す。
    既存ロック取得が None だった場合の確実な upsert 経路。
    """
    log, _created = HabitLog.objects.get_or_create(habit=habit, date=today)
    return HabitLog.objects.select_for_update().get(pk=log.pk)


def _compute_streak_on_first_done(
    player: PlayerProfile,
    habit: Habit,
    today: date_t,
    *,
    allow_auto_shield: bool,
) -> tuple[int, int, bool, Optional[str], bool, bool, Optional[str]]:
    """was_zero (今日初回達成) かつ habit_type != 'todo' のときに呼ぶ。

    Returns: (new_streak, new_best, is_comeback, auto_shield_type, streak_protected,
              streak_protection_pending_consumed, streak_protection_message)

    `allow_auto_shield=False` (checklist 経路) は yesterday_done / yesterday_rest
    の判定のみ行う。

    Note: player は呼び出し側で select_for_update 済み前提 (再ロックしない)。
    【FEAT-424 (2026-06-11)】休息の果実 + 休息日機能廃止に伴い、果実自動消費 +
    RestDay 自動作成ロジックは撤去済み。RestDay テーブルは既存データ (手動設定分)
    の参照用に残置 (yesterday_rest 判定のみ)。
    """
    yesterday = today - timedelta(days=1)

    # 昨日「この習慣」を達成していたか (既存ロジック)
    this_habit_done_yesterday = HabitLog.objects.filter(
        habit=habit, date=yesterday, count__gt=0,
    ).exists()
    # 昨日「プレイヤーのいずれかの習慣・ToDo」を達成していたか
    any_activity_yesterday = HabitLog.objects.filter(
        habit__player=player, date=yesterday, count__gt=0,
    ).exists()
    yesterday_done = this_habit_done_yesterday or any_activity_yesterday
    yesterday_rest = RestDay.objects.filter(
        player=player, date=yesterday,
    ).exists()
    was_manually_rest = yesterday_rest  # comeback 判定用 (手動設定分のみ)

    auto_shield_type: Optional[str] = None

    new_streak = (habit.streak + 1) if (yesterday_done or yesterday_rest) else 1
    new_best = max(new_streak, habit.best_streak)
    # is_comeback は手動設定の休息日の翌日達成のみ (自動シールドは除く)
    is_comeback = (not yesterday_done) and was_manually_rest and allow_auto_shield

    # 【FEAT-377 (2026-05-29)】ストリーク自動保護:
    # count 経路 (allow_auto_shield=True) で streak が途切れる (new_streak==1) かつ
    # 保護する価値のある streak があり (habit.streak > 0) かつ
    # 自動保護 ON + 在庫あり + 当日未使用 → streak 維持 (リセットしない)。
    #
    # Pre-mortem #1 保護: award_diamond_for_streak_7days は new_streak の 7 倍数チェックを
    # 行うため、保護後の new_streak が 7 の倍数でなければ発火しない。冪等担保も維持。
    # Pre-mortem #2 保護: login_streak_days には一切触れないため完全独立。
    streak_protected = False
    eco = player.economy  # 【FEAT-478 Phase 2b】economy フィールドを一括取得
    # 【BUG-85 (2026-06-10)】1 個のストリーク石で同日に途切れた全 habit を保護する仕様。
    # 旧実装は `last_streak_protection_used_at != today` の条件で当日 2 つ目以降の
    # 保護を弾いていたため、複数の習慣を持つユーザーが「同日に石を 1 個消費したのに
    # 1 つの habit しか守られなかった」という不公平を感じていた (ユーザー報告 2026-06-10)。
    #
    # 新仕様:
    #   - 当日初回保護    → 在庫 1 消費 + フラグを today にマーク (旧仕様と同等)
    #   - 当日 2 回目以降 → 在庫消費なしで保護のみ発動 (フラグは today のまま)
    #
    # 結果として「1 石 = 1 日全 habit 保護」となり、ユーザーが複数習慣を持っていても
    # 公平にカバーされる。日次冪等 (= 翌日には新たに 1 個必要) の性質は維持。
    if (
        allow_auto_shield  # count 経路のみ (checklist は streak 保護対象外)
        and new_streak == 1
        and habit.streak > 0  # 保護する価値のある streak があった
        and eco.streak_protection_auto_enabled
    ):
        today_already_used = eco.last_streak_protection_used_at == today
        has_stock = (eco.streak_protection_count or 0) > 0

        if today_already_used:
            # 今日の最初の habit で既に石消費済 → 追加消費なしで保護発動 (BUG-85)
            new_streak = habit.streak + 1
            new_best = max(new_streak, habit.best_streak)
            streak_protected = True
        elif has_stock:
            # 今日初回 → 在庫 1 消費 + フラグ today (旧仕様と同等)
            new_streak = habit.streak + 1
            new_best = max(new_streak, habit.best_streak)
            eco.streak_protection_count = max(0, eco.streak_protection_count - 1)
            eco.last_streak_protection_used_at = today
            eco.save(update_fields=['streak_protection_count', 'last_streak_protection_used_at'])
            streak_protected = True

    # 【FEAT-420 (2026-06-10)】予約モード「翌日判定」:
    # 自動保護 ON のときは pending 経路を無視 (自動が優先、二重消費防止)。
    # pending=True の場合のみ、当日の達成結果を見て「消費」or「リセット」を判定する。
    streak_protection_pending_consumed = False
    streak_protection_message: Optional[str] = None
    pending = eco.streak_protection_pending
    auto_enabled = eco.streak_protection_auto_enabled

    if allow_auto_shield and pending and not auto_enabled:
        if new_streak == 1 and habit.streak > 0:
            # 途切れていた → 在庫があれば保護発動 + 消費、無ければ救済なし
            has_stock = (eco.streak_protection_count or 0) > 0
            if has_stock:
                new_streak = habit.streak + 1
                new_best = max(new_streak, habit.best_streak)
                eco.streak_protection_count = max(0, eco.streak_protection_count - 1)
                eco.last_streak_protection_used_at = today
                eco.streak_protection_pending = False
                eco.save(update_fields=[
                    'streak_protection_count',
                    'last_streak_protection_used_at',
                    'streak_protection_pending',
                ])
                streak_protected = True
                streak_protection_pending_consumed = True
                streak_protection_message = (
                    f'ストリーク保護石を 1 個使いました。'
                    f'あなたの {new_streak} 日 連続が守られましたよ 🪶'
                )
            else:
                # Pre-mortem S1: 在庫なし → 救済なし、pending だけリセット
                eco.streak_protection_pending = False
                eco.save(update_fields=['streak_protection_pending'])
        else:
            # Pre-mortem S5: 途切れずに達成 (or 元々 streak=0) → pending リセットのみ
            eco.streak_protection_pending = False
            eco.save(update_fields=['streak_protection_pending'])

    return (
        new_streak, new_best, is_comeback, auto_shield_type, streak_protected,
        streak_protection_pending_consumed, streak_protection_message,
    )


def _apply_player_level_up_loop(battle, exp_delta: int) -> tuple[int, int]:
    """battle.current_exp += exp_delta し、必要なら level up ループを回す。

    【FEAT-478 Phase 2b】battle は PlayerBattleState インスタンス (player.battle から取得)。
    Returns: (old_level, new_level). save() は呼び出し側で battle.save() を実行する。
    """
    old_level = battle.level
    battle.current_exp += exp_delta
    while battle.current_exp >= battle.max_exp:
        battle.current_exp -= battle.max_exp
        battle.level += 1
        battle.allocatable_points += GameBalance.ALLOCATABLE_POINTS_PER_LEVEL
        # 【FEAT-319】level_to_max_exp で単一真実値化、直書き禁止。
        battle.max_exp = GameBalance.level_to_max_exp(battle.level)
    return old_level, battle.level


def grant_monthly_ticket_if_21_days_done(player: PlayerProfile, today: date_t) -> bool:
    """【FEAT-433 (2026-06-13)】当月 21 日達成で SSR 確定チケット +1 配布。

    旧 (FEAT-312 以前) の「前月 20 日達成 → 今月初に付与」方式を廃止し、
    当月の達成日数が 21 日に達した瞬間に即時付与する。

    Note: 呼び出し側で transaction.atomic() 配下、player は select_for_update 済み前提
    (CLAUDE.md レンデブー順序: PlayerProfile → PlayerGachaStatus)。
    """
    from ..models import HabitLog, PlayerGachaStatus
    from ..constants import GachaBalance

    first_of_month = today.replace(day=1)

    gacha_status, _ = PlayerGachaStatus.objects.select_for_update().get_or_create(
        player=player,
    )

    if gacha_status.monthly_last_granted_month == first_of_month:
        return False

    month_days = HabitLog.objects.filter(
        habit__player=player,
        date__gte=first_of_month,
        date__lte=today,
        count__gt=0,
    ).values('date').distinct().count()

    if month_days >= 21:
        gacha_status.monthly_tickets = min(
            gacha_status.monthly_tickets + 1,
            GachaBalance.MONTHLY_TICKET_MAX,
        )
        gacha_status.monthly_last_granted_month = first_of_month
        gacha_status.save(update_fields=[
            'monthly_tickets', 'monthly_last_granted_month',
        ])
        return True
    return False


# ─────────────────────────────────────────────────────────────────────────────
# 公開 API: apply_count_change
# ─────────────────────────────────────────────────────────────────────────────


def apply_count_change(
    player: PlayerProfile,
    habit: Habit,
    delta: int,
    *,
    is_checklist: bool = False,
) -> CountChangeResult:
    """単一エントリポイント: count / checklist の plus / minus を統一処理する。

    Args:
        player: ロック前の PlayerProfile (本関数内で `select_for_update` する)
        habit: ロック前の Habit (本関数内で `select_for_update` する)
        delta: +1 (plus / check ON) or -1 (minus / check OFF)
        is_checklist: True なら checklist 経路 (comeback / auto_shield / streak_diamond /
            HabitRewardLog はスキップ、battle_charges は BUG-96 で count 同等加算化)

    Returns:
        CountChangeResult — view 側でレスポンス Map にマップする

    Raises:
        ValueError: delta が +1 / -1 以外
    """
    if delta not in (1, -1):
        raise ValueError(f'delta must be +1 or -1, got {delta!r}')

    today = timezone.localdate()
    # 【FEAT-434 (2026-06-14)】ToDo は既存の難易度倍率方式を維持、Habit (count/checklist)
    # は継続日数ベースの新テーブル (calc_habit_base_exp) に置換。
    if habit.habit_type == 'todo':
        base_exp = calc_exp_gain(habit, player)
    else:
        base_exp = calc_habit_base_exp(habit)
    # 【FEAT-318 (2026-06-13 再活性化)】XP ブースト有効時、base_exp 自体を ×1.5。
    # bonus_exp / delta_exp は base_exp から派生するため、ここで一括適用すれば
    # plus / minus 両経路 + log.exp_gained / habit.total_exp にも自然に反映される。
    base_exp = apply_xp_boost_if_active(player, base_exp)
    # bonus は plus / minus 両経路で同じ計算 (BUG-A 対称性、BUG-2026-0512-02 checklist 同等)
    bonus_exp = calc_stat_bonus_exp(player, habit.category, base_exp)
    if player.settings.mode == GameBalance.MODE_ADVENTURE:
        bonus_exp += round(base_exp * GameBalance.ADVENTURE_EXP_BONUS_RATE)
    delta_exp = base_exp + bonus_exp

    result = CountChangeResult()

    if delta == 1:
        result = _apply_plus(
            player_pk=player.pk,
            habit_pk=habit.pk,
            today=today,
            base_exp=base_exp,
            bonus_exp=bonus_exp,
            delta_exp=delta_exp,
            is_checklist=is_checklist,
        )
    else:
        result = _apply_minus(
            player_pk=player.pk,
            habit_pk=habit.pk,
            today=today,
            base_exp=base_exp,
            bonus_exp=bonus_exp,
            delta_exp=delta_exp,
            is_checklist=is_checklist,
        )

    return result


def _apply_plus(
    *,
    player_pk: int,
    habit_pk: int,
    today: date_t,
    base_exp: int,
    bonus_exp: int,
    delta_exp: int,
    is_checklist: bool,
) -> CountChangeResult:
    """plus / check ON 経路。"""
    from ..views.habits import _auto_allocate_by_ratio  # 循環回避: lazy import

    result = CountChangeResult(exp_gain=base_exp, bonus_exp=bonus_exp)

    with transaction.atomic():
        # ── ロック取得 (rendezvous: Player → Habit → HabitLog) ───────────
        player, habit, log = _lock_player_habit_log(player_pk, habit_pk, today)
        if log is None:
            log = _ensure_log(habit, today)
        was_zero = (log.count == 0)

        # ── log を更新 ───────────────────────────────────────────────────
        # count_delta = +1 (log.count は 1 ずつ進む)、exp_gained は base のみ加算
        # (旧実装と完全同等、bonus_exp は player.current_exp 側でのみ加算する)
        log.count += 1
        log.exp_gained += base_exp
        log.save(update_fields=['count', 'exp_gained'])
        result.log_count_after = log.count

        # ── habit 集計 + streak 更新 ─────────────────────────────────────
        habit_update = {
            'total_count': F('total_count') + 1,
            'total_exp':   F('total_exp') + base_exp,
        }
        new_streak: Optional[int] = None
        if was_zero and habit.habit_type != 'todo':
            (
                new_streak,
                new_best,
                is_comeback,
                auto_shield_type,
                streak_protected,
                streak_protection_pending_consumed,
                streak_protection_message,
            ) = _compute_streak_on_first_done(
                player, habit, today,
                allow_auto_shield=not is_checklist,
            )
            habit_update['streak'] = new_streak
            habit_update['best_streak'] = new_best
            result.is_comeback = is_comeback
            result.auto_shield_type = auto_shield_type
            result.streak_protected = streak_protected  # 【FEAT-377】
            result.streak_protection_pending_consumed = streak_protection_pending_consumed  # 【FEAT-420】
            result.streak_protection_message = streak_protection_message  # 【FEAT-420】
        Habit.objects.filter(pk=habit.pk).update(**habit_update)

        # ── 【FEAT-398】日次 EXP スロットル (経路 1 only、is_checklist=False の count 経路) ─
        # checklist 経路 (is_checklist=True) は EXP スロットル対象外 (既存挙動踏襲)。
        # ガチャ報酬経路 (_apply_reward) は本サービスを呼ばないため自動的に対象外。
        if not is_checklist:
            # 【FEAT-537】旧実装は pt も受け取って `_pts` で捨てていた。
            # スロットル側から pt を外したので受け取り自体が無くなった。
            base_exp_throttled, throttled_now = apply_daily_exp_throttle(
                player, base_exp,
            )
            # EXP スロットル後の delta_exp を再計算
            # bonus_exp も同じ削減率適用 (1pt 固定後は bonus もほぼゼロ)
            if base_exp_throttled < base_exp:
                # スロットル発動: EXP を 1pt 固定に削減
                ratio = base_exp_throttled / base_exp if base_exp > 0 else 0
                bonus_exp_throttled = max(0, round(bonus_exp * ratio))
                delta_exp = base_exp_throttled + bonus_exp_throttled
                result.exp_gain = base_exp_throttled
                result.bonus_exp = bonus_exp_throttled
            else:
                # スロットル未発動: そのまま
                delta_exp = base_exp + bonus_exp
            result.daily_throttle_triggered = throttled_now
            # 【FEAT-408】閾値到達直後 (throttled_now=True) のみ PostHog に記録 (best-effort)
            # Pre-mortem S2: capture_for_player は try/except 包みで best-effort 化済み
            if throttled_now:
                total_habits = Habit.objects.filter(player=player, is_active=True).count()
                capture_for_player(player, 'daily_exp_throttle_reached', {
                    'daily_exp_count': player.battle.daily_exp_count,
                    'player_lv':       player.battle.level,
                    'total_habits_count': total_habits,
                })

        # 【FEAT-478 Phase 2b】reset_battle_charges_if_new_day は battle_charges /
        # battle_charges_date を内部 save する。その後 player.battle で最新状態を取得。
        # count + checklist 両経路で battle_charges +1
        reset_battle_charges_if_new_day(player)
        battle = player.battle  # 内部 save 後に最新 DB 状態を取得

        # ── battle の EXP + Lv 更新 ──────────────────────────────────────
        old_level, new_level = _apply_player_level_up_loop(battle, delta_exp)
        result.old_level = old_level
        result.new_level = new_level
        result.leveled_up = new_level > old_level

        # 【BUG-96 (2026-06-12)】battle_charges 加算を checklist 経路でも実行 (案 B 採択)。
        # 旧 FEAT-289「既存挙動踏襲スキップ」を撤回。チェック 1 個 = count 1 達成と同等扱い。
        # 数値根拠: DAILY_BATTLE_LIMIT=10 + battle_charges 上限 30 で構造的にファーミング不可、
        # 5 項目チェックリストで 5 charges (= 1.6 戦) は許容範囲。
        # 【FEAT-398 第 3 段階】battle_charges_awarded フラグ管理で取り消し対称化 (minus 経路も対応)。
        # 【FEAT-406 (2026-06-01)】3 達成 = 1 戦の思想復活 + 日次リセット導入。
        # 【FEAT-410 (2026-06-01)】上限 3 → 30 (10 戦分ストック = daily_battle_count 上限と整合)。
        # 日次リセット (FEAT-406) が永続爆発リスクを構造的に断っているため安全。
        # 【FEAT-497 (2026-08-04)】リテラル 30 を GameBalance.BATTLE_CHARGES_MAX へ集約。
        # 交換ピース経路 (shop.py の piece_battle_charge) が 2 つ目の加算経路として
        # 同じ上限を見る必要があるため。
        if battle.battle_charges < GameBalance.BATTLE_CHARGES_MAX:
            battle.battle_charges += 1
            log.battle_charges_awarded = True
        else:
            log.battle_charges_awarded = False  # 上限到達、加算されなかった記録
        # battle_charges_awarded フラグを log に保存 (count/exp_gained と別 save)
        log.save(update_fields=['battle_charges_awarded'])
        battle.save(update_fields=['current_exp', 'level', 'max_exp', 'allocatable_points', 'battle_charges'])

        # ── レベルアップ時の自動 stat 配分 + 結晶付与 (FEAT-379) ──────────
        if result.leveled_up:
            allocs, crystals = _auto_allocate_by_ratio(player)
            result.auto_allocations = allocs
            result.crystals_awarded = crystals

        # ── 当日初ダイヤ (`award_diamond_if_first_today`) ─────────────────
        if player.settings.mode == GameBalance.MODE_ADVENTURE:
            result.diamond_earned = False
        else:
            result.diamond_earned = bool(
                was_zero and award_diamond_if_first_today(player, today)
            )

        # ── count 経路のみ: FEAT-314 streak diamond (7 / 14 / 21 / ...) ──
        if not is_checklist and was_zero and habit.habit_type != 'todo' and new_streak is not None:
            if award_diamond_for_streak_7days(player, new_streak):
                result.streak_diamond_days = new_streak

        # ── count 経路のみ: HabitRewardLog 監査 ──────────────────────────
        if not is_checklist:
            HabitRewardLog.objects.create(
                player=player,
                habit=habit,
                action=HabitRewardLog.ACTION_PLUS,
                exp_delta=delta_exp,
                diamond_delta=1 if result.diamond_earned else 0,
            )

        # 【FEAT-465 (2026-06-24)】月次カテゴリチャレンジ進捗加算 (count / checklist
        # 両経路、ToDo (habit_type='todo') は対象外、Gemini Ver1 要件 + 契約テスト C7)
        if habit.habit_type != 'todo':
            increment_challenge_progress(player, habit.category, today)

        # 【FEAT-433】当月 21 日達成で SSR 確定チケット即時配布 (count / checklist 両経路)
        result.monthly_ticket_awarded = grant_monthly_ticket_if_21_days_done(player, today)

        # 【BUG-122 (2026-06-14)】その日初回タスク達成ボーナス (Day 1: 500+3+3、
        # Day 2-7: +100、Day 8+: +20)。当日重複は last_login_diamond_at で抑制。
        from .diamond_service import award_daily_first_task_bonus
        result.today_login_bonus = award_daily_first_task_bonus(player, today)

        # 【FEAT-452 (2026-06-20)】当日 3 回目のタスク達成でフレンドプレゼント
        # popup 候補を抽選。直近 7 日以内ログインのフレンドからランダム 1 人選択、
        # 同日重複防止 + フレンド 0 件 / 既送付済は silent (no popup)。
        from .friend_gift_popup_service import check_friend_gift_popup_trigger
        result.friend_gift_candidate = check_friend_gift_popup_trigger(player, today)

        # 【FEAT-479 (2026-07-06)】その日初回タスク達成でパズルピース (grey) 付与。
        # 【FEAT-479 hotfix (2026-07-06)】旧 `daily_task_count == 1` 外側ガードを
        # 撤廃。ガードは try_grant_task_piece 内部の `last_task_piece_date == today`
        # で idempotent 化されている (2 回目以降は None 返却) ため冗長。
        #
        # 撤廃の動機: Silent auto-activate 修正と旧ガードの悪循環で
        # 「fix deploy 前にタスク 1 回目 → active null で piece 発火せず、
        # deploy 後にタスク 2 回目以降 → 外側ガードで弾かれる」の詰み状態が発生。
        # ガードを外せば当日中に piece 付与を復帰できる。
        from .puzzle_world_service import try_grant_task_piece
        result.puzzle_piece_awarded = try_grant_task_piece(player, today)

    return result


def _apply_minus(
    *,
    player_pk: int,
    habit_pk: int,
    today: date_t,
    base_exp: int,
    bonus_exp: int,
    delta_exp: int,
    is_checklist: bool,
) -> CountChangeResult:
    """minus / check OFF 経路。log が無い / count=0 の場合は no_op=True で早期 return。"""
    result = CountChangeResult()

    with transaction.atomic():
        # ── ロック取得 (rendezvous 同順) ─────────────────────────────────
        player, habit, log = _lock_player_habit_log(player_pk, habit_pk, today)

        # BUG-2026-01: 取り消すべき達成が存在しない場合は冪等に no_op を返す
        if log is None or log.count <= 0:
            result.no_op = True
            return result

        # ── log を更新 (count -= 1, exp_gained -= base、両者 max 0) ─────
        log.count = max(0, log.count - 1)
        log.exp_gained = max(0, log.exp_gained - base_exp)
        log.save(update_fields=['count', 'exp_gained'])
        result.log_count_after = log.count
        becomes_zero = (log.count == 0)

        # ── habit 集計 (Greatest で 0 未満防止) ──────────────────────────
        habit_update = {
            'total_count': Greatest(F('total_count') - 1, 0),
            'total_exp':   Greatest(F('total_exp') - base_exp, 0),
        }
        if becomes_zero and habit.habit_type != 'todo':
            # 「今日加算した +1 を戻す」(最低 0)
            habit_update['streak'] = max(0, habit.streak - 1)
        Habit.objects.filter(pk=habit.pk).update(**habit_update)

        # ── player EXP を base+bonus 分減算 (BUG-A 対称性) ─────────────
        # checklist 経路は旧実装も base+bonus 減算で同じ
        battle = player.battle
        battle.current_exp = max(0, battle.current_exp - delta_exp)
        minus_update_fields = ['current_exp']

        # 【BUG-96 (2026-06-12)】battle_charges 取り消し対称化、checklist 経路も対象に追加。
        # plus 経路で is_checklist=True でも awarded=True フラグを立てたため、minus も対称化必須。
        # log.battle_charges_awarded=True なら charges -1 + フラグ False。
        # False なら無処理 (上限到達で加算されなかった or migration 前の旧データ)。
        if log.battle_charges_awarded:
            battle.battle_charges = max(0, battle.battle_charges - 1)
            log.battle_charges_awarded = False
            log.save(update_fields=['battle_charges_awarded'])
            minus_update_fields.append('battle_charges')

        battle.save(update_fields=minus_update_fields)

        # ── count 経路のみ: HabitRewardLog (minus, exp_delta は負値) ────
        if not is_checklist:
            HabitRewardLog.objects.create(
                player=player,
                habit=habit,
                action=HabitRewardLog.ACTION_MINUS,
                exp_delta=-delta_exp,
                diamond_delta=0,
            )

    # plus 系の reward / leveled_up は minus 経路では返さない (既存契約踏襲)
    result.exp_gain = 0
    result.bonus_exp = bonus_exp  # checklist の旧挙動: response_bonus_exp=bonus_exp が呼ばれていたかは要確認
    # ↑ 注意: 旧 checklist は minus 経路で response_bonus_exp=0 を返していた。
    #   view 側でレスポンス組み立て時に override する。
    return result
