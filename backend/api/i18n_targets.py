"""【FEAT-489】`_en` フィールドを持つ model を **自動列挙** するユーティリティ。

## なぜ手書きリストをやめたか

`translate_master_data`（英訳を流し込む）と `check_i18n_coverage`（空欄を検出する）は
どちらも対象 model を **ハードコードした 5 件のリスト**で持っていた。

その後 `Job.job_name_en` が「Phase 4 の漏れ回収」として追加されたが、
**どちらのリストにも登録されなかった**。結果:

- native reviewer から受け取った JSON にジョブ名を書いても **投入できない**
- `check_i18n_coverage --fail-on-empty` を release gate に使っても、
  `job_name_en` が全件空のまま **緑で通る**

「空欄を検出するためのコマンドが、いま一番空欄である field を見ていない」
という状態だった（[20260802 functional review](../../doc/codebase_review/20260802_functional_review.md) §3 B-1）。

手書きリストは **人が思い出したものしか拾わない**。model から `_en` を発見すれば、
次に誰かが `_en` を足した瞬間から両コマンドの対象に入る。

これは Flutter 側 `test/i18n_coverage_test.dart` の check A
（**dir を列挙するのではなく、UI を持つ dir を発見する**）と同じ発想を
Backend に移したもの。

## 命名規約への依存

「`_en` で終わる concrete field は英訳対象」という規約に乗っている。
規約から外れた名前（例: `english_title`）を付けると拾われないので、
**新しい i18n field は必ず `<base>_en` で命名すること**。
"""
from django.apps import apps

_APP_LABEL = 'api'
_SUFFIX = '_en'


def i18n_targets() -> list[tuple[str, type, list[str]]]:
    """`api` app の全 model から `_en` で終わる concrete field を列挙する。

    Returns:
        `(model_name, model_class, [en_field, ...])` の list。
        model 名の昇順、field 名も昇順で安定させる（出力の diff を読みやすく
        するため / テストで順序に依存できるようにするため）。
    """
    targets: list[tuple[str, type, list[str]]] = []
    for model in apps.get_app_config(_APP_LABEL).get_models():
        fields = sorted(
            f.name
            for f in model._meta.get_fields()
            # concrete=False は逆参照 (related_name) や GenericForeignKey。
            # DB 列を持たないので bulk_update / filter の対象にならない。
            if getattr(f, 'concrete', False) and f.name.endswith(_SUFFIX)
        )
        if fields:
            targets.append((model.__name__, model, fields))
    return sorted(targets, key=lambda t: t[0])


def i18n_target_map() -> dict[str, tuple[type, list[str]]]:
    """[i18n_targets] を `{model_name: (model_class, en_fields)}` に整形する。

    JSON の key から model を引く `translate_master_data` 向け。
    """
    return {name: (cls, fields) for name, cls, fields in i18n_targets()}
