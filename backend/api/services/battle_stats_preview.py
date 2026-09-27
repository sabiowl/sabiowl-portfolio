"""【FEAT-535 (2026-08-29)】admin 表示用の「プレイヤー戦闘能力」ミラー。

🔴 **真実値は Dart 側にある。本モジュールはそのミラーである。**

Backend はプレイヤーの攻撃力 / HP を **1 つも持っていない**。
`POST /api/battle/start/` が返すのは敵のパラメータとジョブ修飾だけで、
プレイヤーの Combatant を組み立てているのは Flutter の
`battle_provider._buildPlayerCombatant` + `BattleDisplay` である
(`mobile/lib/features/battle/constants/battle_constants.dart`)。

つまりここに書いてある式は **admin に数字を出すためだけの写し**であって、
**実際の戦闘値は端末が計算している**。Dart 側の係数が変われば、ここは黙って
嘘の数字を出し続ける。

**それを防いでいるのが `mobile/test/battle/battle_display_formula_contract_test.dart`
である。** Backend から Dart を読むテストは書けない (CI の実行単位が別) ので、
**Dart 側から「Python も直せ」と叫ばせる向きだけが機能する**。
同テストは失敗時に本ファイル名を名指しする。

同じ書き方の前例: `views/maintenance.py` の `_EN_FALLBACK` (FEAT-536)。

## 入力はすべて Backend が持っている

| 入力 | 所在 |
|---|---|
| `level` | `PlayerBattleState.level` |
| `weapon_atk` | `PlayerWeapon(is_equipped=True) -> WeaponMaster.atk_bonus` |
| 6 ステータス Lv | `CharacterStat.level` (`name` は '運動力' 等の日本語キー) |
| ジョブ修飾 | `PlayerProfile.active_character.job` |

⚠️ **ジョブ解決は `active_character.job` が唯一の真実値。**
`PlayerProfile.active_job` は v1.1+ の熟練度システム用に維持されているだけで
`views/battle/start.py` は参照しない (CLAUDE.md「ジョブ解決 (FEAT-430)」)。
**本モジュールでも読まないこと。**
"""

from decimal import Decimal, ROUND_HALF_UP


# ─────────────────────────────────────────────────────────────────────────────
# Dart 側の定数ミラー
#
# 変更したくなったら、まず Dart 側 (battle_constants.dart /
# battle_provider._buildPlayerCombatant) を直すこと。ここは追従する側である。
# ─────────────────────────────────────────────────────────────────────────────

#: `BattleDisplay.computeAtk` の切片と傾き。式: (10 + level*2 + weaponAtk + studyLv)
ATK_INTERCEPT = 10
ATK_PER_LEVEL = 2

#: `BattleConstants.playerBaseHp` / `playerHpPerLevel`。
#: 🔴 `playerBaseHp` は 2026-06-13 に 10 -> 20 の 2 倍化を経験した**動く定数**。
PLAYER_BASE_HP = 200
PLAYER_HP_PER_LEVEL = 20

#: 6 ステータスの連動係数 (FEAT-333)。`_buildPlayerCombatant` の inline に対応。
ATHLETIC_HP_PER_LEVEL = 5       # 運動力 -> maxHp
MENTAL_ATB_PER_LEVEL = 0.01     # 精神力 -> atbSpeedModifier
HEALTH_REGEN_PER_LEVEL = 2      # 健康力 -> 毎ターン回復
CREATIVITY_CRIT_PER_LEVEL = 0.005       # 創造力 -> クリ率
CONTRIBUTION_REDUCTION_PER_LEVEL = 0.005  # 貢献力 -> 被ダメ軽減

#: MVP は固定 (`_buildPlayerCombatant` の `spd: 10`)。
PLAYER_SPD = 10

#: Dart 側の `player.equippedWeapon?.atkBonus ?? 10`。
#: 未装備でも 0 ではなく 10 が入る (starter_sword 相当)。
UNEQUIPPED_WEAPON_ATK = 10

