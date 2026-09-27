"""【2026-08-09】ジョブ熟練度の説明文が `constants.py` と食い違わないことの契約テスト。

## なぜ要るか

本テストは **「説明が実装に嘘をつく」** という、このリポジトリで実際に起きた
劣化を止めるためにある。

FEAT-511 Phase A (2026-07-30 実装済) に対して、`party_edit_dialog.dart` には
FEAT-430 時代の予告バナー「熟練度システムは v1.1+ でご用意します」が
**外し忘れで残り続けていた**。結果、ユーザーから
「本当に実装されているのか懸念しています」という報告が上がった (2026-08-09)。

その修正のなかで「熟練度の上げ方」を説明する info ダイアログを新設したが、
**説明文には勝利 5 EXP / 敗北 1 EXP / tier 倍率 / Lv 上限といった実数が
埋め込まれている**。`constants.py` を調整したときに ARB を直し忘れると、
今度は**バナーではなく説明文が嘘をつく**。同じ型の再発になる。

Flutter 側のテストでは Python の定数を読めないため、**Backend 側から ARB を
読んで縛る**。真実値は常に `constants.py` の側。

## 何を縛るか (逆は縛らない)

縛るのは「**定数の値が説明文に現れていること**」だけ。文章の言い回しや語順は
自由にしてよい。文面まで固定すると、コピーを磨くたびにテストが落ちて
「テストを直すために文章を戻す」という本末転倒が起きる。

## 公開スナップショットについて

`mobile/` は公開対象に含まれる (除外は Firebase 設定のみ、
`scripts/portfolio/exclude.txt`) ため、`test_env_var_documentation.py` のような
`.portfolio-snapshot` マーカー分岐は要らない。ARB が無ければそれ自体が異常。
"""
import json
from pathlib import Path

from django.test import SimpleTestCase

from api.constants import (
    JOB_MASTERY_EXP_PER_BATTLE_LOSS,
    JOB_MASTERY_EXP_PER_BATTLE_WIN,
    JOB_MASTERY_MAX_LEVEL,
    JOB_MASTERY_TIER_MULTIPLIER,
)

# backend/api/tests/ から見たリポジトリルート
_REPO_ROOT = Path(__file__).resolve().parents[3]
_ARB_DIR = _REPO_ROOT / 'mobile' / 'lib' / 'l10n'

_KEYS = (
    'gamifJobMasteryInfoTitle',
    'gamifJobMasteryInfoLead',
    'gamifJobMasteryInfoHowToTitle',
    'gamifJobMasteryInfoHowToBattle',
    'gamifJobMasteryInfoHowToEquipped',
    'gamifJobMasteryInfoHowToAuto',
    'gamifJobMasteryInfoAmountTitle',
    'gamifJobMasteryInfoAmountWinLose',
    'gamifJobMasteryInfoAmountTier',
    'gamifJobMasteryInfoMaxTitle',
    'gamifJobMasteryInfoMaxBody',
    'gamifJobMasteryInfoTooltip',
)


def _load(locale: str) -> dict:
    path = _ARB_DIR / f'app_{locale}.arb'
    # ja 側は BOM 付き。utf-8-sig で両方読める。
    return json.loads(path.read_text(encoding='utf-8-sig'))


class JobMasteryInfoArbSyncTest(SimpleTestCase):
    """info ダイアログの ARB が constants.py の実数を反映していることを縛る。"""

    def setUp(self):
        self.arbs = {loc: _load(loc) for loc in ('ja', 'en')}

    def test_keys_exist_in_both_locales(self):
        """12 key が ja / en の双方に存在する。"""
        for loc, arb in self.arbs.items():
            missing = [k for k in _KEYS if k not in arb]
            self.assertEqual(
                missing, [],
                f'app_{loc}.arb に info ダイアログの key が足りない: {missing}',
            )

    def test_win_loss_exp_matches_constants(self):
        """勝利 / 敗北の EXP が説明文に現れている。"""
        for loc, arb in self.arbs.items():
            text = arb['gamifJobMasteryInfoAmountWinLose']
            for label, value in (
                ('WIN', JOB_MASTERY_EXP_PER_BATTLE_WIN),
                ('LOSS', JOB_MASTERY_EXP_PER_BATTLE_LOSS),
            ):
                self.assertIn(
                    f'{value} EXP', text,
                    f'app_{loc}.arb の gamifJobMasteryInfoAmountWinLose が '
                    f'JOB_MASTERY_EXP_PER_BATTLE_{label}={value} を反映していない。\n'
                    f'  現在の文言: {text}\n'
                    f'  constants.py を変えたら ARB (ja/en 両方) も直すこと。',
                )

    def test_tier_multipliers_match_constants(self):
        """4 つの tier 倍率がすべて説明文に現れている。"""
        for loc, arb in self.arbs.items():
            text = arb['gamifJobMasteryInfoAmountTier']
            for tier, mult in JOB_MASTERY_TIER_MULTIPLIER.items():
                self.assertIn(
                    str(mult), text,
                    f'app_{loc}.arb の gamifJobMasteryInfoAmountTier に '
                    f'tier={tier} の倍率 {mult} が無い。\n'
                    f'  現在の文言: {text}',
                )

    def test_max_level_matches_constants(self):
        """Lv 上限が見出しと本文の双方に現れている。"""
        for loc, arb in self.arbs.items():
            for key in ('gamifJobMasteryInfoMaxTitle', 'gamifJobMasteryInfoMaxBody'):
                self.assertIn(
                    str(JOB_MASTERY_MAX_LEVEL), arb[key],
                    f'app_{loc}.arb の {key} が '
                    f'JOB_MASTERY_MAX_LEVEL={JOB_MASTERY_MAX_LEVEL} を反映していない。\n'
                    f'  現在の文言: {arb[key]}',
                )
