"""英訳の投入が **主キーに依存しない** ことを縛る。

## なぜ必要か (2026-08-06 の CI 赤)

`doc/i18n/master_data_en.json` は当初 `GachaReward` を **pk で指定**していた。
これが CI (PostgreSQL) で 13 件 `not found` になり、4 テストが落ちた。

原因は `GachaReward` が migration ではなく **実行時** (`views/gacha.py` の
`_ensure_gacha_rewards()`) に seed されること。migration 直後は 6 行しか無く、
残り 13 行は lazy seed が作る。その pk は DB backend で変わる:

- SQLite      : 解放された rowid を `max+1` で再利用する
- PostgreSQL  : シーケンスは再利用しない

結果、**ローカル (SQLite) では 19 行すべてに当たり、CI (PostgreSQL) では
6 行にしか当たらない**という状態になっていた。

## このテストが無いと何が困るか

開発者のローカルは SQLite なので、**この失敗モードはローカルでは絶対に
再現しない**。CI に上げるまで気付けず、しかも CI のログは長くて埋もれる。

そこで pk をわざとずらして「pk が変わっても投入できるか」を SQLite 上で
検証する。実 DB の採番規則を真似るのではなく、**pk に依存していないこと
自体**を確かめるので、backend を問わず意味を持つ。

## 落ちたときに疑うところ

`translate_master_data` の `_COMPOSITE_KEYS` から `GachaReward` が消えたか、
JSON に `id` が復活したか (`scripts/build_master_data_en.py` の出力)。
"""
from io import StringIO
from pathlib import Path

from django.core.management import call_command
from django.test import TestCase

from api.models import GachaReward

_JSON = Path(__file__).resolve().parents[3] / 'doc' / 'i18n' / 'master_data_en.json'

_PK_OFFSET = 1000


def _clone_with_offset(rows):
    """同じ内容・違う pk の行を作る (PostgreSQL の採番ずれを模す)。"""
    editable = [f.name for f in GachaReward._meta.fields if f.name != 'id']
    return [
        GachaReward(
            id=o.pk + _PK_OFFSET,
            **{name: getattr(o, name) for name in editable},
        )
        for o in rows
    ]


class GachaRewardPkIndependenceTest(TestCase):
    def setUp(self):
        # GachaReward は実行時 seed。migration 直後は 6 行しか無い。
        from api.views.gacha import _ensure_gacha_rewards
        _ensure_gacha_rewards()

    def test_seeded_rows_are_not_created_by_migrations(self):
        """前提の確認 —— lazy seed が実際に行を増やしていること。

        ここが崩れる (= migration で seed されるようになる) と、本テストの
        前提が変わる。そのときは docstring ごと見直すこと。
        """
        self.assertGreater(
            GachaReward.objects.count(), 6,
            'lazy seed が行を作っていない。_ensure_gacha_rewards() の呼び出しか、'
            'seed の定義が変わった可能性がある。',
        )

    def test_translation_applies_after_pk_shift(self):
        """pk を全件ずらしても、英訳が 1 行残らず入ること。

        修正前はここで `GachaReward id=7 not found` 相当が出て
        `CommandError` になっていた。
        """
        original = list(GachaReward.objects.order_by('pk'))
        shifted = _clone_with_offset(original)
        GachaReward.objects.all().delete()
        GachaReward.objects.bulk_create(shifted)

        # ずらした pk が元の pk と重ならないこと (テスト自体の妥当性)
        self.assertEqual(
            GachaReward.objects.filter(pk__lte=_PK_OFFSET).count(), 0,
            'pk をずらせていない。オフセットが小さすぎる可能性がある。',
        )

        out = StringIO()
        # skip が 1 件でもあれば CommandError になる。例外が出ないこと自体が契約。
        call_command('translate_master_data', file=str(_JSON), stdout=out)

        blank = GachaReward.objects.filter(name_en='').count()
        self.assertEqual(
            blank, 0,
            f'pk がずれると {blank} 行に英訳が入らない。'
            f'translate_master_data が pk 依存に戻っていないか確認すること。\n'
            f'--- コマンド出力 ---\n{out.getvalue()}',
        )

    def test_json_does_not_identify_gacha_rewards_by_pk(self):
        """JSON 側で `id` が復活していないこと。

        `_COMPOSITE_KEYS` があれば pk より複合キーが優先されるので実害は
        出ないが、**pk は行の identity ではない**という設計判断を残すために
        ファイル側でも縛る。
        """
        import json

        entries = json.loads(_JSON.read_text(encoding='utf-8'))['GachaReward']
        with_id = [e for e in entries if 'id' in e]
        self.assertEqual(
            with_id, [],
            'master_data_en.json の GachaReward に "id" が復活している。'
            ' scripts/build_master_data_en.py が id を出力していないか確認すること。',
        )
