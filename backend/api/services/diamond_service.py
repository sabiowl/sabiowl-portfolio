"""【FEAT-314】ダイヤ取得経路の追加 - 3 ヘルパー集約モジュール。

既存 `exp_service.award_diamond_if_first_today` (当日初の習慣達成 +1 ダイヤ) と
同じ「冪等性 select_for_update」パターンを踏襲し、以下 3 経路を実装:

- `award_diamond_for_battle_win`        — その日初のバトル勝利で +5 (DateField で冪等)
- `award_diamond_for_streak_7days`      — 7/14/21/... 日達成で +5 (IntegerField で冪等)
- `award_diamond_for_title_acquired`    — 称号 unlock 時 +20 (BooleanField で冪等)

各ヘルパーは `transaction.atomic()` + `select_for_update()` で並列リクエスト
保護を担保し、戻り値の bool で「実際に付与したか」を呼び出し側に伝える
(レビュー Pre-mortem #1 並列レース対策)。

関連レビュー: `doc/gameplay_review/20260525_gameplay_review.md` §3 B-3
関連 FEAT  : FEAT-295 (バトル) / FEAT-222 (Achievement) / FEAT-247 (ToastCenter)

【FEAT-478 Phase 2b (2026-07-04)】PlayerProfile 直アクセスを State 経由に書換:
  - diamonds / diamonds_total → PlayerEconomyState (player.economy.*)
  - last_battle_diamond_at / last_streak_diamond_day / last_login_diamond_at
    → PlayerStreakState (player.streak.*)
"""
from datetime import date

from django.db import transaction

from ..models import PlayerAchievement, PlayerProfile
from .posthog_capture import capture_for_player  # 【FEAT-408】diamond_earned / diamond_spent 計測


# 付与額の定数 (テストや UI 側で参照可能、変更時の影響範囲を限定)
DIAMOND_BATTLE_WIN_AMOUNT     = 5
DIAMOND_STREAK_MILESTONE_AMT  = 5
DIAMOND_TITLE_ACQUIRED_AMOUNT = 20
STREAK_DIAMOND_MILESTONE_STEP = 7  # 7 の倍数 (7/14/21/...) で発火

# 【BUG-122 (2026-06-14)】「その日初回タスク達成」ボーナス (trigger 変更: ログイン → タスク達成)
# 旧 BUG-120: ログイン時に diamonds 付与 (silent)
# 新 BUG-122: その日初回の habit / ToDo / checklist / timeline 完了で diamond_service の
#   award_daily_first_task_bonus() が付与、Mobile UI で 7 日カレンダー + スタンプ演出を表示。
#   Day 1 のみ初日 seed (500 ダイヤ + 3 デイリー + 3 ウィークリー) も同経路で配布。
DIAMOND_FIRST_TASK_DAY_1      = 500   # Day 1 (登録日) の初回タスク達成
DIAMOND_FIRST_TASK_EARLY      = 100   # Day 2-7
DIAMOND_FIRST_TASK_LATE       = 20    # Day 8 以降
FIRST_TASK_EARLY_DAYS_END     = 7     # Day N <= 7 が early tier (Day 2-7 が対象)
FIRST_TASK_DAY_1_DAILY_TICKETS  = 3   # Day 1 のみ初日 seed として配布
FIRST_TASK_DAY_1_WEEKLY_TICKETS = 3   # Day 1 のみ初日 seed として配布


def award_diamond_for_battle_win(player: PlayerProfile, today: date) -> bool:
    """その日初のバトル勝利でダイヤ +5 を付与する。

    `PlayerStreakState.last_battle_diamond_at` で冪等担保:
        - == today      → 当日既に付与済 → False (no-op)
        - != today (or None) → +5 ダイヤ + last_battle_diamond_at = today に更新

    `select_for_update` で並列バトル勝利リクエスト時の二重付与を防止
    (`exp_service.award_diamond_if_first_today` と同パターン)。

    Args:
        player: 呼び出し時点の PlayerProfile (本関数内で再フェッチして lock)
        today:  当日の日付 (呼び出し側で `timezone.localdate()` JST を使うこと、Pre-mortem #3)

    Returns:
        True  - 実際に +5 を付与した
        False - 既に当日付与済みでスキップした
    """
    # 早期 return (lock 取らずに済む高速パス、所有日 == today なら確実に skip)
    if player.streak.last_battle_diamond_at == today:
        return False
    with transaction.atomic():
        locked = PlayerProfile.objects.select_for_update().get(pk=player.pk)
        locked_streak = locked.streak
        if locked_streak.last_battle_diamond_at == today:
            return False
        locked_eco = locked.economy
        locked_eco.diamonds              += DIAMOND_BATTLE_WIN_AMOUNT
        locked_eco.diamonds_total        += DIAMOND_BATTLE_WIN_AMOUNT
        locked_streak.last_battle_diamond_at = today
        locked_eco.save(update_fields=['diamonds', 'diamonds_total'])
        locked_streak.save(update_fields=['last_battle_diamond_at'])
    # 【FEAT-408】diamond_earned 計測 (best-effort, select_for_update 外で実行)
    capture_for_player(player, 'diamond_earned', {
        'source': 'battle_first_win',
        'amount': DIAMOND_BATTLE_WIN_AMOUNT,
        'total_balance_after': locked_eco.diamonds,
    })
    return True


