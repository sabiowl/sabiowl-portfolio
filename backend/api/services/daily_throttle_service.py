"""【FEAT-398 (2026-05-31)】日次スロットルサービス。

ファーミング防止のための 2 軸制限:
  1. EXP スロットル: 経路 1-2 (習慣 +1 / ToDo / タイムライン予定完了) で
     1 日 25 件超過後の経路 EXP / 配分 pt を 1pt 固定に削減。
  2. バトル出陣上限: 経路 4 (BattleStartView) で 1 日 10 回超過後の出陣を拒否。

両者は独立カウンタ。ガチャ報酬 (経路 3) は対象外。
カウンタリセット: 日付変更時 (date field との比較) で 0 リセット (JST 基準)。

Pre-mortem:
  #2 race: select_for_update() ロック内で呼ぶこと (caller 責務)
  #3 日付境界: timezone.localdate() を 1 回取得して使い回す
  #5 ガチャ経路混入: ガチャ view (_apply_reward) は意図的に呼ばない (docstring 明示)
"""

from django.utils import timezone

from ..constants import (
    DAILY_EXP_THROTTLE_LIMIT,
    DAILY_EXP_THROTTLED_VALUE,
    DAILY_BATTLE_LIMIT,
)


def apply_daily_exp_throttle(player, exp_gain: int, points_gain: int):
    """EXP / 配分 pt を日次閾値で削減し、daily_exp_count を更新して保存する。

    caller は select_for_update() ロック済みの player を渡すこと (Pre-mortem #2)。
    【FEAT-478 Phase 2b】battle state への書込と保存を本関数内で完結する。

    Args:
        player: PlayerProfile インスタンス (ロック済み)
        exp_gain: 削減前の EXP 付与量
        points_gain: 削減前の 配分 pt 付与量

    Returns:
        (exp_gain, points_gain, throttled_now):
            exp_gain:     削減後 EXP (閾値前は不変、閾値後は 1pt 固定)
            points_gain:  削減後 pt  (同上)
            throttled_now: 今回の処理で初めて閾値 (26 件目) に達した場合 True
                           (Flutter 側でサビ口調 SnackBar を 1 回表示するためのシグナル)
    """
    today = timezone.localdate()
    battle = player.battle

    # 日付変わったらカウントリセット
    if battle.daily_exp_count_date != today:
        battle.daily_exp_count = 0
        battle.daily_exp_count_date = today

    throttled_now = False
    if battle.daily_exp_count >= DAILY_EXP_THROTTLE_LIMIT:
        # 閾値到達直後 (== LIMIT が 25 件目が終了して 26 件目に入る瞬間) のみ True
        if battle.daily_exp_count == DAILY_EXP_THROTTLE_LIMIT:
            throttled_now = True
        exp_gain    = DAILY_EXP_THROTTLED_VALUE  # 1pt 固定
        points_gain = DAILY_EXP_THROTTLED_VALUE

    battle.daily_exp_count += 1
    battle.save(update_fields=['daily_exp_count', 'daily_exp_count_date'])
    return exp_gain, points_gain, throttled_now


def check_daily_battle_limit(player):
    """1 日 N 回出陣済なら False を返す (N = DAILY_BATTLE_LIMIT + player.battle.daily_battle_limit_bonus)。

    【FEAT-429 (2026-06-12)】player.battle.daily_battle_limit_bonus を加算する動的 limit に対応。

    caller は select_for_update() ロック済みの player を渡すこと。
    カウンタのリセット判定のみ行い、save は reset_daily_battle_count_if_new_day 内で完結。

    Returns:
        (can_battle, current_count, dynamic_limit):
            can_battle:    出陣可能なら True、上限到達なら False
            current_count: 現在の出陣回数 (0-15)
            dynamic_limit: 動的算出された上限 (10 + bonus、UI 反映用)
    """
    reset_daily_battle_count_if_new_day(player)
    battle = player.battle
    dynamic_limit = DAILY_BATTLE_LIMIT + (battle.daily_battle_limit_bonus or 0)
    return (battle.daily_battle_count < dynamic_limit,
            battle.daily_battle_count,
            dynamic_limit)


def increment_daily_battle_count(player):
    """出陣成功確定時に daily_battle_count を +1 して保存する。

    BattleStartView の transaction 内、check_daily_battle_limit() で True を
    確認した後に呼ぶこと。
    """
    # check_daily_battle_limit() を先に呼んでいれば既にリセット済みのはずだが、
    # 防御的に再チェック (Pre-mortem #3 日付境界の race 許容)
    reset_daily_battle_count_if_new_day(player)
    battle = player.battle
    battle.daily_battle_count += 1
    battle.save(update_fields=['daily_battle_count'])


def current_daily_battle_count(player) -> int:
    """読み取り時に表示すべき本日の出陣回数を返す。

    `daily_battle_count_date` が今日でなければ、DB 上の値が 10 でも UI には
    0 を返す。Flutter の出陣ボタンが stale な 10/10 を見て BattleStartView への
    到達を塞ぐ BUG-78 の防止用。

    本関数は DB を変更しない。永続化が必要な read path では
    reset_daily_battle_count_if_new_day() を呼び、caller が save する。
    """
    today = timezone.localdate()
    battle = player.battle
    if battle.daily_battle_count_date != today:
        return 0
    return battle.daily_battle_count


def reset_daily_battle_count_if_new_day(player) -> bool:
    """日付が変わっていれば daily_battle_count を 0 に戻して保存する。

    【FEAT-478 Phase 2b】battle state への書込と保存を本関数内で完結する。

    Returns:
        True  — リセットが発生した
        False — 同日のため変更なし
    """
    today = timezone.localdate()
    battle = player.battle
    if battle.daily_battle_count_date != today:
        battle.daily_battle_count = 0
        battle.daily_battle_count_date = today
        battle.save(update_fields=['daily_battle_count', 'daily_battle_count_date'])
        return True
    return False


def reset_battle_charges_if_new_day(player) -> bool:
    """【FEAT-406 (2026-06-01)】battle_charges を日次リセットする。

    player.battle.battle_charges_date != today (または null) の場合、
    battle_charges=0 + battle_charges_date=today にリセットして保存する。

    Pre-mortem S1 対応: charges 加算時・消費時の「今日初めての操作」で
    0 リセットを掛けることで、日跨ぎで charges が持ち越されるのを防ぐ。

    caller は select_for_update() ロック済みの player を渡すこと。
    【FEAT-478 Phase 2b】battle state への書込と保存を本関数内で完結する。

    Returns:
        True  — リセットが発生した (battle_charges / battle_charges_date を変更)
        False — 同日のため変更なし
    """
    today = timezone.localdate()
    battle = player.battle
    if battle.battle_charges_date != today:
        battle.battle_charges = 0
        battle.battle_charges_date = today
        battle.save(update_fields=['battle_charges', 'battle_charges_date'])
        return True
    return False
