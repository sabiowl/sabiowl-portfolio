"""【FEAT-401 (2026-05-31)】Enemy 12 体追加 (12 → 24 体) の契約テスト。

12 シナリオ = 新規追加 12 体 × 以下を検証:
  1. DB に存在すること (migration 0118 apply 確認)
  2. 全属性が指示書 §2.2 仕様通りであること
  3. tier が正しいこと (zako/mid_boss/boss/hidden_boss)
  4. 耐性 (physical/magical resistance) が仕様通りであること
  5. unlock_level がバランス設計 (5-6 撃) と整合すること

balance sanity チェック式 (FEAT-400 v3 slime Lv1 → 5.9 撃から逆算):
  player_atk_approx = 20 + 2 * unlock_level  (Lv1 ≈ 22, Lv18 ≈ 56 ≒ 実測値)
  hits = base_hp / player_atk_approx
  期待: 4.0 ≤ hits ≤ 7.0 (適正難易度レンジ)

【FEAT-522 (2026-08-07) 期待値の反転 — テストは削除していない】
`level_scaling` の期待値を **0.5 → 0** に反転し、`base_atk` を実ダメージ値に
差し替えた。ATK を「設定値 = 実ダメージ」にしたため
(`base_atk * (1 + level_scaling * max(0, Lv - unlock_level))`)。

**0.5 に戻すと設定値と実ダメージが乖離する。** 新式では 0.5 は
「解禁 +1 Lv ごとに +50%」の意味になり、解禁 +10 Lv で 6 倍のダメージになる。
FEAT-400 v3 / FEAT-401 の「0.5 統一」契約は本 FEAT で意図的に破棄した契約であって、
テストごと消してよいという意味ではない (Pre-mortem #3)。
"""
from django.test import TestCase

from api.models import Enemy


# (key, name, tier, unlock_level, base_hp, base_atk, base_spd,
#  level_scaling, reward_coins, reward_exp,
#  physical_resistance, magical_resistance, weak_ult_cost)
# 【FEAT-401 v2 (2026-05-31)】バランス調整後の値:
#   zako 系: base_hp 引き上げ (unlock 撃数 5.0-5.1 目標)
#   mid_boss~hidden_boss: base_hp 引き上げ + 上位は base_atk 削減 (Player 生存性確保)
# 【FEAT-495 (2026-07-25)】reward_exp を bake 済実効値に更新 (旧 raw × 0.3):
#   bat 18→5 / rat 22→6 / skeleton 35→10 / wolf 60→18 / ogre 70→21 /
#   lizard_warrior 85→25 / dark_knight 100→30 / fire_demon 130→39 /
#   vampire_lord 145→43 / chimera 215→64 / lich_king 245→73 / leviathan 280→84
# 【BUG-140 (2026-07-25)】boss + griffin 同 tier monotonic 回復で 2 敵上方修正:
#   fire_demon 39→52 / vampire_lord 43→56 (dragon Lv 20 45 → ice_witch → fire_demon → vampire_lord)
# 【FEAT-522 (2026-08-07)】base_atk = 実ダメージ / level_scaling = 0 に更新。
# base_atk はユーザーが実機で確認して「丁度良い」と判断した値であり、理想計算とは
# 整数丸めの分だけずれている。**きれいな値に寄せ直さないこと** (指示書 §4)。
_NEW_ENEMY_SPECS = [
    ('bat',           'コウモリ',           'zako',        2, 170,  3,  8, 0.0, 8,    5,  1.0, 1.0, None),
    ('rat',           'ジャイアントラット',  'zako',        3, 180,  4,  6, 0.0, 10,   6,  1.0, 1.0, None),
    ('skeleton',      'スケルトン',          'zako',        7, 220, 14,  5, 0.0, 18,  10,  0.8, 1.0, None),
    ('wolf',          'ダイアウルフ',        'zako',       11, 265, 11,  9, 0.0, 30,  18,  1.0, 1.0, None),
    ('ogre',          'オーガ',              'mid_boss',   14, 350, 35,  4, 0.0, 35,  21,  1.0, 1.0, None),
    ('lizard_warrior','リザード戦士',        'mid_boss',   17, 390, 34,  6, 0.0, 40,  25,  1.0, 0.8, None),
    ('dark_knight',   '闇の騎士',            'mid_boss',   22, 440, 44,  7, 0.0, 50,  30,  0.7, 1.0, None),
    ('fire_demon',    '炎の悪魔',            'boss',       28, 510, 56,  9, 0.0, 60,  52,  1.0, 0.6, None),
    ('vampire_lord',  '吸血鬼の王',          'boss',       32, 560, 48, 11, 0.0, 70,  56,  0.7, 1.0, None),
    # 【BUG-81 (2026-06-10)】以下 3 体は griffin/void_dragon (ulv35) 100c との逆転解消で上方修正済み
    ('chimera',       'キメラ',              'hidden_boss',38, 640, 95,  8, 0.0, 105, 64,  0.85,0.85,None),
    ('lich_king',     'リッチキング',        'hidden_boss',42, 700,126,  7, 0.0, 115, 73,  1.0, 0.5, 4),
    ('leviathan',     'リヴァイアサン',      'hidden_boss',48, 750,240,  5, 0.0, 125, 84,  0.9, 1.0, None),
]