def award_diamond_for_streak_7days(player: PlayerProfile, streak_days: int) -> bool:
    """連続 7 / 14 / 21 / ... 日達成 (7 の倍数) でダイヤ +5 を付与する。

    `PlayerStreakState.last_streak_diamond_day` で冪等担保:
        - streak_days が 7 の倍数でない          → False (no-op)
        - last_streak_diamond_day >= streak_days → False (既付与 or より大きな streak で
                                                            既に付与済)
        - 上記以外                                → +5 ダイヤ + last_streak_diamond_day を
                                                    streak_days に更新

    Args:
        player:      呼び出し時点の PlayerProfile (本関数内で再フェッチして lock)
        streak_days: 当該習慣の更新後 streak 値 (HabitCountView の `new_streak`)

    Returns:
        True  - +5 を付与
        False - 7 の倍数でない or 既に同 streak で付与済
    """
    if streak_days < STREAK_DIAMOND_MILESTONE_STEP:
        return False
    if streak_days % STREAK_DIAMOND_MILESTONE_STEP != 0:
        return False
    # 早期 return (Pre-mortem #1 並列 race 対策の前段ガード)
    if player.streak.last_streak_diamond_day >= streak_days:
        return False
    with transaction.atomic():
        locked = PlayerProfile.objects.select_for_update().get(pk=player.pk)
        locked_streak = locked.streak
        if locked_streak.last_streak_diamond_day >= streak_days:
            return False
        locked_eco = locked.economy
        locked_eco.diamonds               += DIAMOND_STREAK_MILESTONE_AMT
        locked_eco.diamonds_total         += DIAMOND_STREAK_MILESTONE_AMT
        locked_streak.last_streak_diamond_day = streak_days
        locked_eco.save(update_fields=['diamonds', 'diamonds_total'])
        locked_streak.save(update_fields=['last_streak_diamond_day'])
    # 【FEAT-408】diamond_earned 計測
    capture_for_player(player, 'diamond_earned', {
        'source': 'streak_7days',
        'streak_days': streak_days,
        'amount': DIAMOND_STREAK_MILESTONE_AMT,
        'total_balance_after': locked_eco.diamonds,
    })
    return True


def award_diamond_for_title_acquired(
    player: PlayerProfile,
    achievement_id: int,
) -> bool:
    """称号 (Achievement) 獲得時の祝福ボーナスとしてダイヤ +20 を付与する。

    `PlayerAchievement.diamond_awarded` フラグで冪等担保:
        - True  → 既付与 → False (no-op)
        - False → +20 ダイヤ + diamond_awarded=True に更新

    既存 `AchievementClaimView` の `reward_diamonds` 経路とは **別軸**:
        - claim 経路 = ユーザー任意 + Achievement.reward_diamonds (可変)
        - 本経路   = unlock 自動 + 固定 +20 ダイヤ (祝福)

    Args:
        player:         呼び出し時点の PlayerProfile
        achievement_id: unlock した Achievement の ID

    Returns:
        True  - +20 を付与
        False - 既に付与済 or PlayerAchievement が見つからない (防御的に no-op)
    """
    with transaction.atomic():
        # 【FEAT-450 (2026-06-20)】ロック取得順を PlayerProfile → PlayerAchievement に統一。
        # CLAUDE.md「select_for_update のレンデブー順序統一」+ diamond_service 他関数
        # (award_daily_first_task_bonus 等) の PlayerProfile 起点パターンに整合。
        # 旧実装は PlayerAchievement → PlayerProfile の逆順だった
        # (codebase_review 20260620 §2-2-B の指摘解消)。
        # 【冪等性】PlayerAchievement.diamond_awarded の DB 値を担保するため、
        # 早期 return (pa is None / pa.diamond_awarded=True) の判定後に
        # PlayerProfile ロックを取りに行く設計を維持。Player ロックを先取りすると
        # 「pa が存在しない / 既付与」の no-op 経路でも Player ロックを取って
        # 即解放するパターンになるが、低頻度経路のため許容範囲。
        locked_player = PlayerProfile.objects.select_for_update().get(pk=player.pk)
        # PlayerAchievement が存在しない場合 (caller が誤呼び出し) は防御的に skip。
        # check_achievements 後の `newly_unlocked` から呼ぶ前提なので通常は存在する。
        pa = (
            PlayerAchievement.objects
            .select_for_update()
            .filter(player=player, achievement_id=achievement_id)
            .first()
        )
        if pa is None:
            return False
        if pa.diamond_awarded:
            return False
        locked_eco = locked_player.economy
        locked_eco.diamonds       += DIAMOND_TITLE_ACQUIRED_AMOUNT
        locked_eco.diamonds_total += DIAMOND_TITLE_ACQUIRED_AMOUNT
        locked_eco.save(update_fields=['diamonds', 'diamonds_total'])
        pa.diamond_awarded = True
        pa.save(update_fields=['diamond_awarded'])
    # 【FEAT-408】diamond_earned 計測
    capture_for_player(player, 'diamond_earned', {
        'source': 'title_acquired',
        'achievement_id': achievement_id,
        'amount': DIAMOND_TITLE_ACQUIRED_AMOUNT,
        'total_balance_after': locked_eco.diamonds,
    })
    return True


