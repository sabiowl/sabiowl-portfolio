"""【FEAT-296 Phase 2-1】migration 0083 で投入される 4 ボス Enemy の seed 契約テスト。

検証対象:
  - 4 ボス + 既存ゴブリンの計 5 種が DB に存在
  - 各 Enemy の必須フィールド（base_hp / tier / sprite_key）が指示書 §1.2 の値と一致
"""
from django.test import TestCase

from api.models import Enemy


class GuildEnemySeedContractTest(TestCase):
    """FEAT-296 Phase 2-1: 4 ボス + ゴブリンが seed されている契約。"""

    def test_all_five_enemies_exist_after_migrations(self):
        """migration 0082 (goblin) + 0083 (4 ボス) 適用後、5 種が存在する。"""
        keys = set(Enemy.objects.values_list('key', flat=True))
        expected = {
            'goblin',         # migration 0082
            'giant_slime',    # migration 0083
            'goblin_king',    # migration 0083
            'dragon',         # migration 0083
            'shadow_mage',    # migration 0083
        }
        # 期待値が全て含まれていることを assert（テスト DB に他の seed が混在しても通る）
        self.assertTrue(
            expected.issubset(keys),
            'migration 0082/0083 で投入される 5 種が DB に存在すべき。'
            f'\n期待: {expected}\n実値: {keys}',
        )

    def test_boss_enemies_have_correct_fields(self):
        """4 体の主要フィールド（FEAT-400 v3 migration 0117 適用後の値）と一致する。

        【FEAT-332 (2026-05-27)】giant_slime/goblin_king/shadow_mage を「ギリギリ倒せる強さ」で調整。
        【FEAT-400 v3 (2026-05-31)】全 12 体 base_hp 固定値再設計 + level_scaling 0.5 統一:
          giant_slime: hp 45 → 180、goblin_king: hp 37 → 220、shadow_mage: hp 33 → 250
          dragon: hp 800 → 350、atk 25 → 10、scaling 2.5 → 0.5
        【FEAT-522 (2026-08-07)】ATK を「設定値 = 実ダメージ」に変更 (migration 0201)。
          base_atk を実ダメージ値に、level_scaling を 0.5 → **0 に反転**:
            giant_slime: atk 9 → 16、goblin_king: atk 9 → 18、
            shadow_mage: atk 10 → 22、dragon: atk 10 → 40
          **期待値は削除ではなく反転している。** 0.5 に戻すと新式
          `base_atk * (1 + level_scaling * max(0, Lv - unlock_level))` で
          解禁 +10 Lv に 6 倍のダメージが出て、設定値と実ダメージが乖離する。
          base_atk はユーザーが実機で確認した値なので、理想値に寄せ直さないこと。
        """
        # 【FEAT-495 (2026-07-25)】reward_exp を bake 済実効値に更新 (旧 raw × 0.3):
        #   giant_slime 30→9 / goblin_king 60→18 / shadow_mage 120→36 / dragon 150→45
        cases = [
            # 【FEAT-400 v3】全体 base_hp 固定値再設計 (unlock で 5 撃設計)
            ('giant_slime', '巨大スライム',   'enemy_giant_slime',  180, 16, 6,  0.0, 15,  9, 'zako'),
            ('goblin_king', 'ゴブリンキング', 'enemy_goblin_king',  220, 18, 9,  0.0, 30, 18, 'boss'),
            ('shadow_mage', 'シャドウメイジ', 'enemy_shadow_mage',  250, 22, 12, 0.0, 60, 36, 'boss'),
            # dragon: hp 800 → 350 (FEAT-400 v3)、atk 25 → 10 → 40、scaling 2.5 → 0.5 → 0 (FEAT-522)
            ('dragon',      'ドラゴン',       'enemy_dragon',       350, 40, 7,  0.0, 80, 45, 'boss'),
        ]
        for key, name, sprite_key, hp, atk, spd, scaling, coins, exp, tier in cases:
            with self.subTest(key=key):
                e = Enemy.objects.get(key=key)
                self.assertEqual(e.name,          name)
                self.assertEqual(e.sprite_key,    sprite_key)
                self.assertEqual(e.base_hp,       hp)
                self.assertEqual(e.base_atk,      atk)
                self.assertEqual(e.base_spd,      spd)
                self.assertAlmostEqual(e.level_scaling, scaling, places=2)
                self.assertEqual(e.reward_coins,  coins)
                self.assertEqual(e.reward_exp,    exp)
                self.assertEqual(e.tier,          tier)
