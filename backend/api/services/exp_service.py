import logging

from django.db import transaction
from django.utils import timezone

from ..models import CharacterStat, PlayerProfile, Notification
from ..constants import GameBalance

_logger = logging.getLogger(__name__)

# 後方互換エイリアス（既存 import を壊さないため維持）
EXP_PER_COUNT      = GameBalance.EXP_PER_COUNT
GOLD_PER_COUNT     = GameBalance.GOLD_PER_COUNT
# 【FEAT-213】値の型が `dict[str, str]` → `dict[str, list[tuple[str, float]]]` に変わった。
# 旧 `.get(cat)` で stat 名を直接得る使い方は不可。`get_stat_allocations()` を使うこと。
_CATEGORY_STAT_MAP = GameBalance.CATEGORY_STAT_MAP


def get_stat_allocations(category: str, exp: int) -> list[tuple[str, int]]:
    """【FEAT-213 / FEAT-223】カテゴリと EXP から、`(ステータス名, 加算 EXP)` のリストを返す。

    比率 × EXP を `int()` で切り捨てて整数化したあと、**余りを最大比率の stat に加算** して
    **合計が元 EXP と完全一致** するように補正する（FEAT-223 で旧 `round()` 経路の
    整数丸め誤差を解消、機能レビュー 20260515 P2-1 = 「サイレント喪失バグ #3」クローズ）。

    例:
        >>> get_stat_allocations('運動', 10)
        [('運動力', 10)]
        >>> get_stat_allocations('体力', 10)
        [('運動力', 5), ('健康力', 5)]
        >>> get_stat_allocations('その他', 10)   # FEAT-223 修正後
        [('運動力', 5), ('学習力', 1), ('健康力', 1),
         ('精神力', 1), ('創造力', 1), ('貢献力', 1)]
        # → int(10/6)=1 を 6 stat に配分（合計 6） → 余り 4 を運動力（先頭）に加算

    「その他」のように全 stat が同比率の場合、`max(...)` は **最初のインデックス** を返すため
    余りは運動力に集中する。EXP 10 を 100 回累積しても運動力に +100 程度の偏り（レベル 1 分以下）
    に留まるため、シンプル案を採用。完全均等が必要なら将来ラウンドロビン化を検討。

    未マップカテゴリ（旧 'メンタル' 等で migration 未実行など想定外ケース）の場合は
    空リストを返す（呼び出し側でゼロ加算扱い）。
    """
    mappings = _CATEGORY_STAT_MAP.get(category)
    if not mappings:
        return []
    # 【FEAT-223】int() で切り捨てて余りを最大比率 stat に加算 → 合計を完全保証。
    # 旧 `round()` 経路では「その他」(6 stat × 1/6) で EXP 10 → 12（+2 余分）/
    # EXP 20 → 18（-2 漏れ）など微小誤差が発生していた。
    allocations = [(stat_name, int(exp * ratio)) for stat_name, ratio in mappings]
    remainder = exp - sum(value for _, value in allocations)
    if remainder != 0:
        # 最大比率（同率の場合は最初の）stat に余りを加算する。
        # max() の同率タイブレークは Python 仕様で最初に見つかった idx を返す。
        top_idx = max(range(len(mappings)), key=lambda i: mappings[i][1])
        name, value = allocations[top_idx]
        allocations[top_idx] = (name, value + remainder)
    return allocations


def calc_stat_bonus_exp(player, category: str, exp_gain: int) -> int:
    """【FEAT-213】カテゴリにマップされたステータスの加重平均レベルで bonus EXP を算出する。

    旧（FEAT-201）は単一 stat の level から `min(level * 0.05, 0.50)` 倍を加算していた。
    分散マッピングでは比率で重み付けした平均レベルを使う。100% マッピング側
    （'運動' / '美容' / '健康' / '精神' / '創造' / '社交' / '創造'）では旧挙動と完全等価。

    Returns:
        bonus EXP（整数、未マップカテゴリは 0）。
    """
    mappings = _CATEGORY_STAT_MAP.get(category)
    if not mappings:
        return 0
    stat_names = [s for s, _r in mappings]
    stats = {
        s.name: s for s in
        CharacterStat.objects.filter(player=player, name__in=stat_names)
    }
    weighted_level = sum(
        stats[name].level * ratio
        for name, ratio in mappings
        if name in stats
    )
    return round(exp_gain * min(weighted_level * 0.05, 0.50))


def calc_exp_gain(habit, player) -> int:
    """難易度倍率を考慮したEXP獲得量を返す。

    【FEAT-334 (2026-05-27)】旧 LEGENDARY_UNLOCK_LEVEL=20 ゲート (Player Lv 20 未達時
    に legendary を normal degrade する隠れた減速) を撤廃。新ゲートは
    `services/habit_slot_service.calc_legendary_slots(player)` (6 軸 Lv 5 ALL で +1)
    が `HabitListCreateView.post` で適用するため、ここに到達した時点で legendary は
    full multiplier (5.0) を適用してよい。`player` 引数は API 互換のため残置 (将来
    stat 連動の EXP ブースト等で参照する可能性あり)。
    """
    mult = GameBalance.DIFFICULTY_MULTIPLIER.get(habit.difficulty, 1.0)
    return max(1, round(GameBalance.EXP_PER_COUNT * mult))


