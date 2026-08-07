"""【FEAT-515 Phase 2 (2026-08-04)】エラー code の Backend ↔ ARB 同期ガード。

## なぜ必要か

Phase 2 で「`ApiError.code` から Flutter 側の ARB を引く」方式を入れた。
この方式には **日本語ユーザーにだけ効く落とし穴**がある:

  ARB は locale を問わず引かれるので、**日本語表示も ARB の値になる**。

つまり Backend の `message='コインが足りないようですね 🪶'` を誰かが書き換えても、
画面に出るのは ARB の古い文言のままになる。**例外も出ず、テストも落ちない。**
英語だけ直して日本語を放置する逆パターンも同様に静かに壊れる。

さらに code をリネームすると、対応表から黙って外れて日本語に戻る
(指示書 §5 Pre-mortem S1 と同じ構造。Phase 1 で `battle_service.dart` に
実際に起きていた)。

本テストは 2 つを縛る:

  1. Flutter が引いている code が **Backend に実在する**こと
  2. その code の **ja ARB 値が Backend の message と 1 文字も違わない**こと

## 真実値の所在

  - code と message: `backend/api/views/**/*.py` の `error_response(...)`
  - 対応表:         `mobile/lib/core/api/api_error_messages.dart` の switch
  - ja 文言:        `mobile/lib/l10n/app_ja.arb`
"""
import ast
import json
import re
from pathlib import Path

from django.test import SimpleTestCase

_BACKEND = Path(__file__).resolve().parent.parent.parent   # backend/
_ROOT    = _BACKEND.parent                                  # repo root
_VIEWS   = _BACKEND / 'api' / 'views'
_DART    = _ROOT / 'mobile' / 'lib' / 'core' / 'api' / 'api_error_messages.dart'
_ARB_JA  = _ROOT / 'mobile' / 'lib' / 'l10n' / 'app_ja.arb'

# ---------------------------------------------------------------------------
# placeholder を含むため「完全一致」で比較できない code。
#
# Backend が f-string で値を埋めているものは、ARB 側では ICU placeholder /
# select になる。文字列としては一致しないので値比較の対象から外す。
# **存在チェック (①) は通す** ので、リネームは引き続き検出される。
# ---------------------------------------------------------------------------
_PLACEHOLDER_CODES = {
    # message=f'{name}チケットが足りないようですね 🪶' → ICU select(ticketType)
    'gacha_pull_not_enough_tickets',
    # message=f'ダイヤが足りません (必要: {…}、所持: {…}) 🪶' → {needed} / {owned}
    'gacha_redo_insufficient_diamonds',
}


def _backend_messages() -> dict[str, set[str]]:
    """`error_response(code=..., message=...)` を AST で集める。

    同じ code が複数箇所にある場合があるので `code -> {message, ...}` で返す。
    f-string は文字列にならないので `None` を入れて呼び出し側で判別する。
    """
    found: dict[str, set[str]] = {}
    for path in sorted(_VIEWS.rglob('*.py')):
        tree = ast.parse(path.read_text(encoding='utf-8'))
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            fname = getattr(node.func, 'id', None) or getattr(node.func, 'attr', None)
            if fname != 'error_response':
                continue
            kw = {k.arg: k.value for k in node.keywords}
            code_node, msg_node = kw.get('code'), kw.get('message')
            if not isinstance(code_node, ast.Constant):
                continue                      # f-string の code は対象外
            msg = msg_node.value if isinstance(msg_node, ast.Constant) else None
            found.setdefault(code_node.value, set()).add(msg)
    return found


def _dart_code_to_arb_key() -> dict[str, str]:
    """`api_error_messages.dart` の switch から `code -> ARB key` を復元する。

    `case 'a':` `case 'b':` `return l.KEY;` の形なので、
    return に当たるまで case を貯めてから対応付ける。
    """
    src = _DART.read_text(encoding='utf-8')
    mapping: dict[str, str] = {}
    pending: list[str] = []
    for line in src.split('\n'):
        m_case = re.match(r"\s*case '([a-z0-9_]+)':", line)
        if m_case:
            pending.append(m_case.group(1))
            continue
        m_ret = re.search(r'return l\.(\w+)', line)
        if m_ret and pending:
            for c in pending:
                mapping[c] = m_ret.group(1)
            pending = []
    return mapping


