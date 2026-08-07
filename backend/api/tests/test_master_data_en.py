"""【FEAT-489】master data の英訳ファイルが「そのまま適用できる」ことを縛る契約テスト。

## なぜ必要か

`doc/i18n/master_data_en.json` は **DB の日本語原文に対して**作った翻訳である。
原文が動けば翻訳は対応を失うが、それは **英語ユーザーが画面を見るまで気付けない**。

具体的に起きうること:

- migration で `Enemy` を 1 体足した → その敵だけ英語 locale で日本語名が出る
- サビの台詞を 1 行直した → その行の英訳が古い日本語に対応したままになる
- 台詞を admin から削除した → pk がずれ、**別の台詞に英訳が入る**

いずれも例外は出ない。だからここで縛る。

## 何を縛るか

1. 翻訳ファイルが **1 件も skip されずに** 適用できる (= 原文と対応が取れている)
2. 適用後、**翻訳可能な `_en` field が 100% 埋まる** (= 新しい行を訳し忘れていない)

## 落ちたときの直し方

```powershell
cd backend
python manage.py test api.tests.test_master_data_en   # どの行が原因か出る
# 原文を再 export して翻訳を足す:
python scripts/build_master_data_en.py                # 未翻訳を一覧して異常終了する
```

## `GachaReward` の lazy seed について

`GachaReward` は migration ではなく **実行時** (`_ensure_gacha_rewards`) に
seed される。テスト DB は migration しか適用しないので、各テストで先に
seed しないと翻訳ファイルの GachaReward 行が「対象なし」で弾かれる。

## ja 原文が空の field について

`Character.tagline` (14 件) と `TaskSuggestion.hint` (120 件) は **ja 側が空**で、
訳す元が無い。`check_i18n_coverage` はこれらを分母から外すので、本テストの
「100%」もその定義に従う。
"""
import json
from io import StringIO
from pathlib import Path

from django.core.management import CommandError, call_command
from django.test import TestCase

from api.i18n_targets import i18n_targets

_JSON = Path(__file__).resolve().parents[3] / 'doc' / 'i18n' / 'master_data_en.json'


class MasterDataEnglishContractTest(TestCase):
    def test_translation_file_exists(self):
        self.assertTrue(
            _JSON.exists(),
            f'{_JSON} が無い。scripts/build_master_data_en.py で生成すること。',
        )

    def test_applies_without_skipping_any_row(self):
        """原文と 1 件も食い違わずに適用できる。

        `translate_master_data` は不一致が 1 件でもあれば CommandError で
        異常終了する (pk の取り違えを黙って通さないため)。
        """
        from api.views.gacha import _ensure_gacha_rewards
        _ensure_gacha_rewards()   # 実行時 lazy seed (下記コメント参照)
        out = StringIO()
        try:
            call_command('translate_master_data', file=str(_JSON), stdout=out)
        except CommandError as exc:
            self.fail(
                '英訳ファイルが現在の master data に適用できない。\n'
                f'{exc}\n--- コマンド出力 ---\n{out.getvalue()}'
            )

    def test_coverage_is_complete_after_apply(self):
        """適用後、翻訳可能な `_en` field が 1 件も空でない。"""
        from api.views.gacha import _ensure_gacha_rewards
        _ensure_gacha_rewards()
        call_command('translate_master_data', file=str(_JSON), verbosity=0)

        missing = []
        for model_name, model_cls, fields in i18n_targets():
            for field in fields:
                base = field[:-3]
                # ja 原文が空の行は訳しようがないので対象外 (docstring 参照)
                qs = (model_cls.objects
                      .filter(**{f'{field}__exact': ''})
                      .exclude(**{f'{base}__exact': ''}))
                for pk in qs.values_list('pk', flat=True):
                    missing.append(f'{model_name}.{field} pk={pk}')

        self.assertEqual(
            missing, [],
            '英訳が無い master data がある (新しい行を追加して訳し忘れた可能性):\n'
            + '\n'.join(missing[:20]),
        )

    def test_file_uses_natural_key_where_available(self):
        """自然キーを持つ model は pk ではなく自然キーで指定する。

        pk はローカルと prod でずれうるが、`Enemy.key` / `Character.key` は
        migration が決めるので安定する。ここが pk に戻ると、prod で
        **別の敵に英名が入る**事故の余地が復活する。
        """
        data = json.loads(_JSON.read_text(encoding='utf-8'))
        for model_name, key_field in (('Enemy', 'key'), ('Character', 'key')):
            for entry in data.get(model_name, []):
                self.assertIn(
                    key_field, entry,
                    f'{model_name} の entry が {key_field} を持っていない: {entry}',
                )
                self.assertNotIn(
                    'id', entry,
                    f'{model_name} は自然キーで指定すること (pk は不安定): {entry}',
                )