def award_daily_first_task_bonus(player: PlayerProfile, today: date) -> dict | None:
    """【BUG-122 (2026-06-14)】その日初回のタスク達成でログインボーナスを付与する。

    呼出元 (4 経路):
      - habit_count_service._apply_plus (habit count + ToDo 完了)
      - ChecklistItemToggleView (checklist 項目チェック)
      - TimelineCompleteView (タイムライン予定の完了)

    `PlayerProfile.created_at` からの絶対経過日数で配布内容を変更:
        Day 1 (登録日の初回タスク達成):
            +500 ダイヤ + 3 デイリーチケット + 3 ウィークリーチケット
            (旧 BUG-120 では seed で登録時に配布、BUG-122 でタスク達成 trigger に変更)
        Day 2-7: +100 ダイヤ
        Day 8 以降: +20 ダイヤ

    `PlayerStreakState.last_login_diamond_at` で当日重複付与を防止 (FEAT-331/BUG-120 と
    同フィールド流用、意味論: 「ログインボーナスを付与した最終日」)。

    Pre-mortem:
      S1 並列リクエスト 二重付与 → select_for_update + 内側 == today 再チェック
      S2 created_at 未来 (運用ミス) → days_count < 1 で early-return
      S3 既存ユーザー (created_at が古い) → 自動的に Day 8+ tier → +20 daily
      S4 Day 1 で gacha auto-grant (+1 デイリー) と重複 → daily_last_granted = today
         で抑制、weekly_last_granted_week も同様に this_monday に set

    Args:
        player: 呼び出し時点の PlayerProfile (本関数内で再フェッチして lock)
        today:  当日の日付 (呼び出し側で `timezone.localdate()` JST を使うこと)

    Returns:
        dict: {amount, days_count, granted_daily_tickets, granted_weekly_tickets}
              当日初回タスク達成で報酬を付与した場合
        None: 当日既処理 or エラー (no-op)
    """
    # 早期 return (lock 取らずに済む高速パス)
    if player.streak.last_login_diamond_at == today:
        return None

    from datetime import timedelta
    from django.utils import timezone as _tz
    from ..constants import GachaBalance

    # 【BUG-130 (2026-06-17)】timezone-aware に変換してから .date() を取る。
    # `player.created_at` は USE_TZ=True により UTC で格納されているため、
    # `.date()` を直接呼ぶと UTC date が返り、`today = timezone.localdate()` (JST)
    # との比較で **JST 00:00〜09:00 に登録したユーザーが days_count=2** になり
    # Day 1 報酬 (500ダイヤ + 3+3 チケット) を取り逃す。`timezone.localtime(...)
    # .date()` で JST date に揃える (P0-02 / player.py:462 と同パターン)。
    registered_date = _tz.localtime(player.created_at).date()
    days_count = (today - registered_date).days + 1  # Day 1 ベース
    if days_count < 1:
        # Pre-mortem S2: created_at 未来 (運用ミス) は付与しない
        return None

    # 報酬テーブル (BUG-122 仕様)
    if days_count == 1:
        amount         = DIAMOND_FIRST_TASK_DAY_1       # 500
        granted_daily  = FIRST_TASK_DAY_1_DAILY_TICKETS  # 3
        granted_weekly = FIRST_TASK_DAY_1_WEEKLY_TICKETS # 3
    elif days_count <= FIRST_TASK_EARLY_DAYS_END:
        amount         = DIAMOND_FIRST_TASK_EARLY        # 100
        granted_daily  = 0
        granted_weekly = 0
    else:
        amount         = DIAMOND_FIRST_TASK_LATE         # 20
        granted_daily  = 0
        granted_weekly = 0

    with transaction.atomic():
        locked = PlayerProfile.objects.select_for_update().get(pk=player.pk)
        locked_streak = locked.streak
        # 別リクエストで先に当日処理されていれば skip (Pre-mortem S1)
        if locked_streak.last_login_diamond_at == today:
            return None
        locked_eco = locked.economy
        locked_eco.diamonds              += amount
        locked_eco.diamonds_total        += amount
        locked_streak.last_login_diamond_at = today
        locked_eco.save(update_fields=['diamonds', 'diamonds_total'])
        locked_streak.save(update_fields=['last_login_diamond_at'])

        # Day 1 special: PlayerGachaStatus にチケット直接付与 + gacha auto-grant 抑制
        if granted_daily > 0 or granted_weekly > 0:
            from ..models import PlayerGachaStatus
            status_obj, _ = PlayerGachaStatus.objects.select_for_update().get_or_create(
                player=locked,
            )
            status_obj.daily_tickets  = min(
                status_obj.daily_tickets + granted_daily,
                GachaBalance.DAILY_TICKET_MAX,
            )
            status_obj.weekly_tickets = min(
                status_obj.weekly_tickets + granted_weekly,
                GachaBalance.WEEKLY_TICKET_MAX,
            )
            # Pre-mortem S4: gacha auto-grant (GachaStatusView) を同日抑制
            status_obj.daily_last_granted        = today
            this_monday = today - timedelta(days=today.weekday())
            status_obj.weekly_last_granted_week  = this_monday
            status_obj.save(update_fields=[
                'daily_tickets', 'weekly_tickets',
                'daily_last_granted', 'weekly_last_granted_week',
            ])

    # 【FEAT-408】diamond_earned 計測
    capture_for_player(player, 'diamond_earned', {
        'source': 'daily_first_task',
        'amount': amount,
        'days_count': days_count,
        'total_balance_after': locked_eco.diamonds,
    })
    return {
        'amount': amount,
        'days_count': days_count,
        'granted_daily_tickets': granted_daily,
        'granted_weekly_tickets': granted_weekly,
    }


