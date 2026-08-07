"""【FEAT-452 (2026-06-20)】フレンドへのプレゼント popup 判定サービス。

当日 3 回目のタスク達成で popup を表示し、直近 1 週間以内ログインのフレンドから
ランダム 1 人を選んで XP ブースト贈与を促す機構。

【発火条件 (すべて満たした時のみ candidate を返す)】
1. daily_task_count が新しい増分で 3 に到達した瞬間 (4 回目以降は発火しない)
2. last_friend_gift_popup_date != today (同日重複防止)
3. FEAT-451 daily 制限未消費 (Gift.filter(sender, sent_at__date=today) が空)
4. 直近 7 日以内ログイン (last_login_diamond_at >= today - 7 日) の
   フレンドが 1 人以上存在する

【呼出経路 (3 系統、すべて _apply_plus / view 内 transaction.atomic 内で呼ぶ)】
- habit_count_service._apply_plus (habit count + ToDo done)
- ChecklistItemToggleView (checklist 項目チェック ON)
- TimelineCompleteView (タイムライン予定の完了)

【サビ哲学整合】
- 1 回目 / 2 回目では発火しない (煩わしさ回避)
- 対象フレンド 0 件 / 既送付済 / 既 popup 表示済 は silent (no popup)
- popup 自体はサーバー側で「出すと決めた」場合のみ Mobile に candidate を返す
"""
import random as _random
from datetime import date, timedelta

from django.db.models import Q

from ..constants import FriendStatus
from ..models import Friendship, Gift, PlayerProfile


_RECENT_LOGIN_WINDOW_DAYS = 7


