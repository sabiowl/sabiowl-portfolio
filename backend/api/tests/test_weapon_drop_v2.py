"""【FEAT-461 (2026-06-22)】WeaponMaster.tier 動的取得の契約テスト 5 件。

arch_review 20260622 §2 P2-B 解消: battle.py の _NORMAL_WEAPON_KEYS /
_RARE_WEAPON_KEYS ハードコード tuple を撤廃し、`_get_tier_weapon_keys(tier)` で
WeaponMaster.tier (migration 0153) から動的取得する設計に変更した。

本テストは「新規武器を WeaponMaster に追加するだけでドロップ候補に反映される」
こと、および「tier を変更すれば即座に候補が変わる」ことを縛る。

【注意】テスト DB はマイグレーション (0148/0149/0153) を経由するため、本物の
wood/iron 24 武器がすでに rare/normal tier で存在する。本テストの自作 key
(`w_*`) は既存武器と衝突しない命名にし、判定は `assertIn`/`assertNotIn` で
「自作 key が期待通り含まれる/含まれない」のみを縛る（既存武器の集合に依存しない）。
"""
from django.test import TestCase

from api.models import WeaponMaster
from api.views.battle import _get_tier_weapon_keys


class WeaponTierDynamicLookupTest(TestCase):
    def setUp(self):
        WeaponMaster.objects.create(key='w_rare_1', name='レア武器1', tier='rare')
        WeaponMaster.objects.create(key='w_rare_2', name='レア武器2', tier='rare')
        WeaponMaster.objects.create(key='w_normal_1', name='ノーマル武器1', tier='normal')
        WeaponMaster.objects.create(key='w_starter', name='スターター武器', tier='starter')
        WeaponMaster.objects.create(key='w_shop', name='ショップ武器', tier='shop')

    def test_rare_tier_returns_only_rare_keys(self):
        keys = _get_tier_weapon_keys('rare')
        self.assertIn('w_rare_1', keys)
        self.assertIn('w_rare_2', keys)
        self.assertNotIn('w_normal_1', keys)
        self.assertNotIn('w_starter', keys)
        self.assertNotIn('w_shop', keys)

    def test_normal_tier_returns_only_normal_keys(self):
        keys = _get_tier_weapon_keys('normal')
        self.assertIn('w_normal_1', keys)
        self.assertNotIn('w_rare_1', keys)
        self.assertNotIn('w_starter', keys)
        self.assertNotIn('w_shop', keys)

    def test_unknown_tier_returns_empty(self):
        keys = _get_tier_weapon_keys('legendary')
        self.assertEqual(keys, ())

    def test_new_weapon_auto_included_without_code_change(self):
        """tier='rare' で新規武器を追加するだけで候補に反映される（battle.py 修正不要）。"""
        WeaponMaster.objects.create(key='w_rare_3', name='レア武器3', tier='rare')
        keys = _get_tier_weapon_keys('rare')
        self.assertIn('w_rare_1', keys)
        self.assertIn('w_rare_2', keys)
        self.assertIn('w_rare_3', keys)

    def test_tier_change_reflected_immediately(self):
        """既存武器の tier を変更すれば、即座にドロップ候補から外れる/入る。"""
        WeaponMaster.objects.filter(key='w_rare_1').update(tier='shop')
        keys = _get_tier_weapon_keys('rare')
        self.assertNotIn('w_rare_1', keys)
        self.assertIn('w_rare_2', keys)
