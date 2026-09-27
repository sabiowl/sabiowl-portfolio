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
from django.contrib import admin
from django.db import models
from django.test import TestCase

from api.i18n_targets import i18n_target_map

# `_en` field に **空でない既定値**を持たせてよいもの。
# **値は「なぜ空にしないか」の理由。空文字にしないこと。**
#
# 🔴 通常は `default=''` である。空を「未翻訳」の印として使い、
# `check_i18n_coverage` / `translate_master_data` がそれを集計するからである。
#
# ⚠️ ここに載せてよいのは、**英文を「出荷物」として同梱する** field だけ。
# 空にすると `check_i18n_coverage` が永久に「未翻訳」と報告し続けるが、
# 実際には正しい英語が出る —— つまり**誤検出**になる。
_EN_DEFAULT_ALLOWLIST: dict[str, str] = {
    # ── 【FEAT-544 (2026-09-23)】バージョンアップ告知 ──────────────────
    # 🔵 admin が**見て確認できる**ことが要件である (FEAT-544 §0/§2)。
    #    空欄だと「英語で何が出るのか」が admin から見えず、
    #    §0 の「忘れられる」と同じ問題が英語側に残る。
    # 🔵 既定値は view の `EN_FALLBACK` と同じ定数を参照しているので、
    #    2 箇所に別の英文が生まれることはない。
    'AppUpdateConfig.title_en':
        '更新告知の英文は出荷物。空だと admin から英語が見えない (FEAT-544)',
    'AppUpdateConfig.body_en':
        '同上',
    'AppUpdateConfig.mandatory_title_en':
        '必須更新の英文は出荷物。緊急時に英語を書かせないための既定値 (FEAT-544)',
    'AppUpdateConfig.mandatory_body_en':
        '同上',
}

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

    def test_en_default_allowlist_entries_have_a_reason(self):
        """`_EN_DEFAULT_ALLOWLIST` の全 entry に理由が書かれている。

        上の `_ALLOWLIST` と同じ運用。理由の無い entry が増えると
        allowlist が「とりあえず足す場所」に堕ちる。
        """
        empty = [k for k, v in _EN_DEFAULT_ALLOWLIST.items() if not v or not v.strip()]
        self.assertEqual(empty, [], f'理由が空の entry: {empty}')

    def test_en_default_allowlist_has_no_stale_entry(self):
        """`_EN_DEFAULT_ALLOWLIST` に実在しない field が残っていない。"""
        stale = []
        for key in _EN_DEFAULT_ALLOWLIST:
            model_name, field_name = key.split('.', 1)
            model = next(
                (m for m in apps.get_app_config('api').get_models()
                 if m.__name__ == model_name), None)
            if model is None:
                stale.append(f'{key} (model が無い)')
            elif field_name not in {f.name for f in model._meta.get_fields()}:
                stale.append(f'{key} (field が無い)')
        self.assertEqual(stale, [], f'実在しない entry: {stale}')

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
                # 🔴 `null=True` は例外なしで禁止する。
                #    allowlist で許すのは **既定値が非空であること**だけ。
                if f'{model.__name__}.{f.name}' in _EN_DEFAULT_ALLOWLIST:
                    if f.null or not f.blank:
                        bad.append(
                            f'{model.__name__}.{f.name} '
                            f'(null={f.null}, blank={f.blank}) '
                            'allowlist にあっても null=True / blank=False は不可'
                        )
                    continue
                if f.null or not f.blank or f.default != '':
                    bad.append(
                        f'{model.__name__}.{f.name} '
                        f'(null={f.null}, blank={f.blank}, default={f.default!r})'
                    )
        self.assertEqual(bad, [], '`_en` field の定義が揃っていない:\n  ' + '\n  '.join(bad))


# ═══════════════════════════════════════════════════════════════════════════
# 【FEAT-536 Phase 2-1 (2026-08-29)】admin の `_en` 露出を「走査」で縛る
# ═══════════════════════════════════════════════════════════════════════════

# admin に `_en` を出さなくてよい model。
# **値は「なぜ入力経路が要らないか」の理由。空文字にしないこと。**
# 上の `_ALLOWLIST` と同じ運用 —— 理由が書けないものは判断していないだけなので、
# allowlist ではなく修正対象に入れる。
_ADMIN_EXPOSURE_ALLOWLIST: dict[str, str] = {}


def _flatten_admin_fields(spec):
    """`fields` / fieldsets の `'fields'` を平らにする。

    Django は横並び指定として `('a', ('b', 'c'))` のようなネストを許すので、
    素朴に `set(spec)` にすると **タプルのまま入って field 名と一致しない**。
    """
    out = []
    for item in spec or ():
        if isinstance(item, (list, tuple)):
            out.extend(item)
        else:
            out.append(item)
    return out


def _scan_admin_en_exposure():
    """admin の `_en` 露出を走査する。

    Returns:
        `(inspected, missing)`。
        `inspected` は **実際に検査した** model 名（宣言ありと判定したもの）、
        `missing` は欠落の説明文字列。

    🔴 **テストから 2 回呼ばずに、この 1 本を共有すること。** 検査対象の
    数え方を別に書くと、**走査を骨抜きにしても「ちゃんと見ている」側だけが
    緑を出し続ける**（実際に負の検証で踏んだ）。
    """
    targets = i18n_target_map()
    inspected: list[str] = []
    missing: list[str] = []

    for model, model_admin in admin.site._registry.items():
        name = model.__name__
        if name not in targets:
            continue
        if _ADMIN_EXPOSURE_ALLOWLIST.get(name):
            continue

        declared_fields = getattr(model_admin, 'fields', None)
        declared_fieldsets = getattr(model_admin, 'fieldsets', None)
        if declared_fields is None and declared_fieldsets is None:
            # 宣言なし = Django が全 field を自動表示する。既に見えている。
            continue

        inspected.append(name)
        shown = set(_flatten_admin_fields(declared_fields))
        for _, opts in (declared_fieldsets or ()):
            shown.update(_flatten_admin_fields(opts.get('fields')))

        for en_field in targets[name][1]:
            if en_field not in shown:
                missing.append(
                    f'{type(model_admin).__name__} ({name}) に {en_field} が無い'
                )
    return inspected, missing