#: `starter_sword.atk_bonus` (migration 0082 が真実値)。
#: ⚠️ 値は `UNEQUIPPED_WEAPON_ATK` と同じ 10 だが **別の意味**である ——
#: あちらは「未装備のときに Dart が使う既定値」、こちらは「実在の武器の値」。
#: 敵一覧の簡約式は後者を仮定しているので、まとめてはいけない
#: (starter_sword を強化したとき、片方だけ動く)。
#: Dart 側の契約テスト C が同じ 10 を明示している。
STARTER_SWORD_ATK_BONUS = 10

#: Dart 側は stat が無ければ `?? 0`。**CharacterStat の default 1 ではない。**
MISSING_STAT_LEVEL = 0

#: `_serialize_job(None)` が返す値 (`views/battle/start.py`)。
#: ⚠️ Dart の `Job.fallback` (warrior / 1.3 / 0.9) ではない。Backend は job が
#: 無いとき **modifier 1.0** を送るので、端末が実際に使うのはこちらである。
JOB_MISSING_ATTACK_POWER_MODIFIER = 1.0
JOB_MISSING_ATB_SPEED_MODIFIER = 1.0


def dart_round(value: float) -> int:
    """Dart の `double.round()` と同じ丸め (half away from zero)。

    ⚠️ Python 組み込みの `round()` は **banker's rounding** で、`round(34.5) == 34`
    になる。Dart は `35` を返す。`attack_power_modifier` には **実在の値として
    `1.5` がある** (`dark_mage`、migration 0112) ので、`.5` は理論上の話ではない。

        >>> dart_round(34.5)
        35
        >>> round(34.5)   # 組み込み: banker's
        34

    float を一度 `Decimal` に通すのは、**Dart と同じ二進小数の結果を丸めるため**。
    `Decimal(str(...))` や `Decimal(23) * Decimal('1.3')` にすると Dart の
    float 演算とずれる (Dart 側は `23 * 1.3 == 29.9` ではなく
    `29.900000000000002` を丸めている)。
    """
    return int(Decimal(value).quantize(Decimal(1), rounding=ROUND_HALF_UP))


def baseline_atk_for_enemy_table(level: int) -> int:
    """**敵一覧の「想定撃数」専用**の基準プレイヤー ATK。

    🔴 **per-player の表示に流用しないこと。**

    これは `BattleDisplay.computeAtk(level, weaponAtk, studyLv,
    attackPowerModifier)` に **3 つの仮定**

        weaponAtk = 10 (starter_sword) / studyLv = 0 / attackPowerModifier = 1.0

    を代入して畳んだ簡約式である (`20 + level * 2`)。個人の表示に使うと
    **武器も学習力もジョブも無視した数字**になり、Lv だけ合っていて中身が全部違う
    —— バランス調整の判断材料としては最悪の形 (それらしいが嘘) になる。

    per-player は [compute_player_battle_stats] を使うこと。
    2 つを同じモジュールに置いてあるのは、**片方だけ直される事故を減らすため**。
    """
    return ATK_INTERCEPT + STARTER_SWORD_ATK_BONUS + max(1, level) * ATK_PER_LEVEL


def compute_atk(level: int, weapon_atk: int, study_lv: int,
                attack_power_modifier: float) -> int:
    """`BattleDisplay.computeAtk` のミラー。

    式: `(10 + level * 2 + weaponAtk + studyLv) * attackPowerModifier` を丸め。
    修飾は **最後に 1 回だけ**掛かる (base の内側に入れない)。
    """
    base = ATK_INTERCEPT + level * ATK_PER_LEVEL + weapon_atk + study_lv
    return dart_round(base * attack_power_modifier)


def compute_atb(atb_speed_modifier: float, mental_lv: int) -> float:
    """`BattleDisplay.computeAtb` のミラー。式: `atbSpeedModifier + mentalLv * 0.01`。"""
    return atb_speed_modifier + mental_lv * MENTAL_ATB_PER_LEVEL


