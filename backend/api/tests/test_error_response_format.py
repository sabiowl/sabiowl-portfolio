"""【FEAT-515】エラーレスポンスが新形式に統一されていることをソース走査で縛る。

## なぜソース走査なのか

CLAUDE.md には長らく

> 全 view の旧形式を `error_response()` に一括書換済。
> `backend/api/views/` で `Response({'error'` は 0 件。

と書かれていた。**これは誤り**で、実測すると旧形式が **78 件**残っていた。

0 件に見えたのは、旧形式が**すべて改行を挟んで書かれている**ため:

```python
return Response(               # ← ここで改行するので
    {'error': '...'},          #    "Response({'error'" では 1 件もヒットしない
    status=400,
)
```

人が打つ grep は書き方の揺れに弱い。**正規表現に `\\s*` を入れて構造的に潰す**
のが本テストの役目であり、FEAT-515 の成果物の本体である。

## なぜ形式を統一する必要があるのか

Mobile 側で **code から文言を解決する**には `code` が必要だが、旧形式には
`{'error': 'ダイヤモンドが不足しています'}` のように **code を持たないもの**がある。
統一しないと英語化の経路に乗らない (FEAT-515 §1)。

さらに CLAUDE.md の FEAT-475 Phase 4 は「旧 parser を削除」と書いており、
先に実施すると旧形式の経路が**表示不能**になる。順序の依存がある。

## allowlist

意図的に旧形式を残すものは、**理由と解除条件**を書いてここに載せる。
"""
import re
from pathlib import Path

from django.test import TestCase

_VIEWS = Path(__file__).resolve().parents[1] / 'views'

# 改行・空白を許容する。1 行 grep で 0 件に見えた事故を構造的に防ぐ (docstring 参照)。
#
# `'error': {` は **既に新形式**を `Response()` で手書きしたもの (auth/social.py に 1 件)。
# `error_response()` が持てない追加 top-level key を返しているため意図的に手書きで、
# 形式としては正しい。旧形式と混同しないよう negative lookahead で除外する。
_OLD_FORM = re.compile(r"Response\(\s*\{\s*['\"]error['\"]\s*:\s*(?!\s*\{)")

# key は views/ からの相対パス。値は「なぜ残すか」+「いつ外すか」。
#
# 【FEAT-475 Phase 4 (2026-08-04)】**空にした**。
#
# FEAT-515 Phase 1 では `rest_day.py` (410 スタブ 4 件) を
# 「ユーザーは到達しないので移行の価値なし」として載せていた。
# しかし Phase 4 で Flutter 側の旧形式 parser を削除する前提が
# **「旧形式の生成側がゼロ」**なので、1 ファイルでも残ると parser を消せない。
# 移行コストは 4 行だったため、allowlist を維持するより移行してしまった。
#
# → **ここは空のまま保つ**。追加するときは「なぜ残すか」と「いつ外すか」を
#    必ず書くこと。allowlist は放置すると「検査されない領域」として腐る。
_ALLOWLIST: dict[str, str] = {}


def _iter_view_files():
    for path in sorted(_VIEWS.rglob('*.py')):
        # `_error_helpers.py` は helper の **定義**。`def error_response(` の
        # シグネチャが呼び出しに見えるので除外する。
        if path.name in ('__init__.py', '_error_helpers.py'):
            continue
        yield path


class ErrorResponseFormatTest(TestCase):
    def test_no_legacy_error_response(self):
        """`Response({'error': ...})` が allowlist を除いて 0 件。

        落ちたら `_error_helpers.error_response(code=..., message=...)` に
        書き換えること。**code 文字列は既存のものを変えない** ——
        Mobile が `ApiError.code` で分岐しているものがあり、
        リネームすると例外も出さずに分岐が外れる (FEAT-515 Pre-mortem S1)。
        """
        offenders = []
        for path in _iter_view_files():
            rel = path.relative_to(_VIEWS).as_posix()
            if rel in _ALLOWLIST:
                continue
            src = path.read_text(encoding='utf-8')
            for m in _OLD_FORM.finditer(src):
                line = src.count('\n', 0, m.start()) + 1
                offenders.append(f'{rel}:{line}')

        self.assertEqual(
            offenders, [],
            f'旧形式のエラーレスポンスが {len(offenders)} 件残っている。\n'
            'error_response(code=..., message=...) に書き換えること:\n  '
            + '\n  '.join(offenders[:40]),
        )

    def test_allowlist_entries_are_real_and_explained(self):
        """allowlist の entry が実在し、理由が書かれている。"""
        for rel, reason in _ALLOWLIST.items():
            self.assertTrue(
                (_VIEWS / rel).exists(),
                f'allowlist の {rel} が実在しない (消したなら allowlist からも消す)',
            )
            self.assertTrue(reason.strip(), f'{rel} の理由が空')

    def test_allowlisted_files_still_contain_legacy_form(self):
        """allowlist のファイルに旧形式が**まだある**。

        移行が済んだのに allowlist に残っていると、「除外したつもり」の穴になる。
        """
        stale = []
        for rel in _ALLOWLIST:
            src = (_VIEWS / rel).read_text(encoding='utf-8')
            if not _OLD_FORM.search(src):
                stale.append(rel)
        self.assertEqual(
            stale, [],
            f'旧形式がもう無いのに allowlist に残っている: {stale}',
        )

    def test_every_error_response_has_code_and_message(self):
        """`error_response()` の呼び出しが `code` と `message` を両方持つ。

        `code` が無いと Mobile 側で文言を解決できず、`message` が無いと
        ユーザーに何も出ない。
        """
        missing = []
        for path in _iter_view_files():
            src = path.read_text(encoding='utf-8')
            for m in re.finditer(r'error_response\((.*?)\n\s*\)', src, re.S):
                body = m.group(1)
                line = src.count('\n', 0, m.start()) + 1
                rel = path.relative_to(_VIEWS).as_posix()
                if 'code=' not in body:
                    missing.append(f'{rel}:{line} (code なし)')
                if 'message=' not in body:
                    missing.append(f'{rel}:{line} (message なし)')
        self.assertEqual(missing, [], '\n  '.join(missing[:20]))
