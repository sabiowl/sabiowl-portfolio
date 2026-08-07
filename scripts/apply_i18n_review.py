"""レビュアーが返した TSV を `app_en.arb` に適用する (FEAT-489 Phase 2F-b)。

## 使い方

1. 返ってきた TSV を `doc/i18n_review/returned/<batch>.tsv` に保存する
   (先頭・末尾の説明文は消す。`key<TAB>revised<TAB>reason` の行だけ残す)
2. `python scripts/apply_i18n_review.py --dry-run` で差分を確認
3. 問題なければ `python scripts/apply_i18n_review.py` で適用
4. `cd mobile && flutter gen-l10n && flutter test`

## なぜスクリプトにするか

300 行を手で戻すのは `DEVELOPER_STYLE_GUIDE.md` §9.9 の罠そのもの。
ただし **書き換え自体は 1 行 = 1 key の値差し替え**で構造を触らないので、
regex でソースを解析する類の危険はない (JSON として読み書きする)。

## 適用前に落とすもの (silent corruption の防止)

- **key が存在しない** — typo / 幻覚。適用せず報告する
- **placeholder が増減している** — `{count}` を消されるとアプリが落ちる
- **ICU 構造の変化** — `select` / `plural` の分岐名が変わっていないか
- **UNSURE: 付き** — reviewer 自身が迷った行。人間の確認に回す
"""
import argparse
import json
import re
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding='utf-8')

ROOT = Path(__file__).resolve().parent.parent
ARB = ROOT / 'mobile/lib/l10n/app_en.arb'
RETURNED = ROOT / 'doc/i18n_review/returned'

# placeholder は `{name}` か `{name, plural, ...}` の形。**閉じか カンマ が続く**
# ことを要求しないと、ICU の分岐本文 `daily{You're ...}` の `{You` を変数名として
# 拾ってしまう (実際に smoke test で誤検出した)。
_PLACEHOLDER = re.compile(r'\{(\w+)\s*[},]')


def placeholders(s: str) -> set[str]:
    """`{name}` / `{count, plural, ...}` の **変数名**を集める。"""
    return set(_PLACEHOLDER.findall(s))