class EnemyRosterV401ContractTest(TestCase):
    """FEAT-401: 追加 12 体が migration 0118 で正しく seed されていること。"""

    # ─────────────────────────────────────────────────────────────
    # シナリオ 1-12: 各 enemy の全属性 + tier + 耐性 + balance 検証
    # ─────────────────────────────────────────────────────────────

    def test_all_12_new_enemies_seeded_with_correct_attributes(self):
        """【シナリオ 1-12】追加 12 体の全属性が指示書 §2.2 通りであること。

        migration 0118 が apply されていない環境では全 subTest が失敗する。
        各 enemy で: 存在確認 / name / tier / unlock_level / base_hp / base_atk /
        base_spd / level_scaling / reward_coins / reward_exp /
        physical_resistance / magical_resistance / weak_ult_cost を検証。
        """
        for spec in _NEW_ENEMY_SPECS:
            (key, name, tier, unlock_level, base_hp, base_atk, base_spd,
             scaling, coins, exp, phys_res, mag_res, weak_ult) = spec

            with self.subTest(enemy=key):
                e = Enemy.objects.filter(key=key).first()
                self.assertIsNotNone(
                    e,
                    f'enemy "{key}" が DB に存在しない '
                    f'(migration 0118_enemy_roster_expansion が未適用?)',
                )
                self.assertEqual(e.name,          name,
                                 f'{key}: name 不一致')
                self.assertEqual(e.tier,          tier,
                                 f'{key}: tier 不一致: 期待={tier} 実値={e.tier}')
                self.assertEqual(e.unlock_level,  unlock_level,
                                 f'{key}: unlock_level 不一致')
                self.assertEqual(e.base_hp,       base_hp,
                                 f'{key}: base_hp 不一致: 期待={base_hp} 実値={e.base_hp}')
                self.assertEqual(e.base_atk,      base_atk,
                                 f'{key}: base_atk 不一致')
                self.assertEqual(e.base_spd,      base_spd,
                                 f'{key}: base_spd 不一致')
                self.assertAlmostEqual(e.level_scaling, scaling, places=2,
                                       msg=f'{key}: level_scaling 不一致')
                self.assertEqual(e.reward_coins,  coins,
                                 f'{key}: reward_coins 不一致')
                self.assertEqual(e.reward_exp,    exp,
                                 f'{key}: reward_exp 不一致')
                self.assertAlmostEqual(e.physical_resistance, phys_res, places=2,
                                       msg=f'{key}: physical_resistance 不一致')
                self.assertAlmostEqual(e.magical_resistance,  mag_res,  places=2,
                                       msg=f'{key}: magical_resistance 不一致')
                self.assertEqual(e.weak_ult_cost, weak_ult,
                                 f'{key}: weak_ult_cost 不一致')

    def test_12_new_enemies_balance_sanity_at_unlock(self):
        """【balance sanity】unlock_level で「4〜7 撃」レンジ内であること。

        FEAT-400 v3 計算式 (scaled_hp = base_hp 固定) に基づき、
        unlock 時点の推定撃数が適正難易度レンジ内であることを縛る。

        推定式: player_atk_approx = 20 + 2 * unlock_level
          (slime Lv1 の実測 5.9 撃から逆算: base=20, step=2)
        期待: 4.0 ≤ hits ≤ 7.0 (unlock で倒せる、ただし挑戦的)
        """
        for spec in _NEW_ENEMY_SPECS:
            key = spec[0]
            unlock_level = spec[3]
            base_hp      = spec[4]

            with self.subTest(enemy=key):
                e = Enemy.objects.filter(key=key).first()
                if e is None:
                    self.skipTest(f'{key} が DB に存在しないため balance 検証をスキップ')

                player_atk_approx = 20 + 2 * unlock_level
                hits = e.base_hp / player_atk_approx

                self.assertGreaterEqual(
                    hits, 4.0,
                    f'{key} Lv{unlock_level}: hits={hits:.2f} < 4.0 '
                    f'(player_atk≈{player_atk_approx}, hp={e.base_hp}) — 簡単すぎる',
                )
                self.assertLessEqual(
                    hits, 8.0,
                    f'{key} Lv{unlock_level}: hits={hits:.2f} > 8.0 '
                    f'(player_atk≈{player_atk_approx}, hp={e.base_hp}) — 難しすぎる',
                )

    def test_tier_distribution_correct(self):
        """追加 12 体の tier 分布が設計 (zako 4 / mid_boss 3 / boss 2 / hidden_boss 3) 通り。"""
        zako_keys        = {'bat', 'rat', 'skeleton', 'wolf'}
        mid_boss_keys    = {'ogre', 'lizard_warrior', 'dark_knight'}
        boss_keys        = {'fire_demon', 'vampire_lord'}
        hidden_boss_keys = {'chimera', 'lich_king', 'leviathan'}

        all_new_keys = zako_keys | mid_boss_keys | boss_keys | hidden_boss_keys
        existing_keys = set(
            Enemy.objects.filter(key__in=all_new_keys)
                         .values_list('key', flat=True)
        )

        self.assertEqual(all_new_keys, existing_keys,
                         f'追加 12 体のうち未 seed の enemy: '
                         f'{all_new_keys - existing_keys}')

        for key in zako_keys:
            self.assertEqual(Enemy.objects.get(key=key).tier, 'zako',
                             f'{key}: tier は zako のはず')
        for key in mid_boss_keys:
            self.assertEqual(Enemy.objects.get(key=key).tier, 'mid_boss',
                             f'{key}: tier は mid_boss のはず')
        for key in boss_keys:
            self.assertEqual(Enemy.objects.get(key=key).tier, 'boss',
                             f'{key}: tier は boss のはず')
        for key in hidden_boss_keys:
            self.assertEqual(Enemy.objects.get(key=key).tier, 'hidden_boss',
                             f'{key}: tier は hidden_boss のはず')

    def test_level_scaling_unified_to_zero(self):
        """追加 12 体の level_scaling が全て 0 (FEAT-522 固定ダメージ)。

        【FEAT-522 (2026-08-07)】FEAT-400 v3 の「0.5 統一」から **0 に反転**した。
        テストは削除していない — 0.5 に戻ると新式
        `base_atk * (1 + level_scaling * max(0, Lv - unlock_level))` で
        解禁 +10 Lv に 6 倍のダメージが出て、設定値と実ダメージが乖離するため。
        """
        for spec in _NEW_ENEMY_SPECS:
            key = spec[0]
            with self.subTest(enemy=key):
                e = Enemy.objects.filter(key=key).first()
                if e is None:
                    self.skipTest(f'{key} が DB に存在しない')
                self.assertAlmostEqual(
                    e.level_scaling, 0.0, places=2,
                    msg=f'{key}: level_scaling={e.level_scaling} != 0 '
                        f'(FEAT-522 固定ダメージ違反。0.5 のまま残っていると'
                        f' 解禁 +10 Lv で 6 倍のダメージになる)',
                )

    def test_resistances_for_special_enemies(self):
        """耐性を持つ 6 体 (skeleton/dark_knight/lizard_warrior/fire_demon/vampire_lord/chimera/lich_king/leviathan) の値。"""
        resistance_cases = [
            # (key, physical_resistance, magical_resistance)
            ('skeleton',       0.8,  1.0),  # 骨は物理耐性
            ('dark_knight',    0.7,  1.0),  # 黒鎧で物理耐性
            ('lizard_warrior', 1.0,  0.8),  # 鱗で魔法耐性
            ('fire_demon',     1.0,  0.6),  # 炎で魔法耐性
            ('vampire_lord',   0.7,  1.0),  # 不死で物理耐性
            ('chimera',        0.85, 0.85), # 合成獣で両耐性
            ('lich_king',      1.0,  0.5),  # 死霊術士で魔法耐性
            ('leviathan',      0.9,  1.0),  # 海の怪物
        ]
        for key, phys, mag in resistance_cases:
            with self.subTest(enemy=key):
                e = Enemy.objects.filter(key=key).first()
                if e is None:
                    self.skipTest(f'{key} が DB に存在しない')
                self.assertAlmostEqual(
                    e.physical_resistance, phys, places=2,
                    msg=f'{key}: physical_resistance={e.physical_resistance} != {phys}',
                )
                self.assertAlmostEqual(
                    e.magical_resistance, mag, places=2,
                    msg=f'{key}: magical_resistance={e.magical_resistance} != {mag}',
                )

    def test_lich_king_has_weak_ult_cost_4(self):
        """lich_king の weak_ult_cost=4 (thief Critical +30% 弱点設計)。"""
        e = Enemy.objects.filter(key='lich_king').first()
        if e is None:
            self.skipTest('lich_king が DB に存在しない')
        self.assertEqual(e.weak_ult_cost, 4,
                         'lich_king: weak_ult_cost は 4 (thief で Critical) のはず')

    def test_total_enemy_count_after_migration(self):
        """migration 0118 適用後、Enemy 総数が 24 体以上であること。"""
        total = Enemy.objects.count()
        self.assertGreaterEqual(
            total, 24,
            f'Enemy 総数 {total} < 24 — migration 0118 が未適用か、seed が不足',
        )

    def test_reward_curve_increases_with_tier(self):
        """追加 12 体の報酬曲線: zako < mid_boss < boss < hidden_boss の傾向。"""
        new_keys = [s[0] for s in _NEW_ENEMY_SPECS]
        existing = Enemy.objects.filter(key__in=new_keys)
        if existing.count() < 12:
            self.skipTest('追加 12 体が全て seed されていない')

        zako_max_coins    = existing.filter(tier='zako').order_by('-reward_coins').first().reward_coins
        mid_boss_min      = existing.filter(tier='mid_boss').order_by('reward_coins').first().reward_coins
        boss_min          = existing.filter(tier='boss').order_by('reward_coins').first().reward_coins
        hidden_boss_min   = existing.filter(tier='hidden_boss').order_by('reward_coins').first().reward_coins

        self.assertLess(zako_max_coins, mid_boss_min,
                        f'zako 最大 {zako_max_coins} ≥ mid_boss 最小 {mid_boss_min} — 報酬逆転')
        self.assertLess(mid_boss_min, boss_min,
                        f'mid_boss 最小 {mid_boss_min} ≥ boss 最小 {boss_min} — 報酬逆転')
        self.assertLess(boss_min, hidden_boss_min,
                        f'boss 最小 {boss_min} ≥ hidden_boss 最小 {hidden_boss_min} — 報酬逆転')
