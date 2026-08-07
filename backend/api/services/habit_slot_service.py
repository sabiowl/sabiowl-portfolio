"""
【FEAT-334 (2026-05-27)】Legend 難易度スロット計算ヘルパー。
【FEAT-380 (2026-05-29)】「6 軸全 Lv 5 ALL で 1 枠目解放」仕様にアップグレード。
【FEAT-434 (2026-06-14)】Habit 難易度廃止に伴い Legendary スロット制を全廃。
    `calc_legendary_slots` は常に 0 を返す (= Legendary 不可)。
    `count_active_legendary` は既存 legacy データの監査用に維持。
"""
from __future__ import annotations

from ..models import Habit


def calc_legendary_slots(player) -> int:
    """【FEAT-434 (2026-06-14)】Habit Legendary 廃止に伴い常に 0 を返す。

    v1.0 では Habit 難易度自体が UI から消えるため、本関数の呼び出し元
    (`views/habits.py` の Legendary 枠制限チェック) は実質常に「Legendary
    不可」を返す。安全のため定義のみ残し、戻り値 0 で常に表現する。

    Args:
        player: PlayerProfile インスタンス (API 互換のため引数は維持)。

    Returns:
        int: 常に 0。
    """
    return 0


def count_active_legendary(player) -> int:
    """player の active な legendary 習慣数を返す。

    アーカイブ済み (is_active=False) は除外、Q4 既存維持で過去 legendary は
    新規上限カウントに影響しないが、active で残っているものは消費とみなす。
    """
    return Habit.objects.filter(
        player=player,
        difficulty='legendary',
        is_active=True,
    ).count()