class AdminExposesEnglishFieldsTest(TestCase):
    """`_en` を持つ model の admin が、その `_en` を入力できる状態にある。

    ## なぜ「走査」なのか —— 手で数えたリストが 5 回連続で漏れた

    旧実装は `test_i18n_api_response.py::test_admin_exposes_english_fields` で、
    **`ChallengeAdmin` 決め打ち**だった。2026-08-11 に `Challenge` を直したとき、
    **隣に同じ穴が 2 つ空いたまま**だったのを誰も検出できていない
    (`GachaReward` / `WeaponMaster`)。さらに `MaintenanceConfig` も同型で、
    こちらは **障害中の唯一の画面**に日本語が出る経路だった (FEAT-536 §2)。

    | 回 | 漏れたもの | 見つけた人 |
    |:-:|---|---|
    | 1 | `Job.job_name_en` | Phase 2E の verify |
    | 2 | 2 コマンドの対象 model リスト | 20260802 review |
    | 3 | 8 model / 14 field | 実機 QA |
    | 4 | `gacha.py` に `get_i18n_field` が 0 件 | BUG-146 (ユーザー報告) |
    | 5 | **本件 (view 1 + admin 3)** | FEAT-536 の調査 |

    毎回「見つかった 1 件だけを直して、次の 1 件はユーザーが見つけている」。
    走査に置き換えると、**次に誰かが `_en` を足した瞬間から検査対象に入る**。

    ## 🔴 判定の勘所 —— 「宣言していない admin」を OK にすること

    `fields` も `fieldsets` も宣言していない `ModelAdmin` は Django が
    **全 field を自動表示する**ので、`_en` は既に見えている = 正しく OK。
    ここを雑に扱うと **全部 OK になって何も検出しない**テストになる
    (FEAT-536 Pre-mortem #1)。逆に宣言している admin では
    **fieldsets に無い = 入力経路が存在しない**ので、view を直しても
    永久に日本語のままになる。
    """

    # 走査が確実に見ていなければならない admin。
    #
    # 🔴 **数ではなく名前で縛る。** 「N 件以上見た」では、走査が骨抜きになって
    # 別の admin を N 件数えているだけ、という状態を見逃す。実際、最初は
    # 件数で書いていて **fieldsets を見ない改変を緑のまま通した**。
    _MUST_INSPECT = frozenset({
        'MaintenanceConfig',  # FEAT-536 で塞いだ本体 (fieldsets)
        'GachaReward',        # FEAT-536 で塞いだ隣 (fieldsets)
        'WeaponMaster',       # FEAT-536 で塞いだ隣 (fieldsets)
        'Challenge',          # 2026-08-11 に個別対応した先例 (fieldsets)
    })

    def test_declared_admins_expose_all_en_fields(self):
        _, missing = _scan_admin_en_exposure()
        self.assertEqual(
            sorted(missing), [],
            '🔴 admin に英語 field の入力欄が無い:\n  '
            + '\n  '.join(sorted(missing))
            + '\n\nfields / fieldsets に足すか、_ADMIN_EXPOSURE_ALLOWLIST に'
              '「なぜ入力経路が要らないか」の理由を書いて外すこと。'
              '\n**欄が無い = 入力経路が存在しない**ので、view だけ直しても'
              '永久に日本語のままになる。',
        )

    def test_scan_actually_inspects_the_known_admins(self):
        """走査が骨抜きになっていないこと。

        `fields` / `fieldsets` の読み取りを壊すと、全 admin が「宣言なし」
        判定になって **上のテストは緑のまま何も検出しなくなる**
        (FEAT-536 Pre-mortem #1)。上と**同じ関数**を呼び、
        **既知の admin が検査対象に入っていること**を名前で確認する。
        """
        inspected, _ = _scan_admin_en_exposure()
        missing_from_scan = sorted(self._MUST_INSPECT - set(inspected))
        self.assertEqual(
            missing_from_scan, [],
            '走査が次の admin を見ていない: ' + repr(missing_from_scan)
            + '\n判定条件が壊れているか、admin の宣言方法が変わっている。'
              '意図的に宣言をやめた (= 全 field 自動表示にした) なら、'
              'この集合から外すこと。',
        )

    def test_scan_sees_the_i18n_models(self):
        """`i18n_target_map()` 自体が空になっていない。"""
        self.assertGreater(
            len(i18n_target_map()), 5, '`_en` を持つ model が検出できていない')

    def test_admin_exposure_allowlist_entries_have_a_reason(self):
        empty = [k for k, v in _ADMIN_EXPOSURE_ALLOWLIST.items() if not v or not v.strip()]
        self.assertEqual(empty, [], f'理由が空の allowlist entry: {empty}')

    def test_admin_exposure_allowlist_has_no_stale_entries(self):
        targets = i18n_target_map()
        stale = [k for k in _ADMIN_EXPOSURE_ALLOWLIST if k not in targets]
        self.assertEqual(stale, [], f'実在しない allowlist entry: {stale}')
