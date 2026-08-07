"""【2026-08-05】BattleFinishView のビジネスロジック。

## なぜ切り出したか

`views/battle/finish.py` の `post()` は 378 行あり、views 37 ファイル中
`services/` を利用しているのは 12 ファイル (32%) という状態だった。
「views は HTTP 境界、services はビジネスロジック」という設計方針を掲げつつ、
**最も複雑な経路ほど view にロジックが残っている**のが実態だった
(doc/ARCHITECTURE.md §2.3 に実測値として明記)。

本モジュールはそのうち、独立性が高く重複が多い 2 つを引き受ける:

  - ポーション在庫の消費 (view 側で **ほぼ同一のブロックが 4 つ** 並んでいた)
  - ジョブ熟練度 EXP の加算

## HTTP に依存しない

`services/` は `request` を受け取らず HTTP レスポンスも組まない。
エラーは `BattleFinishError` として送出し、**view が HTTP に変換する**。
これにより service はテストから直接呼べるし、将来 management command や
別経路から再利用しても壊れない。

## トランザクション境界は呼び出し側

本モジュールの関数は **呼び出し元の `transaction.atomic()` 内で実行される
前提**。`select_for_update` を使うため、外側に atomic が無いと機能しない。
finish の処理は「ポーション消費 → 報酬付与 → Battle 確定」を 1 つの原子性で
括る必要があるため、境界を service 側に持たせるとかえって壊れる。

## ロック順序

CLAUDE.md の「`select_for_update` のレンデブー順序統一」に従い、
呼び出し元が既に `PlayerProfile` → `Battle` を昇順ロック済みの状態で、
本モジュールが `PlayerItem` → `PlayerJobMastery` を続けて取る。
この順序を崩すとデッドロックしうるため、関数の呼び出し順を入れ替えないこと。
"""
from django.utils import timezone

from ..models import PlayerItem, PlayerJobMastery


class BattleFinishError(Exception):
    """finish 処理中のドメインエラー。

    view 側が `error_response()` に変換する。service は HTTP を知らない。
    """

    def __init__(self, code: str, message: str, *, extra: dict | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.extra = extra or {}


# ── ポーション消費 ──────────────────────────────────────────────

# (入力フィールド名, PlayerItem.item_id, 表示名, 在庫不足時のエラーコード)
#
# 【注意】1 件目だけ code が `not_enough_potions` で、他の 3 件のような
# `not_enough_<item_id>` 形式になっていない。FEAT-298 で最初に実装された
# 回復薬のコードが先にクライアントへ出ており、後から追加した 3 種
# (FEAT-376 / FEAT-432) だけが規則的な命名になった経緯による。
# **揃えると既存クライアントの分岐が壊れるため、非対称のまま維持する。**
_POTION_SPECS = (
    ('potions_used',              'recovery_potion',      '回復薬',   'not_enough_potions'),
    ('recovery_potion_plus_used', 'recovery_potion_plus', '上位回復薬', 'not_enough_recovery_potion_plus'),
    ('attack_potion_used',        'attack_potion',        '攻撃の薬', 'not_enough_attack_potion'),
    ('defense_potion_used',       'defense_potion',       '防御の薬', 'not_enough_defense_potion'),
)


def consume_potions(player, used_counts: dict) -> None:
    """戦闘で実際に使ったポーションを `PlayerItem` から減算する。

    Args:
        player: ロック済みの `PlayerProfile`。
        used_counts: `_POTION_SPECS` のフィールド名 → 使用数。

    Raises:
        BattleFinishError: 所持数が使用数に満たない場合。
            `/start/` 時点では足りていても、その後に別デバイスで消費される
            race があるため finish 側でも再検証する (Pre-mortem #5)。

    呼び出し元の `transaction.atomic()` 内で実行すること。
    """
    for field, item_id, label, error_code in _POTION_SPECS:
        used = used_counts.get(field, 0)
        if used <= 0:
            continue

        item = (
            PlayerItem.objects
            .select_for_update()
            .filter(player=player, item_id=item_id)
            .first()
        )
        owned = item.quantity if item else 0
        if used > owned:
            raise BattleFinishError(
                code=error_code,
                message=f'{label}の所持数を超えています 🪶',
                extra={'owned': owned, 'requested': used},
            )

        item.quantity -= used
        item.save(update_fields=['quantity'])


# ── ジョブ熟練度 ────────────────────────────────────────────────

def award_job_mastery(player, battle, result: str) -> dict | None:
    """バトル結果に応じてジョブ熟練度 EXP を加算し、レスポンス用 dict を返す。

    Args:
        player: ロック済みの `PlayerProfile`。
        battle: 対象の `Battle` (enemy.tier を倍率に使う)。
        result: 'win' / 'lose' / 'abandon'。

    Returns:
        レスポンスに載せる dict。`active_character.job` が無い場合は None。

    【FEAT-430】`active_character.job` が唯一の真実値。
    `PlayerProfile.active_job` は参照しない (v1.1+ の熟練度システム解禁時に再活用)。
    """
    # 遅延 import: constants は他モジュールから広く読まれるため、
    # services 層で循環参照を作らないよう関数内で読む (view 側の実装を踏襲)。
    from ..constants import (
        JOB_MASTERY_EXP_PER_BATTLE_LOSS,
        JOB_MASTERY_EXP_PER_BATTLE_WIN,
        JOB_MASTERY_MAX_LEVEL,
        JOB_MASTERY_TIER_MULTIPLIER,
        calc_job_mastery_exp_to_next,
    )

    if not (player.active_character and player.active_character.job):
        return None

    job = player.active_character.job
    # 【FEAT-229 レンデブー順序】PlayerProfile → Battle → PlayerJobMastery 昇順
    mastery, _created = PlayerJobMastery.objects.select_for_update().get_or_create(
        player=player, job=job,
        defaults={'level': 1, 'exp': 0},
    )

    base_exp = (
        JOB_MASTERY_EXP_PER_BATTLE_WIN if result == 'win'
        else JOB_MASTERY_EXP_PER_BATTLE_LOSS
    )
    tier_mult = JOB_MASTERY_TIER_MULTIPLIER.get(battle.enemy.tier, 1.0)
    exp_gain = int(base_exp * tier_mult)

    mastery.exp += exp_gain
    leveled_up = False
    maxed_now = False

    # 複数 Lv 同時 up 対応 (Lv 5 → 6 → 7 が 1 戦で起きるケース)
    while (mastery.level < JOB_MASTERY_MAX_LEVEL
           and mastery.exp >= calc_job_mastery_exp_to_next(mastery.level)):
        mastery.exp -= calc_job_mastery_exp_to_next(mastery.level)
        mastery.level += 1
        leveled_up = True

    if mastery.level >= JOB_MASTERY_MAX_LEVEL and not mastery.is_maxed:
        mastery.is_maxed = True
        mastery.first_maxed_at = timezone.now()
        maxed_now = True
        # Max 到達時: EXP は 0 にキャップ (超過分を次 Lv に繰り越さない)
        mastery.exp = 0

    mastery.save()

    return {
        'job_id':         job.job_id,  # string key (e.g. 'warrior'), not PK
        'job_name':       job.job_name,
        'exp_gained':     exp_gain,
        'level':          mastery.level,
        'exp':            mastery.exp,
        'exp_to_next':    (calc_job_mastery_exp_to_next(mastery.level)
                           if mastery.level < JOB_MASTERY_MAX_LEVEL else 0),
        'is_maxed':       mastery.is_maxed,
        'leveled_up_now': leveled_up,
        'maxed_now':      maxed_now,
    }
