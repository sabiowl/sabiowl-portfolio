"""【FEAT-537 (2026-08-29)】レベルアップ時の配分ポイント付与を **走査で** 縛る。

## なぜ走査なのか —— 手で数えたリストが 6 回連続で漏れた

ユーザー報告は「バトルで勝ってレベルアップしたのに 10pt もらえなかった」。
調べると **3pt は仕様どおり**だったが、その仕様自体が意図を実現していなかった。
さらに **仮メモ変換経路は加算が丸ごと欠落**していた (0pt)。

`allocatable_points` を assert しているテストは **2 ファイルだけで、どちらも
習慣経路**だった。残り 6 経路は 1 件も縛られていない —— 7 本目を足したときに
誰も気付けなかったのはそのためである。

| 回 | 漏れたもの | 見つけた人 |
|:-:|---|---|
| 1 | `Job.job_name_en` | Phase 2E の verify |
| 2 | 2 コマンドの対象 model リスト | 20260802 review |
| 3 | 8 model / 14 field | 実機 QA |
| 4 | `gacha.py` に `get_i18n_field` が 0 件 | BUG-146 (ユーザー報告) |
| 5 | `MaintenanceConfig` の admin (+ 隣に 2 つ) | FEAT-536 の調査 |
| **6** | **本件 (7 経路中 3 経路が壊れていた)** | **実機報告** |

🔴 **定数を 10 に揃えるだけなら、8 本目を書いたときに同じことが起きる。**
本ファイルが FEAT-537 の成果物の本体である。

## 判別子 —— 変数名ではなく「何を呼んでいるか」で決める

| ループ | body が呼ぶもの |
|---|---|
| プレイヤーのレベルアップ | `GameBalance.level_to_max_exp(...)` |
| ステータスのレベルアップ | `apply_stat_level_up_step(stat)` |

この 2 つは **意味的に排他**なので、`battle` / `battle_state` / `locked_battle` /
`stat` といった変数名に依存した脆い判定をしなくてよい (Pre-mortem #2)。

## 🔴 判別できないものは skip せず fail させる (§6-2)

FEAT-536 で見つけた `check_i18n_coverage` は、行が 0 件の model を
`(no records)` で `continue` していたため **gate が緑のまま英語が壊れていた**。
「見なかったことにする」経路を作ると、テストは緑を出し続けながら何も守らない。

本テストは **EXP オーバーフローの形をした while ループ**
(`while X.current_exp >= X.max_exp`) を見つけたのにどちらの helper も
呼んでいない場合、**skip せず fail** する。人間に「これは何のループか」を
判断させ、判別子のほうを更新させる。

⚠️ 逆に、**`level_to_max_exp` を呼ぶループは形に関わらず**プレイヤーの
レベルアップとして扱う。条件の書き方 (`while True:` + `break` 等) を変えて
規約から逃げられないようにするため。
"""
import ast
from pathlib import Path

from django.test import SimpleTestCase

# backend/api/
_API_ROOT = Path(__file__).resolve().parent.parent

# 走査対象外。テストは規約の適用先ではなく、migration は過去の凍結された記録。
_SKIP_DIR_NAMES = {'tests', 'migrations', '__pycache__'}

_POINTS_CONST = 'GameBalance.ALLOCATABLE_POINTS_PER_LEVEL'
_POINTS_FIELD = 'allocatable_points'

# レベルアップループが書き換えるプレイヤー field。
# `save(update_fields=[...])` がこのどれかを含むなら、**同じ save で
# allocatable_points も永続化されなければならない**。
_LEVEL_UP_FIELDS = frozenset({'current_exp', 'level', 'max_exp'})


def _iter_source_files():
    for path in sorted(_API_ROOT.rglob('*.py')):
        if any(part in _SKIP_DIR_NAMES for part in path.relative_to(_API_ROOT).parts):
            continue
        yield path


