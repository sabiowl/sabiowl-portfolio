"""【FEAT-489 Phase 2G-b】英語で横に伸びて overflow しそうな Row を洗い出す triage ツール。

## なぜ必要か

2026-08-02 の実機 QA で、ギルド画面の「オートバトル」バーが英語で
`RIGHT OVERFLOWED BY 18 PIXELS` になった。原因は `Row` の中に
**Expanded/Flexible で包まれていない `Text(l10n....)`** があったこと。
日本語の「(ホーム到着時に自動で戦闘)」は 360dp に収まるが、英語の
"(Fights automatically when you open the app)" は収まらない。

同じ形は他にもあり得るが、全画面を実機で見るのは高コストなので、
**見る順番を決めるため**に機械で候補を並べる。

## これはゲートではない

ヒットは「疑い」であって不具合ではない。短い文字列なら Expanded が無くても
収まるし、`MainAxisSize.min` の Row は親が幅を与えないので通常は問題ない。
**CI に入れてはいけない** —— 実機 QA の優先順位付けにだけ使う。

## 使い方

```powershell
cd c:\\Users\\subar\\claude\\sabiowl
python scripts/row_overflow_scan.py          # 伸び幅トップ 20
python scripts/row_overflow_scan.py --all    # 全件
```

## 幅の見積もり

全角 = 2 / 半角 = 1 の等幅換算。実フォントの字送りとは違うが、
「日本語より英語がどれだけ横に伸びるか」の**相対比較**には十分。

ICU plural (`{count, plural, =1{...} other{...}}`) は展開せず生文字列で数える。
実際の描画は分岐 1 つ分なので **伸び幅を過大評価する** 点に注意
(`challengeCardCountLabel` が上位に来るのはこの理由で、実害ではない)。
"""
import json
import re
import sys
import unicodedata
from pathlib import Path

sys.stdout.reconfigure(encoding='utf-8')

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / 'mobile' / 'lib'
ARB = LIB / 'l10n'

SHOW_ALL = '--all' in sys.argv


def width(s: str) -> int:
    """全角 2 / 半角 1 の等幅換算 (絵文字も 2 扱い)。"""
    total = 0
    for ch in s:
        if unicodedata.east_asian_width(ch) in ('W', 'F') or ord(ch) > 0x1F000:
            total += 2
        else:
            total += 1
    return total


def find_blocks(src: str, opener: str):
    """`opener` (例 'Row(') から括弧の対応を取って本文を切り出す。"""
    for m in re.finditer(re.escape(opener), src):
        start = m.end() - 1
        depth = 0
        for i in range(start, len(src)):
            c = src[i]
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if depth == 0:
                    yield m.start(), src[start:i + 1]
                    break


def main() -> int:
    ja = json.loads((ARB / 'app_ja.arb').read_text(encoding='utf-8-sig'))
    en = json.loads((ARB / 'app_en.arb').read_text(encoding='utf-8-sig'))

    rows = []
    for path in sorted(LIB.rglob('*.dart')):
        src = path.read_text(encoding='utf-8')
        for pos, body in find_blocks(src, 'Row('):
            if 'Expanded' in body or 'Flexible' in body:
                continue  # 既に伸縮を許してある
            if 'MainAxisSize.min' in body:
                continue  # 親が幅を与えないので overflow しにくい
            keys = re.findall(
                r'Text\(\s*(?:l10n|AppLocalizations\.of\(context\)!)\.(\w+)',
                body,
            )
            if not keys:
                continue
            delta, detail = 0, []
            for k in keys:
                j, e = ja.get(k), en.get(k)
                if not isinstance(j, str) or not isinstance(e, str):
                    continue
                d = width(e) - width(j)
                delta += d
                detail.append((d, k, e))
            if not detail:
                continue
            rows.append((delta, path.relative_to(REPO).as_posix(),
                         src.count('\n', 0, pos) + 1, sorted(detail, reverse=True)))

    rows.sort(reverse=True)
    shown = rows if SHOW_ALL else rows[:20]
    print(f'Expanded/Flexible なし・非 min の Row: {len(rows)} 件'
          f' (英語の伸び幅順、表示 {len(shown)} 件)\n')
    for delta, rel, line, detail in shown:
        print(f'+{delta:>3} 文字幅  {rel}:{line}')
        for d, k, e in detail[:3]:
            if d <= 0:
                continue
            preview = e if len(e) <= 58 else e[:55] + '...'
            print(f'          +{d:>3}  {k}  "{preview}"')
        print()
    if not SHOW_ALL and len(rows) > len(shown):
        print(f'... 残り {len(rows) - len(shown)} 件は --all で表示')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
