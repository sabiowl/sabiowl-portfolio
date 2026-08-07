"""【FEAT-302 Phase 1】敵 3 体追加 + 弱点 / 耐性 + 段階解放の Backend 契約テスト 4 件。

指示書 §3.1 シナリオ:
  - シナリオ A: 3 新規 enemy (armored_knight / ice_witch / void_dragon) が seed されている
  - シナリオ B: 既存 5 enemy の tier が不変（後方互換性、Pre-mortem #5）
  - シナリオ C: EnemyListView レスポンスに新規 4 フィールド
    (physical_resistance / magical_resistance / weak_ult_cost / unlock_level) が含まれる
  - シナリオ D: tier choices に mid_boss / hidden_boss が含まれる + filter で機能する

【FEAT-522 (2026-08-07)】シナリオ A の `base_atk` 期待値を実ダメージ値に更新した。
ATK を「設定値 = 実ダメージ」にしたため (migration 0201)。値はユーザーが実機で
確認したもので、理想計算とは整数丸めの分ずれている (armored_knight 理想 33 /
検証済 36)。**理想値に寄せ直さないこと。**

> 本ファイルは FEAT-522 指示書 §5 の変更対象表に **載っていなかった**。
> `base_atk` を assert している契約テストは指示書が挙げた 3 件ではなく 4 件ある。
> フルスイートを回して初めて発覚したので、次に enemy のバランス値を触る人は
> `grep -rn "base_atk" api/tests/` で全件を洗い出すこと。
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Enemy, PlayerProfile

User = get_user_model()


_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework.authtoken.authentication.TokenAuthentication',
        'api.authentication.GuestTokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
}


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class EnemyResistanceContractTest(APITestCase):
    """FEAT-302: Enemy モデル拡張 + 3 体 seed + EnemyListView レスポンスの契約。"""

    def setUp(self):
        cache.clear()  # cache_page(60*5) でキャッシュされないよう毎テストでクリア
        self.user = User.objects.create_user('player1', email='p1@example.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='Player1', battle_charges=3,
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    # ─────────────────────────────────────────────────────────────
    # シナリオ A: 3 新規 enemy が seed されている（migration 0088 結果）
    # ─────────────────────────────────────────────────────────────
    def test_3_new_enemies_seeded_with_correct_values(self):
        """指示書 §2.1 PM 確定値が migration 0088 で正しく投入されたことを縛る。"""
        expected = {
            'armored_knight': {
                'name':                '鎧の騎士',
                'tier':                'mid_boss',
                # 【FEAT-332 (2026-05-27)】unlock_level 15 → 18 調整。
                # 【FEAT-400 v3 (2026-05-31)】base_hp 31 → 320 (固定値で Lv 18 解禁直後 5.7 撃設計)。
                'unlock_level':        18,
                'base_hp':             320,
                # 【FEAT-522 (2026-08-07)】base_atk 9 → 36 = 1 発の実ダメージ。
                'base_atk':            36,
                # 【BUG-81 (2026-06-10)】報酬逆転解消 (ulv17 lizard 40/85 より低かったため上方修正)。
                # 【FEAT-495 (2026-07-25)】reward_exp は bake 済実効値 (旧 raw 95 の × 0.3)
                'reward_coins':        45,
                'reward_exp':          28,
                'physical_resistance': 0.7,
                'magical_resistance':  1.0,
                'weak_ult_cost':       None,
            },
            'ice_witch': {
                'name':                '氷の魔女',
                'tier':                'boss',
                'unlock_level':        25,
                # 【FEAT-400 v3 (2026-05-31)】base_hp 600 → 400, base_atk 28 → 12 (scaling 0.5 統一)。
                'base_hp':             400,
                # 【FEAT-522 (2026-08-07)】base_atk 12 → 37 = 1 発の実ダメージ。
                # 旧式ではこの 12 が Lv 25 で 150 ダメージになっていた。
                'base_atk':            37,
                # 【BUG-81 (2026-06-10)】dark_knight (ulv22) 50/100 との逆転解消。
                # 【FEAT-495 (2026-07-25)】reward_exp は bake 済実効値 (旧 raw 125 の × 0.3)
                # 【BUG-140 (2026-07-25)】dragon Lv 20 (45) との同 tier boss 逆転解消で 37 → 48
                'reward_coins':        55,
                'reward_exp':          48,
                'physical_resistance': 1.0,
                'magical_resistance':  0.5,
                'weak_ult_cost':       4,  # thief (ultCost=4) で Critical
            },
            'void_dragon': {
                'name':                '虚空の竜',
                'tier':                'hidden_boss',
                'unlock_level':        35,
                # 【FEAT-400 v3 (2026-05-31)】base_hp 1200 → 500, base_atk 40 → 11 (scaling 0.5 統一)。
                'base_hp':             500,
                # 【FEAT-522 (2026-08-07)】base_atk 11 → 87 = 1 発の実ダメージ。
                'base_atk':            87,
                # 【FEAT-495 (2026-07-25)】reward_exp は bake 済実効値 (旧 raw 300 の × 0.3)
                'reward_coins':        100,
                'reward_exp':          90,
                'physical_resistance': 1.0,
                'magical_resistance':  1.0,
                'weak_ult_cost':       None,
            },
        }
        for key, exp in expected.items():
            e = Enemy.objects.filter(key=key).first()
            self.assertIsNotNone(e, f'enemy "{key}" が seed されていない')
            for field, value in exp.items():
                actual = getattr(e, field)
                if isinstance(value, float):
                    self.assertAlmostEqual(
                        actual, value, places=2,
                        msg=f'{key}.{field} 不一致: 期待={value} 実値={actual}',
                    )
                else:
                    self.assertEqual(
                        actual, value,
                        f'{key}.{field} 不一致: 期待={value} 実値={actual}',
                    )

    # ─────────────────────────────────────────────────────────────
    # シナリオ B: 既存 5 enemy の tier が不変（Pre-mortem #5 後方互換性）
    # ─────────────────────────────────────────────────────────────
    def test_existing_5_enemies_tier_unchanged(self):
        """migration 0087 (AlterField tier choices 拡張) で既存データに副作用がないこと。

        新規 3 体追加で choices=mid_boss/hidden_boss が増えたが、既存 5 体の
        tier 値 (zako/boss) は変わってはいけない。
        """
        expected_existing = {
            'goblin':      'zako',
            'giant_slime': 'zako',
            'goblin_king': 'boss',
            'dragon':      'boss',
            'shadow_mage': 'boss',
        }
        for key, expected_tier in expected_existing.items():
            e = Enemy.objects.filter(key=key).first()
            self.assertIsNotNone(e, f'既存 enemy "{key}" が消えている')
            self.assertEqual(
                e.tier, expected_tier,
                f'{key}.tier が migration 0087/0088 で変わった: '
                f'期待={expected_tier} 実値={e.tier}',
            )
            # 新規フィールドは default 値（耐性なし）が入っているはず
            self.assertEqual(
                e.physical_resistance, 1.0,
                f'{key}: 既存 enemy の physical_resistance は default 1.0 のはず',
            )
            self.assertEqual(
                e.magical_resistance, 1.0,
                f'{key}: 既存 enemy の magical_resistance は default 1.0 のはず',
            )
            self.assertIsNone(
                e.weak_ult_cost,
                f'{key}: 既存 enemy の weak_ult_cost は default null のはず',
            )
            # 【FEAT-332 (2026-05-27)】unlock_level の段階解禁化 + ギリギリ倒せる強さ調整。
            # FEAT-329 (migration 0096) で boss 系 3 体を段階解禁したが、本要件で更に
            # 上方修正 + zako 系 (goblin/giant_slime) も解禁レベル化。
            # PM 推奨設計 (migration 0099) に整合する期待値マップ。
            expected_unlock_levels = {
                'goblin':      5,   # FEAT-332: 旧 0 → 5、最弱位置の上方修正
                'giant_slime': 8,   # FEAT-332: 旧 0 → 8、zako 中位
                'goblin_king': 12,  # FEAT-332: 旧 8 → 12、boss 入口
                'shadow_mage': 15,  # FEAT-332: 旧 12 → 15、魔法系ミドル
                'dragon':      20,  # 維持 (FEAT-329)
            }
            self.assertEqual(
                e.unlock_level, expected_unlock_levels[key],
                f'{key}: unlock_level 期待={expected_unlock_levels[key]} 実値={e.unlock_level} '
                f'(FEAT-332 解禁レベル変更 + ギリギリ倒せる強さ調整、migration 0099)',
            )

    # ─────────────────────────────────────────────────────────────
    # シナリオ C: EnemyListView レスポンスに新規 4 フィールドが含まれる
    # ─────────────────────────────────────────────────────────────
    def test_enemy_list_response_includes_new_4_fields(self):
        """GET /battle/enemies/ の各 enemy エントリに新規フィールドが入ること。

        Flutter `EnemyMaster.fromJson` が読む契約を縛る（fromJson null 安全側に
        書いてあっても、Backend が出さないと UI で機能しない）。
        """
        res = self.client.get(reverse('battle-enemies'))
        self.assertEqual(res.status_code, 200, res.content)
        enemies = res.data.get('enemies', [])
        self.assertGreaterEqual(
            len(enemies), 8,
            'enemies は既存 5 + 新規 3 = 8 件以上のはず',
        )
        for e in enemies:
            self.assertIn('physical_resistance', e,
                          f'{e.get("key")}: physical_resistance フィールド欠落')
            self.assertIn('magical_resistance', e,
                          f'{e.get("key")}: magical_resistance フィールド欠落')
            self.assertIn('weak_ult_cost', e,
                          f'{e.get("key")}: weak_ult_cost フィールド欠落')
            self.assertIn('unlock_level', e,
                          f'{e.get("key")}: unlock_level フィールド欠落')

        # 具体値も 1 体だけサニティ確認（ice_witch の弱点 + 耐性が正しく含まれる）
        ice = next((e for e in enemies if e['key'] == 'ice_witch'), None)
        self.assertIsNotNone(ice, 'ice_witch がレスポンスに含まれていない')
        self.assertEqual(ice['weak_ult_cost'], 4)
        self.assertEqual(ice['unlock_level'], 25)
        self.assertAlmostEqual(ice['magical_resistance'], 0.5, places=2)

    # ─────────────────────────────────────────────────────────────
    # シナリオ D: tier choices 拡張 + filter で動作
    # ─────────────────────────────────────────────────────────────
    def test_tier_filter_supports_new_tiers(self):
        """tier クエリ ?tier=mid_boss / ?tier=hidden_boss で正しく filter される。

        【FEAT-401 (2026-05-31)】12 体追加により tier=mid_boss / boss の数が増加。
        exact 比較 → issubset に緩和し、新規 enemy 追加時に本テストが壊れない設計に変更。
        各 tier の代表 enemy の存在 + 意図しない tier 混在のないことを縛る。
        """
        # mid_boss → armored_knight (既存) + ogre / lizard_warrior / dark_knight (FEAT-401)
        res = self.client.get(reverse('battle-enemies'), {'tier': 'mid_boss'})
        self.assertEqual(res.status_code, 200, res.content)
        keys = set(e['key'] for e in res.data['enemies'])
        # 既存 armored_knight が含まれること
        self.assertIn(
            'armored_knight', keys,
            f'tier=mid_boss に armored_knight が含まれるはず、実値: {keys}',
        )
        # 【FEAT-401】新規 3 体も含まれること
        for key in ('ogre', 'lizard_warrior', 'dark_knight'):
            self.assertIn(
                key, keys,
                f'tier=mid_boss に {key} が含まれるはず (FEAT-401 追加)、実値: {keys}',
            )
        # zako が混入していないこと (filter 機能確認)
        for e in res.data['enemies']:
            self.assertEqual(e['tier'], 'mid_boss',
                             f'{e["key"]}: tier=mid_boss フィルタで zako/boss が混入')

        # hidden_boss → void_dragon + griffin (既存) + chimera / lich_king / leviathan (FEAT-401)
        cache.clear()
        res = self.client.get(reverse('battle-enemies'), {'tier': 'hidden_boss'})
        self.assertEqual(res.status_code, 200, res.content)
        keys = set(e['key'] for e in res.data['enemies'])
        self.assertIn(
            'void_dragon', keys,
            f'tier=hidden_boss に void_dragon が含まれるはず、実値: {keys}',
        )
        # 【FEAT-383 / migration 0109】griffin も hidden_boss
        self.assertIn(
            'griffin', keys,
            f'tier=hidden_boss に griffin が含まれるはず (migration 0109 追加済)、実値: {keys}',
        )
        # 【FEAT-401】新規 3 体も含まれること
        for key in ('chimera', 'lich_king', 'leviathan'):
            self.assertIn(
                key, keys,
                f'tier=hidden_boss に {key} が含まれるはず (FEAT-401 追加)、実値: {keys}',
            )

        # boss → 既存 4 体 + fire_demon / vampire_lord (FEAT-401)
        cache.clear()
        res = self.client.get(reverse('battle-enemies'), {'tier': 'boss'})
        self.assertEqual(res.status_code, 200, res.content)
        keys = set(e['key'] for e in res.data['enemies'])
        # 既存 4 体が含まれること
        self.assertTrue(
            {'goblin_king', 'dragon', 'shadow_mage', 'ice_witch'}.issubset(keys),
            f'tier=boss: 既存 4 体が含まれるはず、実値: {keys}',
        )
        # 【FEAT-401】新規 2 体も含まれること
        for key in ('fire_demon', 'vampire_lord'):
            self.assertIn(
                key, keys,
                f'tier=boss に {key} が含まれるはず (FEAT-401 追加)、実値: {keys}',
            )
        # mid_boss / zako が混入していないこと (filter 機能確認)
        for e in res.data['enemies']:
            self.assertEqual(e['tier'], 'boss',
                             f'{e["key"]}: tier=boss フィルタで他 tier が混入')