def _dotted(node) -> str:
    """`ast.Attribute` / `ast.Name` を `'A.b.c'` 形式にする。読めなければ ''。"""
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
        return '.'.join(reversed(parts))
    return ''


def _called_names(node) -> set:
    """`node` 以下で呼ばれている関数名 (dotted と末尾の両方) を集める。"""
    names = set()
    for sub in ast.walk(node):
        if isinstance(sub, ast.Call):
            dotted = _dotted(sub.func)
            if dotted:
                names.add(dotted)
                names.add(dotted.rsplit('.', 1)[-1])
    return names


def _attr_names(node) -> set:
    return {s.attr for s in ast.walk(node) if isinstance(s, ast.Attribute)}


def _looks_like_exp_overflow(while_node) -> bool:
    """`while X.current_exp >= X.max_exp:` の形をしているか。"""
    return {'current_exp', 'max_exp'}.issubset(_attr_names(while_node.test))


def _points_augassigns(node):
    """`<obj>.allocatable_points += <expr>` を列挙する。"""
    for sub in ast.walk(node):
        if (isinstance(sub, ast.AugAssign)
                and isinstance(sub.op, ast.Add)
                and isinstance(sub.target, ast.Attribute)
                and sub.target.attr == _POINTS_FIELD):
            yield sub


def _save_calls(node):
    """`<obj>.save(...)` を `(obj, update_fields or None, lineno)` で列挙する。

    `update_fields` を渡していない (= 全 field 保存) 場合は None を返す。
    """
    for sub in ast.walk(node):
        if not (isinstance(sub, ast.Call)
                and isinstance(sub.func, ast.Attribute)
                and sub.func.attr == 'save'):
            continue
        obj = _dotted(sub.func.value)
        fields = None
        for kw in sub.keywords:
            if kw.arg != 'update_fields':
                continue
            if isinstance(kw.value, (ast.List, ast.Tuple, ast.Set)):
                fields = {
                    e.value for e in kw.value.elts
                    if isinstance(e, ast.Constant) and isinstance(e.value, str)
                }
            else:
                # 変数経由等。読めないので「明示していない」扱いにする
                # —— ここを red にすると直しようがない false red になる。
                fields = None
        yield obj, fields, sub.lineno


