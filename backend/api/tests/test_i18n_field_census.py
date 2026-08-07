"""【FEAT-516】「運営が書く文言 field には `_en` がある」をソース走査で縛る。

## なぜ必要か —— 同じ漏れが 3 回起きている

FEAT-489 Phase 4 は対象を **「5 model」と手で数えて**決めた。数え方が悪かったの
ではなく、**数えたこと自体**が問題だった。手で数えたリストは、数えた人が
思い出したものしか含まない。

| 時期 | 漏れたもの | 検出 |
|---|---|---|
| Phase 4 | `Job.job_name_en` | Phase 2E の verify |
| Phase 4 | `translate_master_data` / `check_i18n_coverage` の対象 model | 20260802 review |
| Phase 4 | **本 FEAT の 8 model / 14 field** | 実機 QA (ユーザー報告は 1 行だった) |

2 回目の対策として `api/i18n_targets.py` で自動列挙にしたが、あれは
**`_en` を持っている model を発見する**もので、**`_en` が無い model は
構造的に見つけられない**。3 回目の漏れはその盲点そのものだった。

本テストはその盲点を塞ぐ。Flutter 側 `test/i18n_coverage_test.dart` の check A
(**dir を列挙するのではなく、UI を持つ dir を発見する**) と同じ発想。

## 判定は field 単位で行う (Pre-mortem S4)

`Job` は `job_name_en` が追加された際に**同じ model の `description` が
見過ごされた**。「model 単位で対応済」と誤認しやすいので、model ではなく
**field ごと**に判定する。

## allowlist に載せてよいもの

**「なぜ翻訳しないか」を 1 行で説明できるものだけ**。説明が書けないものは
判断していないだけなので、対象に入れること。
"""
import re

from django.apps import apps
from django.db import models
from django.test import TestCase

# 「運営が書く表示文言」らしい field 名の判定語。
#
# ここを絞りすぎると次の漏れをまた見逃す (Pre-mortem S1)。広めに取って、
# 該当しないものは allowlist に**理由付きで**落とす運用にする。
_COPY_WORDS = (
    'title', 'name', 'description', 'text', 'body', 'message',
    'label', 'tagline', 'detail', 'hint', 'role', 'content',
)

# 翻訳対象外。key は `'Model'` (model 全体) か `'Model.field'` (field 単位)。
# **値は「なぜ翻訳しないか」の理由。空文字にしないこと。**
_ALLOWLIST: dict[str, str] = {
    # ── user-generated content ────────────────────────────────────────
    # backend_i18n.md §1 が明示的に対象外としたもの。
    # ユーザーが**自分の言語で書いた原文**なので、翻訳すると別人の文章になる。
    'Habit':                   'ユーザーが書いた習慣名',
    'ChecklistItem':           'ユーザーが書いたチェック項目',
    'TimelineEvent':           'ユーザーが書いた予定タイトル',
    'FreeMemo':                'ユーザーが書いたメモ本文',
    'Message':                 'ユーザーが書いたフレンド宛メッセージ',
    'PlayerProfile':           'ユーザーが決めたプレイヤー名',
    'PlayerStatsMatrix':       'PlayerProfile の proxy model (admin 用)。実体は同じ name',
    'AccountDeletionFeedback': 'ユーザーが書いた退会理由の自由記述',

    # ── 運営 or 外部サービスしか見ないもの ────────────────────────────
    'IAPReceipt.error_message': 'RevenueCat webhook のエラー詳細。admin のデバッグ用でユーザーに出ない',
    'BattleLog.summary_text':   'Flutter が生成して POST する戦闘ログ。生成時点で端末の言語になっている',

    # ── 送信時に確定させる文言 (別の仕組みで i18n 済) ─────────────────
    'Notification': (
        'FEAT-517 で対応済。文面は api/i18n_messages.py が宛先の言語で組み立て、'
        '結果の文字列を保存する。model に _en を持たせる設計ではない'
    ),
}