def compute_max_hp(level: int, athletic_lv: int) -> int:
    """`_buildPlayerCombatant` の maxHp ミラー。

    式: `playerBaseHp + level * playerHpPerLevel + 運動力Lv * 5`。

    🔴 この式には長らく Python ミラーも契約テストも無かった。
    `playerBaseHp` は 2026-06-13 に 10 -> 20 の 2 倍化を経験している。
    """
    return PLAYER_BASE_HP + level * PLAYER_HP_PER_LEVEL + athletic_lv * ATHLETIC_HP_PER_LEVEL


# ─────────────────────────────────────────────────────────────────────────────
# per-player
# ─────────────────────────────────────────────────────────────────────────────

#: 6 ステータスのうち、戦闘能力に効く 5 つ + 学習力。表示順は admin の並びに使う。
_STAT_KEYS = ('運動力', '学習力', '健康力', '精神力', '創造力', '貢献力')


def collect_player_battle_inputs(player) -> dict:
    """`compute_player_battle_stats` の入力を 1 プレイヤー分そろえる。

    ⚠️ **フォールバックが効いたことを呼び出し側に見せる。**
    黙って 10 を返すと admin では「武器を装備している」と誤読される
    (FEAT-535 Pre-mortem #6)。`*_missing` を立てて画面に出させる。
    """
    stats = {s.name: s.level for s in player.stats.all()}
    missing_stats = [k for k in _STAT_KEYS if k not in stats]

    equipped = next(
        (w for w in player.weapons.all() if w.is_equipped),
        None,
    )
    weapon_missing = equipped is None

    # 🔴 `active_character.job` のみ。`player.active_job` は読まない (FEAT-430)。
    active_char = player.active_character
    job = active_char.job if (active_char is not None and active_char.job_id) else None

    return {
        'level': player.battle.level,
        'stat_levels': {k: stats.get(k, MISSING_STAT_LEVEL) for k in _STAT_KEYS},
        'missing_stats': missing_stats,
        'weapon': None if weapon_missing else equipped.weapon,
        'weapon_atk': UNEQUIPPED_WEAPON_ATK if weapon_missing else equipped.weapon.atk_bonus,
        'weapon_missing': weapon_missing,
        'active_character': active_char,
        'job': job,
        'job_missing': job is None,
        'attack_power_modifier': (
            JOB_MISSING_ATTACK_POWER_MODIFIER if job is None
            else job.attack_power_modifier
        ),
        'atb_speed_modifier': (
            JOB_MISSING_ATB_SPEED_MODIFIER if job is None
            else job.atb_speed_modifier
        ),
    }


def compute_player_battle_stats(player) -> dict:
    """1 プレイヤーの戦闘能力 7 項目を Dart と同じ式で算出する。

    返す dict は `{'inputs': ..., 'stats': ...}`。**入力も一緒に返す**のは、
    結果だけだと admin で「なぜその数字なのか」が読めないため (FEAT-535 §7-2)。

    🔴 これは **今の値** である。`Battle` はプレイヤー側の初期値を保存しないので
    (`enemy_hp_init` / `enemy_atk_init` はあるが player 側は無い)、
    **「あの日負けた時点の ATK」は事後に復元できない** (FEAT-535 §6)。
    """
    i = collect_player_battle_inputs(player)
    lv = i['stat_levels']

    return {
        'inputs': i,
        'stats': {
            'atk': compute_atk(
                level=i['level'],
                weapon_atk=i['weapon_atk'],
                study_lv=lv['学習力'],
                attack_power_modifier=i['attack_power_modifier'],
            ),
            'max_hp': compute_max_hp(level=i['level'], athletic_lv=lv['運動力']),
            'spd': PLAYER_SPD,
            'atb_modifier': compute_atb(
                atb_speed_modifier=i['atb_speed_modifier'],
                mental_lv=lv['精神力'],
            ),
            'hp_regen_per_turn': lv['健康力'] * HEALTH_REGEN_PER_LEVEL,
            'crit_rate': lv['創造力'] * CREATIVITY_CRIT_PER_LEVEL,
            'damage_reduction': lv['貢献力'] * CONTRIBUTION_REDUCTION_PER_LEVEL,
        },
    }
