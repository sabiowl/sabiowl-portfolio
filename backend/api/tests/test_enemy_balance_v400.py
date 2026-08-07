"""【FEAT-400 v3 (2026-05-31)】Enemy 全 12 体バランス再調整の契約テスト。

12 シナリオ × 3 段階 (unlock / 指定 Lv / +5 Lv) = 36 assertion。

検証内容:
  1. scaled_hp = base_hp (Lv 固定化): Lv を変えても HP が変わらないこと
  2. 全 12 体 base_hp が FEAT-400 v3 設計値と一致すること (DB 直接確認)
  3. level_scaling が 0 統一されていること (FEAT-522 適用確認)

【FEAT-522 (2026-08-07) 期待値の反転 — テストは削除していない】
検証内容 3 の期待値を **0.5 → 0** に反転した。ATK を「設定値 = 実ダメージ」に
したため。**0.5 に戻すと設定値と実ダメージが乖離する** — 新式
`base_atk * (1 + level_scaling * max(0, Lv - unlock_level))` では
0.5 は「解禁 +1 Lv ごとに +50%」を意味し、解禁 +10 Lv で 6 倍になる。
FEAT-400 v3 の「0.5 統一」は本 FEAT で意図的に破棄した契約であって、
テストごと消してよいという意味ではない (Pre-mortem #3)。
HP 側 (検証内容 1 / 2) は FEAT-522 でも変更していない。

設計仕様:
  zako 系 7 体: unlock で 5-6 撃 (onboarding 体験)
  boss 系 5 体: unlock で 6-7 撃 (挑戦的)、指定 Lv で 5 撃 (倒せる)、+5 Lv で楽勝

【🔴 本テストの役割 — FEAT-521 Phase 1 (2026-08-07) 明記】

**本テストは migration seed の契約であり、prod の運用値 (admin 調整後) とは無関係。
prod の値がここと違っても、それは異常ではない。**

`base_hp` 等の期待値は 12 体分ハードコードされているが、テスト DB は migration から
作られるため、本テストが守っているのは「**migration の seed が設計値どおりか**」で
あって prod の実値ではない。役割が違う。

admin からの balance 調整 (2026-07-09 実装済) は migration を経由しないので、
**調整するほど期待値と prod 値は乖離していく**。これは設計どおりであり、
テストを prod 値に追随させようとしてはいけない (構造的に不可能)。

> この注記が無いと、いずれ誰かが「prod と合っていない = テストが古い」と判断して
> 書き換え、migration seed の契約が失われる (FEAT-521 Pre-mortem #4)。
> prod の実値を知りたいときは admin の一覧 (想定撃数 2 列付き) を見ること。

関連: battle.py scaled_hp 計算式変更 + migration 0117_enemy_balance_full_rebalance
"""
import datetime

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