def _dart_declared_codes() -> list[str]:
    """`kLocalizedApiErrorCodes` の列挙を読む。"""
    src = _DART.read_text(encoding='utf-8')
    m = re.search(r'kLocalizedApiErrorCodes = <String>\[(.*?)\];', src, re.S)
    assert m, 'kLocalizedApiErrorCodes が見つかりません'
    return re.findall(r"'([a-z0-9_]+)'", m.group(1))


class ErrorCodeL10nSyncTest(SimpleTestCase):
    """Flutter の code→ARB 対応が Backend と一致しているか。"""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.backend = _backend_messages()
        cls.mapping = _dart_code_to_arb_key()
        cls.declared = _dart_declared_codes()
        # arb は BOM 付き UTF-8 なので utf-8-sig で読む
        cls.arb = {
            k: v for k, v in
            json.loads(_ARB_JA.read_text(encoding='utf-8-sig')).items()
            if not k.startswith('@') and isinstance(v, str)
        }

    def test_dart_switch_and_declared_list_agree(self):
        """`kLocalizedApiErrorCodes` と switch の case が一致する。

        列挙だけ足して switch を書き忘れると、テストは「全 code 解決 OK」に
        見えるのに実際は default に落ちる (= 日本語のまま) 状態になる。
        """
        self.assertEqual(
            sorted(self.declared), sorted(self.mapping),
            msg='kLocalizedApiErrorCodes と switch の case がずれています。\n'
                f'列挙のみ: {sorted(set(self.declared) - set(self.mapping))}\n'
                f'switch のみ: {sorted(set(self.mapping) - set(self.declared))}',
        )

    def test_all_mapped_codes_exist_in_backend(self):
        """Flutter が引いている code が Backend に実在する。

        code をリネームすると対応表から黙って外れ、英語 UI で日本語に戻る。
        例外は出ないので、これが無いと気付けない (Pre-mortem S1)。
        """
        missing = [c for c in self.mapping if c not in self.backend]
        self.assertEqual(
            missing, [],
            msg='Flutter が引いている code が Backend に存在しません。\n'
                'code をリネームしたなら api_error_messages.dart も同時に直してください。\n'
                f'{missing}',
        )

    def test_ja_arb_matches_backend_message(self):
        """ja ARB の文言が Backend の message と完全一致する。

        **ここがずれると日本語ユーザーの表示が黙って変わる。**
        ARB は locale を問わず引かれるので、ja も ARB の値が出るため。
        """
        mismatches = []
        for code, key in sorted(self.mapping.items()):
            if code in _PLACEHOLDER_CODES:
                continue
            if code not in self.backend:
                continue                      # 上のテストが報告する
            arb_value = self.arb.get(key)
            self.assertIsNotNone(
                arb_value, msg=f'ARB key {key} (code={code}) が app_ja.arb にありません')

            for msg in self.backend[code]:
                if msg is None:
                    mismatches.append(
                        f'{code}: Backend が f-string になっています。'
                        f'placeholder 対応するか _PLACEHOLDER_CODES に追加してください')
                elif msg != arb_value:
                    mismatches.append(
                        f'{code} ({key})\n'
                        f'  Backend: {msg!r}\n'
                        f'  ja ARB : {arb_value!r}')

        self.assertEqual(
            mismatches, [],
            msg='Backend の message と ja ARB がずれています。\n'
                'ARB は locale を問わず引かれるので、ずれると **日本語表示が'
                '黙って変わります**。どちらかに揃えてください。\n\n'
                + '\n'.join(mismatches),
        )

    def test_placeholder_exemptions_are_still_needed(self):
        """`_PLACEHOLDER_CODES` の除外が過剰になっていない (allowlist の腐敗防止)。

        Backend が f-string をやめたら除外も外す。放置すると
        「除外リストに入っているから検査されない」code が増えていく。
        """
        stale = [
            c for c in _PLACEHOLDER_CODES
            if c in self.backend and None not in self.backend[c]
        ]
        self.assertEqual(
            stale, [],
            msg='Backend が f-string でなくなったため、除外が不要になりました。\n'
                f'_PLACEHOLDER_CODES から削除してください: {stale}',
        )

    def test_coverage_is_not_silently_shrunk(self):
        """対象 code 数が v1.1 の想定 (20 件) を下回っていない。"""
        self.assertGreaterEqual(
            len(self.declared), 20,
            msg='v1.1 は上位 20 code を対象と決めています (指示書 §3.2)。'
                '減らす場合は指示書と doc/design/backend_i18n.md も更新してください',
        )