def _is_allowlisted(model_name: str, field_name: str) -> str | None:
    """allowlist に載っていれば理由を返す。"""
    return _ALLOWLIST.get(f'{model_name}.{field_name}') or _ALLOWLIST.get(model_name)


def _copy_fields(model):
    """model の「表示文言らしい」concrete な文字列 field を列挙する。"""
    for f in model._meta.get_fields():
        if not isinstance(f, (models.CharField, models.TextField)):
            continue
        if f.name.endswith('_en'):
            continue
        if f.choices:
            # choices 付きは enum。表示は Mobile 側が解決する (Data + Display 分離)
            continue
        if any(w in f.name for w in _COPY_WORDS):
            yield f.name


class I18nFieldCensusTest(TestCase):
    def test_every_operator_written_field_has_en_sibling(self):
        """運営が書く文言 field には必ず `<name>_en` がある。

        落ちたら、その field を **翻訳対象にする** (migration で `_en` を足す) か、
        **allowlist に理由を書いて外す** かのどちらかを選ぶこと。
        「とりあえず allowlist」は禁止 —— 理由が書けないなら判断していない。
        """
        missing = []
        for model in apps.get_app_config('api').get_models():
            names = {f.name for f in model._meta.get_fields()}
            for field in _copy_fields(model):
                if _is_allowlisted(model.__name__, field):
                    continue
                if f'{field}_en' not in names:
                    missing.append(f'{model.__name__}.{field}')

        self.assertEqual(
            missing, [],
            '運営が書く文言なのに `_en` が無い field がある。\n'
            'migration で `_en` を足すか、_ALLOWLIST に理由を書いて外すこと:\n  '
            + '\n  '.join(sorted(missing)),
        )

    def test_allowlist_entries_have_a_reason(self):
        """allowlist の全 entry に理由が書かれている。

        理由の無い entry が増えると allowlist が「とりあえず足す場所」に堕ちる
        (Pre-mortem S2)。
        """
        empty = [k for k, v in _ALLOWLIST.items() if not v or not v.strip()]
        self.assertEqual(empty, [], f'理由が空の allowlist entry: {empty}')

    def test_allowlist_has_no_stale_entry(self):
        """allowlist に実在しない model / field が残っていない。

        model を消したり field 名を変えたりしたときに、allowlist だけが残ると
        「除外したつもり」の穴が生まれる。
        """
        model_names = {m.__name__ for m in apps.get_app_config('api').get_models()}
        stale = []
        for key in _ALLOWLIST:
            if '.' in key:
                model_name, field_name = key.split('.', 1)
                model = next(
                    (m for m in apps.get_app_config('api').get_models()
                     if m.__name__ == model_name), None)
                if model is None:
                    stale.append(f'{key} (model が無い)')
                elif field_name not in {f.name for f in model._meta.get_fields()}:
                    stale.append(f'{key} (field が無い)')
            elif key not in model_names:
                stale.append(f'{key} (model が無い)')
        self.assertEqual(stale, [], f'実在しない allowlist entry: {stale}')

    def test_en_fields_are_blank_default_empty(self):
        """`_en` field は `blank=True, default=''` で作られている。

        `null=True` が混ざると `get_i18n_field` の `(value or '').strip()` は
        動くものの、`filter(field__exact='')` を使う `check_i18n_coverage` /
        `translate_master_data` の集計から **null 行がすり抜ける**。
        """
        bad = []
        for model in apps.get_app_config('api').get_models():
            for f in model._meta.get_fields():
                if not isinstance(f, (models.CharField, models.TextField)):
                    continue
                if not f.name.endswith('_en'):
                    continue
                if f.null or not f.blank or f.default != '':
                    bad.append(
                        f'{model.__name__}.{f.name} '
                        f'(null={f.null}, blank={f.blank}, default={f.default!r})'
                    )
        self.assertEqual(bad, [], '`_en` field の定義が揃っていない:\n  ' + '\n  '.join(bad))