def check_friend_gift_popup_trigger(player: PlayerProfile, today: date) -> dict | None:
    """フレンドプレゼント popup の発火判定 + 候補抽選。

    呼出側 (3 経路) の transaction.atomic + player の select_for_update 保護下で
    実行されることを前提とする (daily_task_count の race 防止)。

    Returns:
        None: popup 表示なし (1/2 回目、4 回目以降、既表示、既送付、対象なし)
        dict: {id, name, level, friend_id, active_character_image_path,
               active_character_key}
              当日 3 回目の発火 + 候補が見つかった場合
    """
    # 【FEAT-478 Phase 2b (2026-07-05、codebase_review 20260704 P2-#5)】
    # 旧実装は `player.daily_task_count` / `daily_task_count_date` /
    # `last_friend_gift_popup_date` を PlayerProfile 直接参照していたが、これらは
    # FEAT-478 Phase 2b で PlayerStreakState (NEW state) に分離済。旧 field への
    # 読み書きは、Phase 2b 完了時点では OLD field 自体はまだ物理削除されておらず
    # 「自己完結」で動作していたものの、次フェーズ Phase 2c (RemoveField) で
    # 物理削除された瞬間に AttributeError を起こす時限爆弾だった。
    # `player.streak` (PlayerStreakState proxy) 経由に統一することで Phase 2c
    # で壊れない構造にする (achievements.py と同パターン、`player_streak` を
    # local に取得して以降の全参照はローカル変数経由)。
    player_streak = player.streak

    # ── Step 1: daily_task_count を increment ────────────────────────
    # 日跨ぎで自動 0 リセット (date != today なら count をリセットしてから +1)
    if player_streak.daily_task_count_date != today:
        player_streak.daily_task_count = 0
        player_streak.daily_task_count_date = today
    player_streak.daily_task_count += 1
    player_streak.save(update_fields=['daily_task_count', 'daily_task_count_date'])

    # ── Step 2: 3 回目以外は発火しない (4 回目以降は無視) ──────────────
    # 「= 3」厳密一致で「ちょうど 3 回目に達した瞬間」のみ発火。
    # 4, 5, ... 回目は発火しない (1 日 1 回限り)。
    if player_streak.daily_task_count != 3:
        return None

    # ── Step 3: 同日重複 popup 防止 ──────────────────────────────────
    # 既に今日表示済みなら発火しない (User が dismiss しても再表示しない、
    # サビ哲学「静かな聖域」整合)。
    if player_streak.last_friend_gift_popup_date == today:
        return None

    # ── Step 4: FEAT-451 daily 制限済なら popup 不要 ─────────────────
    # sender が今日すでに 1 個贈っていれば、再勧誘は無意味 (どうせ送れない)。
    if Gift.objects.filter(sender=player, sent_at__date=today).exists():
        return None

    # ── Step 5: フレンド (ACCEPTED) の player_id 集合を取得 ───────────
    friendships = Friendship.objects.filter(
        Q(from_player=player) | Q(to_player=player),
        status=FriendStatus.ACCEPTED,
    ).values_list('from_player_id', 'to_player_id')

    friend_pk_set: set[int] = set()
    for from_id, to_id in friendships:
        # 自分以外を friend_pk_set に加える (双方向 friendship 対応)
        if from_id != player.id:
            friend_pk_set.add(from_id)
        if to_id != player.id:
            friend_pk_set.add(to_id)

    if not friend_pk_set:
        # フレンドゼロ = popup 不要
        return None

    # ── Step 6: 直近 7 日以内ログイン filter ─────────────────────────
    # last_login_diamond_at は当日初回タスク達成日 (≒ ログイン日) の真実値
    # (FEAT-331/BUG-122 系)。これを「最終ログイン日」proxy として使用。
    # 【FEAT-478 Phase 2b (2026-07-05、codebase_review 20260704 P2-#5)】
    # last_login_diamond_at は PlayerStreakState (NEW state) に分離済。
    # diamond_service.award_daily_login_diamonds は NEW state に write するため、
    # 旧 PlayerProfile.last_login_diamond_at を filter しても常に stale (Phase 2b
    # デプロイ以降どこからも write されない)。related_name='streak_state' 経由で
    # NEW state の値を filter するのが正解 (silent 破綻の是正、regression guard は
    # test_friend_gift_popup_state.test_C で網羅済)。
    cutoff_date = today - timedelta(days=_RECENT_LOGIN_WINDOW_DAYS)
    eligible_friends = list(
        PlayerProfile.objects
        .filter(
            pk__in=friend_pk_set,
            streak_state__last_login_diamond_at__gte=cutoff_date,
        )
        .select_related('active_character')
    )

    if not eligible_friends:
        # アクティブフレンド 0 件 = popup 不要 (silent)
        return None

    # ── Step 7: ランダム 1 人を抽選 ──────────────────────────────────
    chosen = _random.choice(eligible_friends)

    # ── Step 8: popup 表示済フラグを立てる ──────────────────────────
    # User が dismiss しようが accept しようが、今日は再表示しない。
    # accept した場合は別途 GiftView 経由で Gift レコード作成 + FEAT-451
    # daily 制限が次の popup を抑止する (Step 4 で来期も発火しない)。
    # 【FEAT-478 Phase 2b】NEW state (PlayerStreakState) に書込。
    player_streak.last_friend_gift_popup_date = today
    player_streak.save(update_fields=['last_friend_gift_popup_date'])

    # ── Step 9: candidate dict を返却 ────────────────────────────────
    char = chosen.active_character
    return {
        'id':        chosen.id,
        'name':      chosen.name,
        # 【FEAT-478 Phase 2b】chosen.level (旧 PlayerProfile.level) は Phase 2b
        # 以降どこからも書き込まれない孤立フィールド。NEW state proxy 経由で
        # 最新レベルを取得する (FriendPlayerSerializer / _friend_player_lite_dict
        # と同パターン、codebase_review 20260704 P2-#5)。
        'level':     chosen.battle.level,
        'friend_id': chosen.friend_id,
        'active_character_image_path': char.image_path if char else None,
        'active_character_key':        char.key        if char else None,
    }
