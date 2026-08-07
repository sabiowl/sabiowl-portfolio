"""【FEAT-486 (2026-07-08)】バトル勝利時の武器ドロップ抽選 helper。

旧 `views/battle.py` の line 89-185 相当を独立 module 化。
`BattleFinishView` からのみ呼ばれる (呼出側の transaction.atomic 内で実行される
ことを前提とする)。

【FEAT-443 (2026-06-20) → FEAT-444 (2026-06-20) → FEAT-461 (2026-06-22)】
バトル勝利時の武器ドロップ。Normal 15% + Rare 10% の 2 段構成。
Rare 優先 + Normal フォールバック (Rare がヒットしたら Normal は roll しない)。
各 tier 内では未所持のみランダム抽選 (全所持なら no-op、PlayerWeapon
UniqueConstraint 違反を構造的に回避)。

【FEAT-461】候補 key のハードコード tuple (_NORMAL_WEAPON_KEYS / _RARE_WEAPON_KEYS)
は撤廃。WeaponMaster.tier (migration 0153) から動的取得する設計に変更し、新規
武器追加時の二重管理 (migration + battle.py 両方更新) drift リスクを解消した。

有効ドロップ率 (期待値):
  Rare:   10.0%
  Normal: 15% × (1 - 10%) = 13.5%
  None:   76.5%
"""
import logging
import random as _random  # 【FEAT-443】武器ドロップ判定 (gacha.py と同パターン)

from ...models import PlayerWeapon, WeaponMaster

_logger = logging.getLogger(__name__)

_NORMAL_WEAPON_DROP_RATE = 0.15
_RARE_WEAPON_DROP_RATE   = 0.10


def _get_tier_weapon_keys(tier: str) -> tuple[str, ...]:
    """【FEAT-461 (2026-06-22)】指定 tier の WeaponMaster.key 一覧を動的取得。

    旧 _NORMAL_WEAPON_KEYS / _RARE_WEAPON_KEYS のハードコード tuple を置き換える。
    新規武器を WeaponMaster に seed する際は tier を指定するだけでドロップ候補に
    自動的に含まれる (battle.py の修正は不要)。
    """
    return tuple(
        WeaponMaster.objects
        .filter(tier=tier)
        .values_list('key', flat=True)
        .order_by('id')
    )


def _try_drop_from_tier(player, tier: str, drop_rate: float):
    """【FEAT-444 (2026-06-20) → FEAT-461 (2026-06-22)】指定 tier の武器抽選。

    `_try_drop_wood_weapon` (FEAT-443) を tier 汎用化したもの。
    呼出側 (`_try_drop_weapon`) の transaction.atomic + player の select_for_update
    保護下で実行されることを前提とする (PlayerWeapon 作成と整合性を確保)。

    【FEAT-461】candidate_keys のハードコード tuple 直渡しから、tier 文字列
    ('normal' / 'rare') を受け取り `_get_tier_weapon_keys` で動的取得する方式に変更。

    返却値:
      None: ドロップなし (drop_rate を外した / 全 tier 内所持済 / WeaponMaster 不在)
      dict: {'weapon_key': ..., 'weapon_name': ..., 'atk_bonus': ...}
    """
    if _random.random() >= drop_rate:
        return None

    candidate_keys = _get_tier_weapon_keys(tier)
    if not candidate_keys:
        # 【FEAT-461】migration 0153 未適用 / tier backfill 漏れ等の異常状態。
        _logger.warning(
            '[battle.drop] no WeaponMaster found for tier=%s (migration 0153 not applied?)',
            tier,
        )
        return None

    # 未所持の weapon のみ抽選候補に。全所持済なら no-op (UniqueConstraint 違反防止)。
    owned_keys = set(
        PlayerWeapon.objects
        .filter(player=player, weapon__key__in=candidate_keys)
        .values_list('weapon__key', flat=True)
    )
    unowned_keys = [k for k in candidate_keys if k not in owned_keys]
    if not unowned_keys:
        return None

    picked_key = _random.choice(unowned_keys)
    try:
        weapon = WeaponMaster.objects.get(key=picked_key)
    except WeaponMaster.DoesNotExist:
        # candidate_keys 取得から本 lookup までの間に WeaponMaster が削除された等の race。
        _logger.warning(
            '[battle.drop] WeaponMaster not found for key=%s (race during drop?)',
            picked_key,
        )
        return None

    PlayerWeapon.objects.create(
        player=player, weapon=weapon, is_equipped=False,
    )
    return {
        'weapon_key':  picked_key,
        'weapon_name': weapon.name,
        'atk_bonus':   weapon.atk_bonus,
    }


def _try_drop_weapon(player):
    """【FEAT-444 (2026-06-20) → FEAT-461 (2026-06-22)】バトル勝利時の武器ドロップ抽選 (2 段構成)。

    1. Rare tier (10%) を先に roll → ヒット + 未所持あり → Rare ドロップ
    2. Rare がドロップしなかった場合のみ Normal tier (15%) を roll →
       ヒット + 未所持あり → Normal ドロップ
    3. どちらもドロップしなかった場合は None 返却

    有効ドロップ率: Rare 10.0% / Normal 13.5% (Rare 不発時の 90% × 15%) / None 76.5%

    返却値:
      None: ドロップなし
      dict: {'weapon_key': ..., 'weapon_name': ..., 'atk_bonus': ...}
    """
    # Rare 優先 (希少 tier ほど優先) → Rare hit したら Normal は roll しない
    rare_drop = _try_drop_from_tier(player, 'rare', _RARE_WEAPON_DROP_RATE)
    if rare_drop is not None:
        return rare_drop
    return _try_drop_from_tier(player, 'normal', _NORMAL_WEAPON_DROP_RATE)
