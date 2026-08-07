"""【FEAT-489 Phase 3】native English reviewer への受け渡し用 CSV 変換ツール。

## なぜ必要か

`app_en.arb` は 1,380 key の JSON で、非エンジニアのライターに直接編集させると
確実に壊れる (カンマ / エスケープ / BOM / placeholder の破壊)。ライターには
スプレッドシートで作業してもらい、**取り込みは機械で行う**。

placeholder (`{count}` 等) は「絶対に触らない列」として原文を併記し、
import 側で「編集後に placeholder が消えていないか」を検証する。

## 使い方

```powershell
# 1. 発注前: レビュー用 CSV を書き出す
python scripts/arb_review_export.py export

# 2. 納品後: 編集済み CSV を arb に取り込む (dry-run で差分確認してから)
python scripts/arb_review_export.py import path/to/reviewed.csv --dry-run
python scripts/arb_review_export.py import path/to/reviewed.csv
```

## CSV の列

| 列 | 説明 | ライターの操作 |
|---|---|---|
| key | ARB key | **編集禁止** |
| tier | `sabi` / `lilia` / `system` | 参考情報 |
| context | @description (文脈) | 参考情報 |
| japanese | 日本語原文 | 参考情報 |
| english_draft | LLM 一次翻訳 | **編集禁止** (差分確認用に残す) |
| english_final | ライターの修正稿 | **ここだけ編集する** |
| notes | ライターのコメント | 自由記入 |
| placeholders | 保持必須の placeholder | **編集禁止** |
"""
import argparse
import csv
import json
import re
import sys
from pathlib import Path

# Windows の既定コンソール (cp932) では 🪶 等の絵文字を print した瞬間に
# UnicodeEncodeError で落ちる。ARB には Sabi の 🪶 が大量に含まれるため、
# 出力先を UTF-8 に付け替える (実測で crash を確認して追加)。
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, 'reconfigure'):
        _stream.reconfigure(encoding='utf-8', errors='replace')

ROOT = Path(__file__).resolve().parent.parent
ARB_JA = ROOT / 'mobile' / 'lib' / 'l10n' / 'app_ja.arb'
ARB_EN = ROOT / 'mobile' / 'lib' / 'l10n' / 'app_en.arb'
OUT_DIR = ROOT / 'doc' / 'design' / 'review_export'

# ICU の引数名を拾う。単純形 `{count}` と ICU 形 `{count, plural, ...}` の両方に当たる
# ({name} の直後が `}` でも `,` でもよい)。
PLACEHOLDER_RE = re.compile(r'\{\s*(\w+)\s*[,}]')

# ICU の複雑構文。これが原文にあれば編集後にも残っていなければならない。
ICU_KEYWORDS = ('plural,', 'select,', 'selectordinal,')


def _brace_balance(text: str) -> int:
    """`{` と `}` の差分。0 でなければ ICU 構文が壊れている。"""
    return text.count('{') - text.count('}')


def _icu_problems(original: str, edited: str) -> list[str]:
    """ライターの編集が ICU 構文を壊していないか検証する。

    【FEAT-489 Phase 2F-a 以降】ARB には
    `{count, plural, =1{1 time} other{{count} times}}` のような ICU 複数形が入る。
    非エンジニアが編集する前提なので、以下は機械で止める:

      - 引数名の増減 (`{count}` を訳してしまう等)
      - plural / select 構造の消失 (`other{}` ごと消す等)
      - 波括弧の不均衡 (閉じ忘れ)

    これらを通すと `flutter gen-l10n` がビルド時に落ちるか、実行時に
    プレースホルダがそのまま画面に出る。
    """
    problems = []

    before = set(PLACEHOLDER_RE.findall(original))
    after = set(PLACEHOLDER_RE.findall(edited))
    if before != after:
        problems.append(
            f'placeholder 不一致 (元: {sorted(before) or "なし"} / '
            f'編集後: {sorted(after) or "なし"})')

    for kw in ICU_KEYWORDS:
        if kw in original and kw not in edited:
            problems.append(f'ICU 構文 `{kw}` が失われている')

    if _brace_balance(edited) != 0:
        n_open = edited.count('{')
        n_close = edited.count('}')
        problems.append(f'波括弧が不均衡 (開き {n_open} 個 / 閉じ {n_close} 個)')

    return problems


def _load(path: Path) -> dict:
    # gen-l10n / エディタが BOM を付けることがあるため utf-8-sig で読む
    return json.loads(path.read_text(encoding='utf-8-sig'))


def _tier(key: str) -> str:
    """レビュー優先度。sabi > lilia > system の順に人格クリティカル。"""
    if 'Sabi_message' in key:
        return 'sabi'
    if 'ilia' in key or 'eceptionist' in key:
        return 'lilia'
    return 'system'


def export() -> None:
    ja, en = _load(ARB_JA), _load(ARB_EN)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    rows = []
    for key, en_val in en.items():
        if key.startswith('@') or not isinstance(en_val, str):
            continue
        meta = ja.get(f'@{key}') or {}
        rows.append({
            'key': key,
            'tier': _tier(key),
            'context': (meta.get('description') or '') if isinstance(meta, dict) else '',
            'japanese': ja.get(key, ''),
            'english_draft': en_val,
            'english_final': en_val,   # 初期値 = draft。ライターは上書きする
            'notes': '',
            'placeholders': ' '.join(sorted(set(PLACEHOLDER_RE.findall(en_val)))),
        })

    # 人格クリティカルな順に並べる。予算を絞る場合は上から N 行だけ発注できる。
    order = {'sabi': 0, 'lilia': 1, 'system': 2}
    rows.sort(key=lambda r: (order[r['tier']], r['key']))

    groups = {
        'tier1_persona': [r for r in rows if r['tier'] in ('sabi', 'lilia')],
        'tier2_system':  [r for r in rows if r['tier'] == 'system'],
    }

    for name, group in groups.items():
        out = OUT_DIR / f'{name}.csv'
        # Excel / Google Sheets が UTF-8 を正しく開けるよう BOM 付きで書く
        with out.open('w', encoding='utf-8-sig', newline='') as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(group)
        words = sum(len(r['english_draft'].split()) for r in group)
        print(f'{out.relative_to(ROOT)}: {len(group)} rows / {words} words')