def icu_branches(s: str) -> set[str]:
    """`select` / `plural` の分岐名 (`daily{...}` `=1{...}` `other{...}`)。"""
    return set(re.findall(r'(?:^|\s)(=?\w+)\{', s))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    if not RETURNED.exists():
        print(f'!! {RETURNED} がありません。返ってきた TSV を置いてください')
        return 1

    raw = ARB.read_text(encoding='utf-8-sig')
    data = json.loads(raw)

    applied, skipped = [], []
    for tsv in sorted(RETURNED.glob('*.tsv')):
        for lineno, line in enumerate(tsv.read_text(encoding='utf-8').split('\n'), 1):
            if not line.strip():
                continue
            parts = line.split('\t')
            if len(parts) < 2:
                skipped.append((tsv.name, lineno, line[:50], 'TSV の列が足りない'))
                continue
            key = parts[0].strip().strip('`')
            # TSV は 1 行 1 レコードなので、アプリ内の改行は `\n` (2 文字) で
            # 運ばれてくる。ここで本物の改行に戻す。
            revised = parts[1].strip().replace('\\n', '\n')
            reason = parts[2].strip() if len(parts) > 2 else ''

            if key not in data:
                skipped.append((tsv.name, lineno, key, 'key が app_en.arb に無い'))
                continue
            if reason.upper().startswith('UNSURE'):
                skipped.append((tsv.name, lineno, key, 'UNSURE: 人間の確認に回す'))
                continue

            old = data[key]
            if not isinstance(old, str):
                skipped.append((tsv.name, lineno, key, '値が文字列でない'))
                continue
            if old == revised:
                continue

            lost = placeholders(old) - placeholders(revised)
            added = placeholders(revised) - placeholders(old)
            if lost or added:
                skipped.append((tsv.name, lineno, key,
                                f'placeholder が変化 (欠落 {sorted(lost)} / 追加 {sorted(added)})'))
                continue
            if icu_branches(old) != icu_branches(revised):
                skipped.append((tsv.name, lineno, key, 'ICU の分岐名が変化'))
                continue
            # 改行数の変化 = 画面レイアウトの変化。TSV は改行を持てないので
            # reviewer が 2 行を 1 行に潰しがち (batch 01 で 16 件中 5 件発生)。
            #
            # ただし **意図的に増やす**ケースもある (ja に改行があるのに en が
            # 失っていたのを復元する等)。その場合は reason の先頭に `[LAYOUT-OK]`
            # を付けて人が明示承認する。ガード自体は緩めない。
            layout_ok = reason.startswith('[LAYOUT-OK]')
            if not layout_ok and old.count('\n') != revised.count('\n'):
                skipped.append((
                    tsv.name, lineno, key,
                    f'改行数が変化 ({old.count(chr(10))} -> {revised.count(chr(10))})。'
                    f'レイアウトが変わるので目視で確認して \\n を入れ直すこと'))
                continue

            applied.append((key, old, revised, reason))

    print(f'== 適用可: {len(applied)} 件 / 保留: {len(skipped)} 件 ==\n')
    for key, old, revised, reason in applied:
        print(f'  {key}')
        print(f'    - {old}')
        print(f'    + {revised}')
        if reason:
            print(f'    理由: {reason}')
    if skipped:
        print('\n-- 保留 (適用しない) --')
        for f, ln, key, why in skipped:
            print(f'  {f}:{ln} {key} -> {why}')

    if args.dry_run:
        print('\n(--dry-run のため書き込みませんでした)')
        return 0

    # ── 書き戻し ────────────────────────────────────────────────────────────
    #
    # `json.dumps` で丸ごと書き直すと **空行のグルーピングが全部消える**。
    # 16 件の変更に対し 730 行の差分になり、レビュー不能になった (実測)。
    # そこで **該当 key の行だけ**を置換する。
    #
    # 値は必ず 1 行 (アプリ内改行は `\n` エスケープなので折り返さない) なので、
    # 行単位の置換で足りる。正規表現でソース構造を近似しているように見えるが、
    # 書き込み後に **JSON として読み直して期待値と完全一致するか** を検証するので、
    # 取りこぼしや誤爆はそこで必ず落ちる (§9.9 #1 の対策)。
    lines = raw.split('\n')
    remaining = {k for k, _o, _r, _re in applied}
    for key, _old, revised, _reason in applied:
        pat = re.compile(r'^(\s*)"' + re.escape(key) + r'"(\s*:\s*)".*?"(,?)\s*$')
        for i, line in enumerate(lines):
            m = pat.match(line)
            if m:
                lines[i] = (f'{m.group(1)}"{key}"{m.group(2)}'
                            f'{json.dumps(revised, ensure_ascii=False)}{m.group(3)}')
                remaining.discard(key)
                break
    if remaining:
        print(f'\n!! 行を特定できませんでした: {sorted(remaining)}')
        print('   書き込みを中止します')
        return 1

    new_raw = '\n'.join(lines)

    # 完全性の検証: 書き込み前に、期待した dict と 1 バイトも違わないか確かめる
    expected = dict(data)
    for key, _old, revised, _reason in applied:
        expected[key] = revised
    try:
        actual = json.loads(new_raw.lstrip('﻿'))
    except json.JSONDecodeError as e:
        print(f'\n!! 置換後の JSON が壊れています: {e}\n   書き込みを中止します')
        return 1
    if actual != expected:
        diff = {k for k in set(actual) | set(expected)
                if actual.get(k) != expected.get(k)}
        print(f'\n!! 置換結果が期待値と不一致: {sorted(diff)}\n   書き込みを中止します')
        return 1

    ARB.write_text(new_raw, encoding='utf-8', newline='')
    print(f'\napp_en.arb に {len(applied)} 件を適用しました (整形は保持)。'
          '\n次: cd mobile && flutter gen-l10n && flutter test')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