def award_iap_diamonds(
    player: PlayerProfile,
    product_id: str,
    diamonds: int,
    event_id: str,
) -> int:
    """【FEAT-436 Phase 2 (2026-06-17)】IAP 購入のダイヤを付与する。

    RevenueCat webhook から呼ばれる。冪等性は呼出側 (RevenueCatWebhookView) で
    IAPReceipt.event_id unique 制約により担保するため、本関数は単純に
    `select_for_update` で player をロックして diamonds を加算する。

    Args:
        player:     PlayerProfile インスタンス (本関数内で再フェッチして lock)
        product_id: 商品 ID ('diamond_pack_120' 等、PostHog 計測用)
        diamonds:   付与ダイヤ数 (constants.IAP_PRODUCTS から呼出側で解決済)
        event_id:   RevenueCat の event UUID (PostHog 計測用)

    Returns:
        付与後の総ダイヤ残高

    Pre-mortem:
        S5 並列同時 webhook → select_for_update で player ロック
    """
    with transaction.atomic():
        locked = PlayerProfile.objects.select_for_update().get(pk=player.pk)
        locked_eco = locked.economy
        locked_eco.diamonds       += diamonds
        locked_eco.diamonds_total += diamonds
        locked_eco.save(update_fields=['diamonds', 'diamonds_total'])

    # 【FEAT-408 / FEAT-436】diamond_earned 計測 (source='iap')
    capture_for_player(player, 'diamond_earned', {
        'source':              'iap',
        'amount':              diamonds,
        'product_id':          product_id,
        'event_id':            event_id,
        'total_balance_after': locked_eco.diamonds,
    })
    return locked_eco.diamonds


def record_diamond_spent(player, sink: str, amount: int) -> None:
    """【FEAT-408】ダイヤ消費イベントを PostHog に best-effort で記録する。

    ショップ購入 / ガチャ redo / キャラ購入 等のダイヤ消費時に各 view から呼ぶ。

    Args:
        player: PlayerProfile インスタンス (消費後の diamonds 値を参照)
        sink:   消費経路の識別子 ('rest_fruit' / 'gacha_redo' / 'char_purchase' / etc)
        amount: 消費したダイヤ数
    """
    capture_for_player(player, 'diamond_spent', {
        'sink':                sink,
        'amount':              amount,
        'total_balance_after': player.economy.diamonds,
    })