def apply_xp_boost_if_active(player, exp_gain: int) -> int:
    """【FEAT-318 (2026-06-13 再活性化)】XP ブースト有効時、EXP を ×1.5 する。

    `player.xp_boost_active_until` が現在時刻より未来なら `round(exp_gain * 1.5)` を返す。
    対象 3 経路: 習慣達成 (habit_count_service)・バトル勝利 (battle.py)・
    タイムライン完了 (timeline.py)。ガチャ報酬 (gacha.py の `_apply_reward`
    reward_type=='exp') は対象外 (Pre-mortem #4、ブースト自体がガチャ排出物のため
    自己参照を避ける)。

    Pre-mortem #3: `int()` ではなく `round()` を使う（端数 EXP の取りこぼし防止）。
    """
    if player.economy.xp_boost_active_until and player.economy.xp_boost_active_until > timezone.now():
        return round(exp_gain * 1.5)
    return exp_gain


def award_diamond_if_first_today(player, today) -> bool:
    """
    今日初めての達成ボーナスとして ダイヤ +1 を付与する。
    select_for_update で行ロックを取得し、同時リクエストによる二重付与を防ぐ。
    戻り値: 付与されたら True、スキップなら False
    """
    with transaction.atomic():
        locked = PlayerProfile.objects.select_for_update().get(pk=player.pk)
        locked_eco = locked.economy
        if locked_eco.diamond_bonus_date == today:
            return False
        locked_eco.diamonds       += 1
        locked_eco.diamonds_total += 1
        locked_eco.diamond_bonus_date = today
        locked_eco.save(update_fields=['diamonds', 'diamonds_total', 'diamond_bonus_date'])
    return True


# 【2026-07-09 レビュー §5 P3 対応】CharacterStat Lv UP 時 max_exp 増加倍率の単一真実値。
#
# 以前は `int(max_exp * 1.2)` が 3 経路に直書きされていた:
#   1. habits.py:156 (Habit 完了 → auto_allocate_by_ratio 内 while ループ)
#   2. player.py:424 (StatUp API 手動配分 while ループ)
#   3. admin.py (admin auto-recompute helper)
# habits.py の 1.2 が将来変更された際、他 2 経路が silent drift するリスク
# (機能レビュー 20260709 §5 で P3 指摘)。本定数 + `apply_stat_level_up_step`
# ヘルパーを 3 経路すべてが参照する形にして drift 経路を構造的に消滅させる。
#
# 【2026-08-07】3 番目の admin 逆算ヘルパーは本ファイルへ移設し
# `stat_max_exp_at_level` に改名 (下記)。admin.py は import して使うだけになり、
# 「ゲームの計算式は exp_service にしかない」状態になった。
#
# 契約テスト: tests/test_character_stat_level_up_contract.py が
# `apply_stat_level_up_step` (順方向) と `stat_max_exp_at_level` (逆算) の
# binding を lock (Lv 1-25 で完全一致を assert)。
# 将来 1.2 を変更する場合は本定数のみ書き換える。
STAT_LEVEL_UP_MULTIPLIER = 1.2


def apply_stat_level_up_step(stat) -> None:
    """CharacterStat の Lv UP を 1 反復ぶんだけ反映 (level +1 / current_exp -= max_exp / max_exp *= 1.2)。

    真実値: このロジックはここに集約する。Habit 完了経路 / StatUp API 経路 /
    Admin 自動再計算経路すべてで本ヘルパー (または `STAT_LEVEL_UP_MULTIPLIER`) を
    使うこと (§5 P3、機能レビュー 20260709)。

    呼び出し側で while ループを回す想定 (crystal 付与や save() 判断は caller 側)。
    """
    stat.level += 1
    stat.current_exp -= stat.max_exp
    stat.max_exp = int(stat.max_exp * STAT_LEVEL_UP_MULTIPLIER)


# CharacterStat.max_exp のモデル既定値 (models/player.py: default=100) と同期。
STAT_INITIAL_MAX_EXP = 100


