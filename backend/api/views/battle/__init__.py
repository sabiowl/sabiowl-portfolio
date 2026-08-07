"""【FEAT-486 (2026-07-08)】Backend battle view の 4 file 分割 re-export。

旧 `views/battle.py` (1001 LOC) の import 経路を維持するため、本 __init__.py で
各 View class + helper を re-export する。`urls.py` は変更不要
(`views/__init__.py` L65-68 の `from .battle import (...)` は package でも同一 syntax で成立)。

分割設計 (指示書 FEAT-486 §3.1):
  - `start.py`       — `BattleStartView` + `_serialize_job` + 共通定数
  - `finish.py`      — `BattleFinishView`
  - `weapon_drop.py` — 3 weapon drop helper (`_get_tier_weapon_keys` /
                       `_try_drop_from_tier` / `_try_drop_weapon`)
  - `list.py`        — `BattleLogListView` + `EnemyListView`

import 依存 (循環禁止):
  start.py ───┐
              ├─→ (共通定数は start.py に集約、finish.py が import)
  finish.py ──┤
              └─→ weapon_drop.py

  list.py    — 独立 (他の battle module に依存しない)
"""
from .start import BattleStartView, _serialize_job
from .finish import BattleFinishView
from .weapon_drop import (
    _get_tier_weapon_keys,
    _try_drop_from_tier,
    _try_drop_weapon,
)
from .list import BattleLogListView, EnemyListView

__all__ = [
    'BattleStartView', 'BattleFinishView',
    'BattleLogListView', 'EnemyListView',
    '_serialize_job',
    '_get_tier_weapon_keys', '_try_drop_from_tier', '_try_drop_weapon',
]
