"""環境変数の「コード / .env.example / render.yaml」の三者不一致をソース走査で縛る。

## なぜテストにするのか

環境変数は **3 箇所に散らばっていて、どれも他を強制しない**:

| 場所 | 役割 | 壊れ方 |
|---|---|---|
| `config/settings.py` 等 | 実際に読む | ここに足しても他に伝わらない |
| `backend/.env.example` | 開発者が .env を作る雛形 | 抜けると「動かない、原因不明」 |
| `render.yaml` | 本番 Blueprint | 消し忘れると dead な値が本番に残る |

実際、本テストを書いた時点で **両方向のズレが 1 件ずつ**あった:

- `MAGIC_LINK_BASE_URL` — SEC-15 L-01 (2026-05-30) で settings.py と
  .env.example からは消したが、**render.yaml に残っていた**。
  FEAT-178 で MagicLink 経路は撤去済なので参照コードはゼロ。
  つまり本番に 3 ヶ月近く dead な env var が注入され続けていた。
- `DATABASE_URL_DIRECT` — build.sh が実際に使うのに .env.example に
  名前すら出てこなかった (`DATABASE_URL` だけ言及されていた)。

どちらも実害は小さいが、**「掃除したつもりで半分残る」は env var で最も
起きやすい**。人が 3 ファイルを目で突き合わせる運用は続かないので機械に縛らせる。

これは `test_error_response_format.py` と同じ発想 —— CLAUDE.md の
「不変条件はテストで縛る」(FEAT-515 の教訓) の適用。
"""
import re
from pathlib import Path

from django.test import TestCase

_BACKEND = Path(__file__).resolve().parents[2]
_REPO_ROOT = _BACKEND.parent
_ENV_EXAMPLE = _BACKEND / '.env.example'
_RENDER_YAML = _REPO_ROOT / 'render.yaml'

# 環境変数を読む全パターン。`\s*` を挟んで改行を許容する
# (1 行 grep が書き方の揺れで 0 件に見えた FEAT-515 の事故の再発防止)。
_ENV_READ = re.compile(
    r"""os\.(?:environ\.get|getenv)\(\s*['"]([A-Z_0-9]+)['"]   # os.environ.get('X') / os.getenv('X')
      | os\.environ\[\s*['"]([A-Z_0-9]+)['"]                   # os.environ['X']
    """,
    re.VERBOSE,
)

# .env.example で「設定できるキー」として書かれているもの。
# コメントアウト (`# FOO=bar`) も雛形としては有効なので `#?` で許容する。
_ENV_EXAMPLE_KEY = re.compile(r"^#?\s*([A-Z_0-9]+)=", re.MULTILINE)

_RENDER_KEY = re.compile(r"^\s*-\s*key:\s*([A-Z_0-9]+)", re.MULTILINE)

# コードは読むが .env.example には **意図的に書かない** もの。
# 理由と解除条件を必ず添えること (allowlist は放置すると腐る)。
_UNDOCUMENTED_ON_PURPOSE: dict[str, str] = {
    'DATABASE_URL': (
        '【2026-07-06 制定】ローカル .env に書かせないことが目的の変数。'
        '書式を載せるとコピペで prod endpoint が .env に残り、accidental migrate を'
        '誘発する (doc/postmortem/20260706_prod_db_schema_drift.md)。'
        '.env.example には「書かない理由」を散文で説明してあり、'
        '代入形式では載せない。—— この方針が変わるまで恒久。'
    ),
    'DATABASE_URL_DIRECT': (
        '同上。DATABASE_URL と対で Neon Direct 接続を指すため、'
        '片方だけ代入形式で載せると「こちらは書いてよい」と誤読される。'
    ),
}


def _iter_python_sources():
    for root in (_BACKEND / 'config', _BACKEND / 'api'):
        for path in sorted(root.rglob('*.py')):
            # 本テスト自身が正規表現リテラルとして env 名を含むので除外する
            if path == Path(__file__).resolve():
                continue
            yield path


def _env_vars_read_by_code() -> dict[str, str]:
    """{変数名: 最初に見つけた場所} を返す。"""
    found: dict[str, str] = {}
    for path in _iter_python_sources():
        text = path.read_text(encoding='utf-8')
        for match in _ENV_READ.finditer(text):
            name = match.group(1) or match.group(2)
            if name not in found:
                line = text[: match.start()].count('\n') + 1
                found[name] = f'{path.relative_to(_REPO_ROOT).as_posix()}:{line}'
    return found


class EnvExampleCompletenessTests(TestCase):
    """コードが読む環境変数は .env.example に必ず載っていること。"""

    def test_every_env_var_read_by_code_is_documented(self):
        documented = set(_ENV_EXAMPLE_KEY.findall(_ENV_EXAMPLE.read_text(encoding='utf-8')))
        missing = {
            name: where
            for name, where in _env_vars_read_by_code().items()
            if name not in documented and name not in _UNDOCUMENTED_ON_PURPOSE
        }

        self.assertEqual(
            missing,
            {},
            '\n\nコードが読んでいるのに backend/.env.example に無い環境変数があります。\n'
            'セットアップした人が「起動はするが一部機能だけ静かに落ちる」状態になります。\n'
            '.env.example に追記するか、意図的に載せないなら\n'
            '_UNDOCUMENTED_ON_PURPOSE に理由付きで追加してください。\n\n'
            + '\n'.join(f'  - {n}  ({w})' for n, w in sorted(missing.items())),
        )

    def test_allowlist_entries_are_still_read_by_code(self):
        """allowlist が実態から取り残されていないこと。

        コードから消えた変数が allowlist に残ると、次にその名前を復活させた人が
        「なぜか検査されない」状態を踏む。
        """
        read = _env_vars_read_by_code()
        # DATABASE_URL_DIRECT は Python ではなく build.sh が読む
        shell_read = (_BACKEND / 'build.sh').read_text(encoding='utf-8')

        stale = [
            name
            for name in _UNDOCUMENTED_ON_PURPOSE
            if name not in read and name not in shell_read
        ]
        self.assertEqual(
            stale,
            [],
            f'\n\n_UNDOCUMENTED_ON_PURPOSE に、もうコードが読んでいない変数が残っています: '
            f'{stale}\nallowlist から削除してください。',
        )


class RenderBlueprintTests(TestCase):
    """render.yaml が dead な環境変数を本番に注入し続けていないこと。"""

    def test_no_dead_env_var_in_render_yaml(self):
        declared = _RENDER_KEY.findall(_RENDER_YAML.read_text(encoding='utf-8'))
        read_by_python = set(_env_vars_read_by_code())
        read_by_shell = (_BACKEND / 'build.sh').read_text(encoding='utf-8')

        dead = [
            name
            for name in declared
            if name not in read_by_python and name not in read_by_shell
        ]

        self.assertEqual(
            dead,
            [],
            '\n\nrender.yaml が宣言しているのに、コードのどこからも読まれていない\n'
            '環境変数があります。機能撤去のときに render.yaml だけ消し忘れた形です\n'
            '(MAGIC_LINK_BASE_URL の前例: FEAT-178 で経路撤去 → SEC-15 L-01 で\n'
            'settings.py と .env.example からは消したが render.yaml に残った)。\n\n'
            'render.yaml から削除してください。**Render dashboard 側は Blueprint と\n'
            '別管理**なので、そちらの環境変数も手動で消す必要があります。\n\n'
            + '\n'.join(f'  - {n}' for n in dead),
        )