def stat_max_exp_at_level(level: int) -> int:
    """指定 level の CharacterStat が本来持つべき max_exp を返す。

    `PlayerBattleState.max_exp` (`level * 70 + 30` の純関数) と違い、
    `CharacterStat.max_exp` は `apply_stat_level_up_step` が毎 Lv UP で
    `int(max_exp * 1.2)` を積む **compound int() 切り捨ての履歴依存値**。
    `int(100 * 1.2**(N-1))` の一発計算とは Lv5 以降で誤差が積み上がるため、
    同じ iteration を回して再現する必要がある。

        Lv1=100 / Lv5=206 / Lv10=511 / Lv15=1269 / Lv20=3154 ...

    ## 用途 (2026-08-07 に admin.py から移設)

    support が admin で「level を +5」した際、max_exp を正しい値へ手で
    合わせるのは実質不可能 (公式で暗算できない)。ずれたまま保存すると
    次の EXP 加算で while ループが不意に複数回まわり、FEAT-379 結晶
    (希少報酬) が意図せず連鎖付与される。admin は保存時に本関数で
    max_exp を強制上書きしてこの drift 経路を塞いでいる
    (`CharacterStatAdmin.save_model` / `PlayerStatsMatrixAdmin.save_formset`)。

    元は `admin.py` に `_recalc_character_stat_max_exp` として置かれていたが、
    ゲームの計算式が presentation 層に住んでいる状態だったため
    `apply_stat_level_up_step` の隣へ移した。この 2 つは同じ倍率を共有する
    「順方向」と「逆算」の対で、離れていると drift する。

    契約テスト: `tests/test_character_stat_level_up_contract.py` が Lv 1-25 で
    game 経路 (`apply_stat_level_up_step`) との完全一致を lock している。
    """
    if level < 1:
        return STAT_INITIAL_MAX_EXP
    value = STAT_INITIAL_MAX_EXP
    for _ in range(level - 1):
        value = int(value * STAT_LEVEL_UP_MULTIPLIER)
    return value


def _award_crystal_on_stat_level_up(stat, player) -> 'str | None':
    """【FEAT-379 (2026-05-29)】ステータス Lv UP 時に該当結晶 +1 を加算する。

    呼び出し元の `transaction.atomic()` + `select_for_update()` ロック内で実行されること
    (Pre-mortem #2: PlayerProfile のレンデブー順序遵守)。

    Returns:
        付与した結晶の英語キー (例: 'exercise')、マッピングなしなら None。
    """
    field_name = GameBalance.STAT_NAME_TO_CRYSTAL_FIELD.get(stat.name)
    if field_name is None:
        return None  # ガード: STAT_NAMES と不整合のケースはスキップ
    current = getattr(player, field_name, 0) or 0
    setattr(player, field_name, current + 1)
    player.save(update_fields=[field_name])
    return GameBalance.STAT_NAME_TO_CRYSTAL_KEY.get(stat.name)


def create_default_stats(player):
    """【FEAT-171 / FEAT-213 / FEAT-223】新規プレイヤーに初期ステータス 6 種を作成する。

    `GameBalance.STAT_NAMES` で定義された 6 ステータス（運動力 / 学習力 / 健康力 /
    精神力 / 創造力 / 貢献力）を `get_or_create` で冪等的に作成する。FEAT-171 で
    DEX（創造力）+ CHA（貢献力）を追加して 4 種 → 6 種に拡張済（旧 docstring は
    FEAT-223 で 4→6 種に追従修正）。既存プレイヤーへの再実行も安全。
    """
    for stat_name in GameBalance.STAT_NAMES:
        CharacterStat.objects.get_or_create(
            player=player,
            name=stat_name,
            defaults={'level': 1, 'current_exp': 0, 'max_exp': 100},
        )


# ── タイムライン予定の EXP テーブル ─────────────────────────────────────
# 【FEAT-216】FEAT-213 で TimelineEvent.category を Japanese 11 値に拡張した
# 後、本マップが英語 6 値（'habit'/'work'/'health'/'social'/'rest'/'other'）の
# まま取り残されており、1 件もマッチせず常に default 10 を返す「サイレント喪失
# バグ #2」が発生していた（機能レビュー 20260515 P0-1）。
#
# Easy 習慣（EXP_PER_COUNT = 20）を基準に設定し、'休息' のみ意図的に低 EXP を
# 維持（CLAUDE.md「停滞・休息を肯定する」哲学）。default 10 は将来カテゴリが
# 拡張された場合の救済として残す。
_TIMELINE_EXP_MAP = {
    # 能動的活動（Easy 習慣と同等）
    '運動':   20,
    '体力':   20,
    '学習':   20,
    '仕事':   20,
    '創造':   20,
    # 中位（受動寄り / 補助的活動）
    '美容':   15,
    '健康':   15,
    '精神':   15,
    '社交':   15,
    # 維持: 休息は意図的に低 EXP（CLAUDE.md「停滞・休息を肯定する」哲学を保持）
    '休息':   5,
    # 既定救済
    'その他': 10,
}


def calc_timeline_exp(event) -> int:
    """タイムラインイベントのカテゴリに応じた EXP を返す。

    未知カテゴリは default 10 にフォールバック（将来 11 値が拡張された場合の救済）。
    """
    return _TIMELINE_EXP_MAP.get(event.category, 10)