# (enemy_key, expected_base_hp, unlock_level, target_level, plus5_level)
# base_hp は FEAT-400 v3 migration 0117 適用後の固定値
# unlock_level: 解禁直後 (挑戦的)
# target_level: 「倒せる」指定 Lv
# plus5_level: unlock/target + α で楽勝
_ENEMY_BALANCE_CASES = [
    # zako 系 7 体 (unlock で 5-6 撃、+5 Lv で楽勝)
    ('slime',          130,  1,  1,  5),   # Lv1=5.9撃, +5=楽勝
    ('weak_goblin',    150,  5,  5, 10),   # Lv5=5撃, Lv10=3.75撃(楽)
    ('goblin',         150,  5,  5, 10),   # Lv5=5撃, Lv10=3.75撃(楽)
    ('giant_slime',    180,  8,  8, 13),   # Lv8=5撃, Lv13=4撃(楽)
    ('young_orc',      200, 10, 10, 15),   # Lv10=5撃, Lv15=4撃(楽)
    ('goblin_king',    220, 12, 12, 17),   # Lv12=5撃, Lv17=4撃(楽)
    ('shadow_mage',    250, 15, 15, 20),   # Lv15=5撃, Lv20=4撃(楽)
    # boss 系 5 体 (unlock で辛い、target Lv で倒せる、+5 Lv で楽勝)
    ('armored_knight', 320, 18, 20, 25),   # Lv18=5.7撃(辛), Lv20=5.3撃(倒せる), Lv25=4.57撃(楽)
    ('dragon',         350, 20, 25, 30),   # Lv20=5.8撃(辛), Lv25=5撃(倒せる), Lv30=4.38撃(楽)
    ('ice_witch',      400, 25, 30, 35),   # Lv25=5.7撃(辛), Lv30=5撃(倒せる), Lv35=4撃(楽)
    ('void_dragon',    500, 35, 40, 45),   # Lv35=5.6撃(辛), Lv40=5撃(倒せる), Lv45=4.55撃(楽)
    ('griffin',        600, 35, 50, 55),   # Lv35=6.7撃(辛), Lv50=5撃(倒せる), Lv55=4.32撃(楽)
]


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class EnemyBalanceV400ContractTest(APITestCase):
    """FEAT-400 v3: 全 12 体 HP 固定化 + ATK Lv 連動の契約テスト 3 種。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('player_v400', email='v400@example.com')
        # battle_charges=99: 出陣可能 (charges 不足で失敗しない)
        self.player = PlayerProfile.objects.create(
            user=self.user, name='V400Player', battle_charges=99,
            battle_charges_date=datetime.date.today(),
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    def _set_player_level(self, level):
        """player.level を直接 update_fields で設定する (fast path、EXP 演算なし)。"""
        self.player.level = level
        self.player.save(update_fields=['level'])

    def _reset_daily_battle_count(self):
        """FEAT-398 日次バトル上限をリセット (テスト独立性: 36 回呼ぶと上限超えるため)。"""
        self.player.daily_battle_count = 0
        self.player.save(update_fields=['daily_battle_count'])

    def _start_battle_and_get_hp(self, enemy_key):
        """指定 enemy_key でバトル開始し、返却された enemy.hp を返す。"""
        cache.clear()
        self._reset_daily_battle_count()
        res = self.client.post(
            reverse('battle-start'),
            data={'enemy_key': enemy_key},
            format='json',
        )
        self.assertEqual(
            res.status_code, 200,
            f'{enemy_key}: BattleStartView が 200 を返すべき\n実値: {res.content}',
        )
        return res.data['enemy']['hp']

    # ─────────────────────────────────────────────────────────────
    # シナリオ 1-12 (全 12 体 × 3 段階 = 36 assertion):
    # HP が Lv に依らず base_hp 固定であることを縛る (FEAT-400 v3 計算式変更)
    # ─────────────────────────────────────────────────────────────

    def test_all_12_enemies_hp_fixed_across_3_levels(self):
        """【シナリオ 1-12】全 12 体 × unlock / target / +5 Lv で scaled_hp = base_hp (固定)。

        旧式 int(base_hp * scaling * level) では Lv 上昇で HP 増加していた。
        新式 (FEAT-400 v3): scaled_hp = base_hp — Lv 変化に依らず HP 固定。
        各段階で BattleStartView の返却 hp を確認する。
        """
        for enemy_key, expected_hp, unlock_lv, target_lv, plus5_lv in _ENEMY_BALANCE_CASES:
            # ── Stage 1: unlock レベル (解禁直後、挑戦的) ──────────────────
            with self.subTest(enemy=enemy_key, stage='unlock', lv=unlock_lv):
                self._set_player_level(unlock_lv)
                hp = self._start_battle_and_get_hp(enemy_key)
                self.assertEqual(
                    hp, expected_hp,
                    f'{enemy_key} Lv{unlock_lv} (unlock): '
                    f'hp={hp} != expected={expected_hp}',
                )

            # ── Stage 2: target レベル (倒せる) ────────────────────────────
            with self.subTest(enemy=enemy_key, stage='target', lv=target_lv):
                self._set_player_level(target_lv)
                hp = self._start_battle_and_get_hp(enemy_key)
                self.assertEqual(
                    hp, expected_hp,
                    f'{enemy_key} Lv{target_lv} (target): '
                    f'hp={hp} != expected={expected_hp}',
                )

            # ── Stage 3: +5 Lv (楽勝) ──────────────────────────────────────
            with self.subTest(enemy=enemy_key, stage='plus5', lv=plus5_lv):
                self._set_player_level(plus5_lv)
                hp = self._start_battle_and_get_hp(enemy_key)
                self.assertEqual(
                    hp, expected_hp,
                    f'{enemy_key} Lv{plus5_lv} (+5): '
                    f'hp={hp} != expected={expected_hp}',
                )

    # ─────────────────────────────────────────────────────────────
    # DB 値直接確認: migration 0117 適用後の base_hp が設計値通りか
    # ─────────────────────────────────────────────────────────────

    def test_enemy_base_hp_values_match_v400_design(self):
        """migration 0117 適用後の全 12 体 base_hp が FEAT-400 v3 設計値と一致する。

        BattleStartView 経由でなく Enemy モデル値を直接検証する。
        migration 0117 が apply されていない環境では旧値と不一致になり失敗する。
        """
        for enemy_key, expected_hp, *_ in _ENEMY_BALANCE_CASES:
            with self.subTest(enemy=enemy_key):
                enemy = Enemy.objects.filter(key=enemy_key).first()
                self.assertIsNotNone(
                    enemy,
                    f'enemy "{enemy_key}" が DB に存在しない '
                    f'(migration 0117 or 以前の seed migration が未適用?)',
                )
                self.assertEqual(
                    enemy.base_hp, expected_hp,
                    f'{enemy_key}: base_hp={enemy.base_hp} != 期待={expected_hp} '
                    f'(FEAT-400 v3 migration 0117 未適用?)',
                )

    # ─────────────────────────────────────────────────────────────
    # level_scaling 0 統一確認: migration 0201 (FEAT-522) の scaling 更新を縛る
    # ─────────────────────────────────────────────────────────────

    def test_level_scaling_unified_to_zero_after_migration_0201(self):
        """migration 0201 後、全 12 体の level_scaling が 0 統一であること。

        経緯: 旧 boss 系 (dragon 2.5 / ice_witch 1.4 / void_dragon 1.6 /
        griffin 2.0) を migration 0117 で 0.5 に統一 → **FEAT-522 (migration 0201)
        で 0 に統一**。ATK を「設定値 = 実ダメージ」にしたため。

        【FEAT-522】本テストは 0.5 期待から **反転**したものであって、
        新規追加ではない。0.5 に戻すと設定値と実ダメージが乖離する。
        """
        for enemy_key, *_ in _ENEMY_BALANCE_CASES:
            with self.subTest(enemy=enemy_key):
                enemy = Enemy.objects.filter(key=enemy_key).first()
                self.assertIsNotNone(
                    enemy,
                    f'enemy "{enemy_key}" が DB に存在しない',
                )
                self.assertAlmostEqual(
                    enemy.level_scaling, 0.0, places=2,
                    msg=f'{enemy_key}: level_scaling={enemy.level_scaling} != 0 '
                        f'(FEAT-522 migration 0201 未適用?)',
                )
