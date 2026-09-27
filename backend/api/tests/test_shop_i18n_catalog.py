"""【BUG-146 Phase 3 (2026-08-19)】ショップの英訳 dict と `SHOP_CATALOG` のずれを禁じる。

## なぜ必要か (Pre-mortem #3)

`SHOP_CATALOG` は **model ではなく Python の dict リテラル**なので、
`_en` カラムが無く `test_i18n_field_census.py` の視界の外にある。英訳は
`_SHOP_EFFECT_EN` / `_SHOP_NON_WEAPON_NAME_EN` という**別の dict**に置くため、
**片側だけ item を足すと静かに日本語へ落ちる**。

`_localize_catalog_item` は英訳が引けないとき日本語へ silent fallback する
(ユーザーに空文字を見せないため)。その設計だと**ずれても画面は壊れない** ——
だから CI で捕まえる必要がある。id 集合の完全一致を assert し、
**片側だけ増えた / 減った瞬間に落ちる**ようにする。
"""
from django.test import TestCase

from api.models import WeaponMaster
from api.views.shop import (
    _SHOP_EFFECT_EN,
    _SHOP_NON_WEAPON_NAME_EN,
    _XP_BOOST_ACTIVE_EFFECT,
    _XP_BOOST_OWNED_EFFECT,
    SHOP_CATALOG,
    _localize_catalog_item,
)
from api.tests.test_i18n_api_response_no_japanese import _CJK


def _ids(predicate=None):
    return {
        it['id'] for it in SHOP_CATALOG
        if predicate is None or predicate(it)
    }


_WEAPON_IDS = _ids(lambda it: it.get('item_type') == 'weapon')
_NON_WEAPON_IDS = _ids(lambda it: it.get('item_type') != 'weapon')


class ShopI18nCatalogContractTest(TestCase):

    def test_effect_en_covers_every_catalog_item_exactly(self):
        """`_SHOP_EFFECT_EN` の key 集合が `SHOP_CATALOG` の id 集合と完全一致する。

        - 足りない → その品目だけ英語 UI で日本語のままになる
        - 余っている → 消した item の訳が残っている (次に同じ id を使うと誤訳が出る)
        """
        catalog_ids = _ids()
        self.assertEqual(
            sorted(_SHOP_EFFECT_EN), sorted(catalog_ids),
            '\n訳が無い id: ' + repr(sorted(catalog_ids - set(_SHOP_EFFECT_EN)))
            + '\n余分な id:   ' + repr(sorted(set(_SHOP_EFFECT_EN) - catalog_ids)),
        )

    def test_name_en_covers_every_non_weapon_item_exactly(self):
        """`_SHOP_NON_WEAPON_NAME_EN` は**武器以外**の id とだけ一致する。

        武器名は `WeaponMaster.name_en` が真実値なので、ここに武器の id が
        現れたら二重管理が始まっている (どちらが勝つか読めなくなる)。
        """
        self.assertEqual(
            sorted(_SHOP_NON_WEAPON_NAME_EN), sorted(_NON_WEAPON_IDS),
            '\n訳が無い id: ' + repr(sorted(_NON_WEAPON_IDS - set(_SHOP_NON_WEAPON_NAME_EN)))
            + '\n余分な id:   ' + repr(sorted(set(_SHOP_NON_WEAPON_NAME_EN) - _NON_WEAPON_IDS)),
        )

    def test_every_weapon_item_has_a_weapon_master_row(self):
        """武器品目の `weapon_key` が `WeaponMaster` に実在する。

        実在しないと `weapon_name_en` に載らず、名前だけ日本語に落ちる。
        """
        keys = {
            it['weapon_key'] for it in SHOP_CATALOG
            if it.get('item_type') == 'weapon'
        }
        existing = set(WeaponMaster.objects.filter(key__in=keys)
                       .values_list('key', flat=True))
        self.assertEqual(
            sorted(keys - existing), [],
            'SHOP_CATALOG の weapon_key が WeaponMaster に無い',
        )

    def test_english_values_are_not_empty_and_not_japanese(self):
        """英訳に空文字と日本語が混ざっていない。

        空文字だと `_localize_catalog_item` の `or` で日本語へ落ちるので、
        「訳したつもりで日本語のまま」という一番気付きにくい状態になる。
        """
        bad = []
        for mapping, label in (
            (_SHOP_EFFECT_EN, 'effect'),
            (_SHOP_NON_WEAPON_NAME_EN, 'name'),
            (_XP_BOOST_ACTIVE_EFFECT, 'xp_boost_active'),
            (_XP_BOOST_OWNED_EFFECT, 'xp_boost_owned'),
        ):
            for key, value in mapping.items():
                if label.startswith('xp_boost') and key == 'ja':
                    continue  # ja 側は日本語で正しい
                if not value or not value.strip():
                    bad.append(label + ':' + key + ' (空)')
                elif _CJK.search(value):
                    bad.append(label + ':' + key + ' (日本語が残っている)')
        self.assertEqual(bad, [], '英訳の値が不正:\n  ' + '\n  '.join(bad))

    def test_ja_locale_returns_the_original_object_untouched(self):
        """`locale='ja'` は item をそのまま返す (辞書のコピーも作らない)。

        日本語経路が「英訳を引いてから日本語へ戻す」形になっていると、
        訳の抜けが日本語表示のバグとして出うる。**素通し**であることを縛る。
        """
        item = SHOP_CATALOG[0]
        self.assertIs(_localize_catalog_item(item, 'ja', {}), item)

    def test_en_locale_falls_back_to_japanese_when_translation_is_missing(self):
        """英訳が引けないときは日本語へ落ちる (空文字を表示しない)。

        この silent fallback があるからこそ、id ずれは画面上で気付けない。
        上の集合一致テストが唯一の検出手段である、という関係を明示しておく。
        """
        unknown = {'id': 'not_in_catalog', 'name': '未知', 'effect': '未知の効果'}
        got = _localize_catalog_item(unknown, 'en', {})
        self.assertEqual(got['name'], '未知')
        self.assertEqual(got['effect'], '未知の効果')