# 【FEAT-489 Phase 3】候補者スクリーニング用の 5 行。
#
# 実在の key を使う (架空の例文にしない)。サンプルの成果物をそのまま採用でき、
# かつ「本番と同じ難度」で候補者を測れるため。
#
# 5 行はそれぞれ **別の失敗モード**を試す。詳細な合否基準は
# doc/design/i18n_reviewer_brief_en.md §5 を参照。
SCREENING_KEYS = [
    # 停滞の肯定。「Don't worry about it」級の軽い慰めに落とすと不採用 (最重要)
    'sabiTodoCarryover2Sabi_message',
    # 称賛ではなく事実の承認に留められるか (CLAUDE.md の模範台詞そのもの)
    'sabiTodoDone1Sabi_message',
    # 「地層」の比喩を英語で自然な像に置けるか + 複数行の扱い
    'gamifJobMasteryMaxedBodySabi_message',
    # Lilia の明朗さ。formal な customer-service 調に落とすと不採用 (P5)
    'guildLiliaDefault1',
    # エラー文でユーザーを責めないか
    'gamifAchievementPageErrorSabi_message',
]


def sample() -> None:
    """候補者に送るスクリーニング用 CSV (5 行) を書き出す。"""
    ja, en = _load(ARB_JA), _load(ARB_EN)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    rows = []
    for key in SCREENING_KEYS:
        if key not in en:
            raise SystemExit(
                f'ERROR: key が存在しません: {key}\n'
                'ARB のリファクタで key 名が変わった可能性があります。'
                'SCREENING_KEYS を更新してください。')
        meta = ja.get(f'@{key}') or {}
        rows.append({
            'key': key,
            'tier': _tier(key),
            'context': (meta.get('description') or '') if isinstance(meta, dict) else '',
            'japanese': ja.get(key, ''),
            'english_draft': en[key],
            'english_final': en[key],
            'notes': '',
            'placeholders': ' '.join(sorted(set(PLACEHOLDER_RE.findall(en[key])))),
        })

    out = OUT_DIR / 'screening_sample.csv'
    with out.open('w', encoding='utf-8-sig', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    words = sum(len(r['english_draft'].split()) for r in rows)
    print(f'{out.relative_to(ROOT)}: {len(rows)} rows / {words} words')


def import_csv(path: Path, dry_run: bool) -> int:
    en = _load(ARB_EN)
    changes, errors = [], []

    with path.open(encoding='utf-8-sig', newline='') as f:
        for i, row in enumerate(csv.DictReader(f), start=2):
            key = row['key']
            # 【重要】strip() しない。arb には前後の空白が意味を持つ値がある
            # (例: socialGiftRewardCoins = " {count} coins" は連結時の区切り)。
            # strip すると往復のたびに silent に差分が出る (実測で検出)。
            # CSV 往復で混入する CR のみ落とす。
            final = (row.get('english_final') or '').replace('\r\n', '\n')
            if not key or not final.strip():
                continue
            if key not in en:
                errors.append(f'{path.name}:{i} 未知の key: {key}')
                continue
            if final == en[key]:
                continue

            # placeholder / ICU 構文の破壊は gen-l10n の失敗や実行時の表示崩れに
            # 直結するため、1 件でもあれば取り込み全体を中止する
            problems = _icu_problems(en[key], final)
            if problems:
                for msg in problems:
                    errors.append(f'{path.name}:{i} [{key}] {msg}')
                continue
            changes.append((key, en[key], final))

    for e in errors:
        print(f'ERROR  {e}', file=sys.stderr)
    for key, old, new in changes:
        print(f'  {key}\n    - {old}\n    + {new}')
    print(f'\n変更 {len(changes)} 件 / エラー {len(errors)} 件')

    if errors:
        print('エラーがあるため取り込みを中止しました。CSV を修正して再実行してください.',
              file=sys.stderr)
        return 1
    if dry_run:
        print('(dry-run のため書き込みませんでした)')
        return 0
    if not changes:
        return 0

    for key, _, new in changes:
        en[key] = new
    # ja 側と同じ体裁 (BOM + 2 space indent) を保つ
    ARB_EN.write_text(
        json.dumps(en, ensure_ascii=False, indent=2) + '\n', encoding='utf-8-sig')
    print(f'{ARB_EN.relative_to(ROOT)} を更新しました。'
          '`cd mobile && flutter gen-l10n` を実行してください。')
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='cmd', required=True)
    sub.add_parser('export')
    sub.add_parser('sample')
    imp = sub.add_parser('import')
    imp.add_argument('csv', type=Path)
    imp.add_argument('--dry-run', action='store_true')
    args = p.parse_args()

    if args.cmd == 'export':
        export()
        return 0
    if args.cmd == 'sample':
        sample()
        return 0
    return import_csv(args.csv, args.dry_run)


if __name__ == '__main__':
    raise SystemExit(main())