def _enclosing_functions(tree):
    """`{while ノード: 直近の関数定義ノード}` を返す。"""
    owner = {}
    for func in ast.walk(tree):
        if not isinstance(func, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        for sub in ast.walk(func):
            if isinstance(sub, ast.While):
                # ast.walk は外側から回るので、後勝ちで「最も内側」になる。
                owner[sub] = func
    return owner


class AllocatablePointsContractTest(SimpleTestCase):
    """プレイヤーのレベルアップループが全経路で規約を満たす。"""

    def _scan(self):
        """`(player_loops, stat_loops, unknown_loops)` を返す。

        各要素は `(rel, lineno, while_node, enclosing_func, module_tree)`。
        """
        player, stat, unknown = [], [], []
        for path in _iter_source_files():
            rel = path.relative_to(_API_ROOT.parent).as_posix()
            tree = ast.parse(path.read_text(encoding='utf-8'))
            owners = _enclosing_functions(tree)
            for node in ast.walk(tree):
                if not isinstance(node, ast.While):
                    continue
                names = _called_names(node)
                is_player = 'level_to_max_exp' in names
                is_stat = 'apply_stat_level_up_step' in names
                entry = (rel, node.lineno, node, owners.get(node), tree)
                if is_player and is_stat:
                    unknown.append(entry)
                elif is_player:
                    player.append(entry)
                elif is_stat:
                    stat.append(entry)
                elif _looks_like_exp_overflow(node):
                    unknown.append(entry)
        return player, stat, unknown

    @staticmethod
    def _save_candidates(scope_node, target):
        """`target` の save のうち **レベルアップを永続化しているもの**を返す。

        🔵 バトル敗北時の `save(update_fields=['battle_charges'])` のように
        レベルアップ由来の field を 1 つも保存していない save は候補に入れない
        —— そこは pt を足していないので、要求すると意味の無い red になる
        (Pre-mortem #8)。
        """
        out = []
        for obj, fields, line in _save_calls(scope_node):
            if target and obj and obj != target:
                continue                      # 別オブジェクト (economy 等)
            if fields is None:
                out.append((None, line))      # 全 field 保存 → pt も入る
            elif fields & _LEVEL_UP_FIELDS:
                out.append((fields, line))
        return out

    @staticmethod
    def _loop_target(while_node) -> str:
        """`while X.current_exp >= X.max_exp` の `X` を返す。読めなければ ''。"""
        for sub in ast.walk(while_node.test):
            if isinstance(sub, ast.Attribute) and sub.attr == 'current_exp':
                return _dotted(sub.value)
        return ''

    # ── 0: 走査そのものの健全性 ──────────────────────────────────────

    def test_scan_finds_every_level_up_loop(self):
        """走査が実際にループを見つけている。

        判別子が壊れて 0 件になると、以下のテストは **全部緑のまま何も
        検出しなくなる**。件数ではなくファイル名で確認する
        —— 「N 件見た」では、別のものを N 件数えているだけを見逃す。
        """
        player, stat, _ = self._scan()
        self.assertEqual(
            {rel for rel, _, _, _, _ in player},
            {
                'api/services/challenge_reward_service.py',
                'api/services/habit_count_service.py',
                'api/services/puzzle_world_service.py',
                'api/views/battle/finish.py',
                'api/views/free_memo.py',
                'api/views/gacha.py',
                'api/views/timeline.py',
            },
            'プレイヤーのレベルアップ経路の集合が変わった。'
            '経路を増減させたなら本テストを更新すること '
            '(**増やしたのに気付かないこと**を防ぐための集合である)',
        )
        self.assertEqual(
            {rel for rel, _, _, _, _ in stat},
            {'api/views/habits.py', 'api/views/player.py'},
            'ステータス経路の集合が変わった。'
            'プレイヤー経路と取り違えていないか確認すること (Pre-mortem #2)',
        )

    def test_no_unclassifiable_level_up_loops(self):
        """🔴 判別できない EXP オーバーフローループが無い (§6-2)。

        FEAT-536 の `check_i18n_coverage` は行 0 件を `(no records)` で
        `continue` し、**gate が緑のまま英語が壊れていた**。
        黙って skip する経路を作らない。
        """
        _, _, unknown = self._scan()
        self.assertEqual(
            [f'{rel}:{lineno}' for rel, lineno, _, _, _ in unknown], [],
            '\n判別できない while ループがある。'
            'level_to_max_exp / apply_stat_level_up_step のどちらも呼んでいない。'
            '\nプレイヤーのレベルアップなら本テストの規約に従わせ、'
            'そうでなければ本テストの判別子を更新すること。',
        )

    # ── 1 / 2: ループ本体の加算 ──────────────────────────────────────

    def test_every_player_loop_grants_the_shared_constant(self):
        """🔴 全経路が `ALLOCATABLE_POINTS_PER_LEVEL` をちょうど 1 回加算する。

        - 加算が無い     → 「レベルは上がったのに 0pt」(仮メモ変換の実害)
        - リテラル直書き → 定数を変えても追従しない
        - 別の定数 / 変数 → 経路差が残る (本 FEAT が撤回した傾斜)
        """
        player, _, _ = self._scan()
        offenders = []
        for rel, lineno, node, _func, _tree in player:
            assigns = list(_points_augassigns(node))
            if not assigns:
                offenders.append(f'{rel}:{lineno} — allocatable_points の加算が無い')
                continue
            if len(assigns) > 1:
                offenders.append(f'{rel}:{lineno} — 加算が {len(assigns)} 箇所ある')
            for a in assigns:
                if isinstance(a.value, ast.Constant):
                    offenders.append(
                        f'{rel}:{a.lineno} — リテラル {a.value.value!r} の直書き')
                    continue
                dotted = _dotted(a.value)
                if dotted != _POINTS_CONST:
                    offenders.append(
                        f'{rel}:{a.lineno} — {dotted or "式"} を加算している '
                        f'(期待: {_POINTS_CONST})')
        self.assertEqual(
            sorted(offenders), [],
            '\n🔴 レベルアップ時の配分ポイント付与が規約を満たしていない:\n  '
            + '\n  '.join(sorted(offenders))
            + f'\n\n各ループ本体に `<obj>.{_POINTS_FIELD} += {_POINTS_CONST}` を'
              'ちょうど 1 つ置くこと。',
        )

    # ── 3: 永続化 ────────────────────────────────────────────────────

    def test_level_up_saves_persist_the_points(self):
        """🔴 レベルアップを保存する `save()` が pt も保存している。

        加算しても `update_fields` から漏れていれば **DB には入らない**。
        仮メモ変換はまさにこの形だった (加算も無ければ field も無い)。

        判定は「`current_exp` / `level` / `max_exp` のどれかを保存している
        save は、`allocatable_points` も保存していること」。

        🔵 バトル敗北時の `save(update_fields=['battle_charges'])` のように
        **レベルアップ由来の field を 1 つも保存していない save** は対象外
        —— そこは pt を足していないので、要求すると意味の無い red になる
        (Pre-mortem #8)。
        """
        player, _, _ = self._scan()
        offenders = []
        for rel, lineno, node, func, tree in player:
            if func is None:
                offenders.append(f'{rel}:{lineno} — 関数の外にレベルアップループがある')
                continue
            target = self._loop_target(node)

            # まず関数内を見て、1 件も無ければモジュール全体に広げる。
            # `habit_count_service._apply_player_level_up_loop` は
            # **ループが helper、save は呼び出し側**という分業をしており
            # (docstring に「save() は呼び出し側で」と明記)、関数内だけを
            # 見ると false red になる。
            candidates = self._save_candidates(func, target)
            scope = '関数内'
            if not candidates:
                candidates = self._save_candidates(tree, target)
                scope = 'モジュール内'
            if not candidates:
                offenders.append(
                    f'{rel}:{lineno} — レベルアップを永続化する save が'
                    f'{scope}に見つからない')
                continue
            for fields, save_line in candidates:
                if fields is not None and _POINTS_FIELD not in fields:
                    offenders.append(
                        f'{rel}:{save_line} — update_fields に '
                        f'{_POINTS_FIELD!r} が無い (保存: {sorted(fields)})')
        self.assertEqual(
            sorted(offenders), [],
            '\n🔴 加算した配分ポイントが DB に入らない:\n  '
            + '\n  '.join(sorted(offenders)),
        )

    # ── 4: 定数側 ────────────────────────────────────────────────────

    def test_old_per_route_constants_are_gone(self):
        """旧 4 定数が残っていない。

        別名で残すと、8 本目を書く人が旧名を拾って同じ穴が再発する。
        """
        old = (
            'ALLOCATABLE_POINTS_HABIT',
            'ALLOCATABLE_POINTS_TIMELINE',
            'ALLOCATABLE_POINTS_GACHA_EXP',
            'ALLOCATABLE_POINTS_CHALLENGE_EXP',
        )
        found = []
        for path in _iter_source_files():
            text = path.read_text(encoding='utf-8')
            rel = path.relative_to(_API_ROOT.parent).as_posix()
            found += [f'{rel}: {name}' for name in old if name in text]
        self.assertEqual(
            sorted(found), [],
            '\n旧の経路別定数が残っている:\n  ' + '\n  '.join(sorted(found)),
        )

    def test_shared_constant_exists_and_is_ten(self):
        """定数が 1 本あり、値が 10 である。"""
        from api.constants import GameBalance

        self.assertEqual(GameBalance.ALLOCATABLE_POINTS_PER_LEVEL, 10)
