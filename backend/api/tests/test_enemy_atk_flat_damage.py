"""【FEAT-522 (2026-08-07)】敵 ATK「設定値 = 実ダメージ」の契約テスト。

## 何を守るテストか

旧式 `base_atk * level_scaling * player.level` は FEAT-295 (バトル MVP 初版) の
ままで、admin に 12 と入れた ice_witch が Lv 25 で 150、Lv 48 では設定値の 24 倍を
与えていた。**admin の数字から実ダメージが読めない**状態だった。

新式:

    scaled_atk = int(base_atk * (1 + level_scaling * max(0, level - unlock_level)))

`level_scaling` を式から外さなかったのは、外すと死にフィールドになり削除のための
別 FEAT が必要になるため (FEAT-478 → FEAT-488 の前例)。**unlock_level 基点**に
することで意味を持たせ直した。

## テスト群

  A: 24 体全件の `level_scaling == 0` + **件数 24 のハードコード**
     → Pre-mortem #2。0.5 が 1 体でも残ると解禁 +10 Lv で 6 倍のダメージになり、
       原因も分かりにくい。件数を固定しておくと新 enemy 追加時に気付ける。
  B: `base_atk` = 実ダメージ。Lv を変えても一定であることを 3 体で固定
  C: 出陣後に `Enemy.base_atk` を変えても `enemy_atk_init` が追随しない
     → Pre-mortem #4。進行中の戦闘は旧値のまま完走する
  D: `level_scaling` を使った場合の追随の形 (unlock_level 基点であること)
"""
import datetime

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Battle, Enemy, PlayerProfile

User = get_user_model()

# 【Pre-mortem #2】件数をハードコードする。新 enemy を追加したら本テストが落ち、
# 「level_scaling を 0 にしたか」を必ず確認させられる。
_EXPECTED_ENEMY_COUNT = 24

# 【指示書 §4】ユーザーが実機で確認して「丁度良い」と判断した実ダメージ。
# 整数丸めの都合で理想計算とは最大 3 ずれている (armored_knight 理想 33 / 検証済 36)。
# **理想値に寄せ直さないこと。**
_EXPECTED_ATK = {
    'slime': 1,          'bat': 3,           'rat': 4,
    'goblin': 5,         'weak_goblin': 7,   'skeleton': 14,
    'giant_slime': 16,   'young_orc': 20,    'wolf': 11,
    'goblin_king': 18,   'ogre': 35,         'shadow_mage': 22,
    'lizard_warrior': 34,'armored_knight': 36,'dragon': 40,
    'dark_knight': 44,   'ice_witch': 37,    'fire_demon': 56,
    'vampire_lord': 48,  'void_dragon': 87,  'griffin': 52,
    'chimera': 95,       'lich_king': 126,   'leviathan': 240,
}

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


class EnemyLevelScalingZeroContractTest(APITestCase):
    """A — 24 体全件の level_scaling == 0 と件数のハードコード。"""

    def test_all_enemies_have_zero_level_scaling(self):
        """【Pre-mortem #2】0.5 が 1 体でも残っていないこと。

        新式は `1 + scaling * (Lv - unlock)` なので、0.5 が残ると解禁 +10 Lv で
        **6 倍**のダメージになる。1 体だけ極端に強い敵ができ、原因も分かりにくい。
        """
        offenders = {
            e.key: e.level_scaling
            for e in Enemy.objects.all()
            if e.level_scaling != 0.0
        }
        self.assertEqual(
            offenders, {},
            f'level_scaling が 0 でない enemy: {offenders}\n'
            f'新式 base_atk * (1 + scaling * (Lv - unlock)) では、0.5 が残ると'
            f' 解禁 +10 Lv で 6 倍のダメージになる (FEAT-522 Pre-mortem #2)',
        )

    def test_enemy_count_is_pinned(self):
        """件数をハードコードして、新 enemy 追加時に必ず気付けるようにする。"""
        self.assertEqual(
            Enemy.objects.count(), _EXPECTED_ENEMY_COUNT,
            f'Enemy の件数が {_EXPECTED_ENEMY_COUNT} から変わっている。\n'
            f'敵を追加した場合は level_scaling=0 (固定) と base_atk (= 実ダメージ) '
            f'を設定したうえで、本テストの _EXPECTED_ENEMY_COUNT と '
            f'_EXPECTED_ATK を更新すること (FEAT-522)',
        )

    def test_all_enemies_base_atk_matches_verified_values(self):
        """base_atk が実機検証済みの値であること (migration 0201 の適用確認)。"""
        for key, expected in _EXPECTED_ATK.items():
            with self.subTest(enemy=key):
                e = Enemy.objects.filter(key=key).first()
                self.assertIsNotNone(e, f'enemy "{key}" が DB に存在しない')
                self.assertEqual(
                    e.base_atk, expected,
                    f'{key}: base_atk={e.base_atk} != {expected}。\n'
                    f'この値はユーザーが実機で確認した実ダメージ。'
                    f'理想計算とは整数丸めの分ずれているが、寄せ直さないこと (§4)',
                )


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class FlatDamageContractTest(APITestCase):
    """B / C / D — BattleStartView が返す atk の契約。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('player_f522', email='f522@example.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='F522Player', battle_charges=99,
            battle_charges_date=datetime.date.today(),
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    def _start(self, enemy_key):
        cache.clear()
        self.player.daily_battle_count = 0
        self.player.save(update_fields=['daily_battle_count'])
        res = self.client.post(
            reverse('battle-start'),
            data={'enemy_key': enemy_key},
            format='json',
        )
        self.assertEqual(
            res.status_code, 200,
            f'{enemy_key}: BattleStartView が 200 を返すべき\n実値: {res.content}',
        )
        return res.data

    def _set_level(self, level):
        self.player.level = level
        self.player.save(update_fields=['level'])

    # ── B ────────────────────────────────────────────────────────────────
    def test_b_atk_equals_base_atk_across_levels(self):
        """【B】設定値 = 実ダメージ。Lv を変えても atk が動かないこと。

        3 体 × 3 レベル。旧式なら Lv に比例して跳ね上がっていた
        (ice_witch は Lv 25 で 150、Lv 48 で 288)。
        """
        cases = [
            ('slime', 1),          # unlock 0、全レベル帯から挑まれる
            ('armored_knight', 36),  # unlock 18、boss 帯
            ('ice_witch', 37),     # unlock 25、旧式で 150 を出していた敵
        ]
        for enemy_key, expected_atk in cases:
            for level in (1, 25, 48):
                with self.subTest(enemy=enemy_key, level=level):
                    self._set_level(level)
                    data = self._start(enemy_key)
                    self.assertEqual(
                        data['enemy']['atk'], expected_atk,
                        f'{enemy_key} Lv{level}: atk={data["enemy"]["atk"]} '
                        f'!= base_atk={expected_atk}。\n'
                        f'旧式 base_atk * level_scaling * level に戻っていないか',
                    )

    def test_b2_admin_edit_is_reflected_verbatim(self):
        """【B / 実機シナリオ A】admin で base_atk を変えたら、その値がそのまま出る。"""
        Enemy.objects.filter(key='ice_witch').update(base_atk=50)
        self._set_level(30)
        data = self._start('ice_witch')
        self.assertEqual(
            data['enemy']['atk'], 50,
            'admin で 50 に変えたら 50 ダメージちょうどになること。'
            'ここがずれると admin の数字から実ダメージが読めない',
        )

    # ── C ────────────────────────────────────────────────────────────────
    def test_c_enemy_atk_init_is_snapshotted(self):
        """【C / Pre-mortem #4】出陣後に Enemy を変えても進行中の戦闘は追随しない。

        deploy 時点で進行中の戦闘が旧値のまま完走することを保証する。
        `BattleFinishView` の damage 検証 (`_MAX_DAMAGE_MULTIPLIER`) は
        `enemy_hp_init` 基準なので ATK 変更の影響を受けない。
        """
        self._set_level(25)
        data = self._start('ice_witch')
        token = data['token']
        atk_at_start = data['enemy']['atk']
        self.assertEqual(atk_at_start, 37)

        # 出陣後に master data を書き換える (admin 編集 / deploy を模擬)
        Enemy.objects.filter(key='ice_witch').update(base_atk=999)

        battle = Battle.objects.get(token=token)
        self.assertEqual(
            battle.enemy_atk_init, atk_at_start,
            'enemy_atk_init は出陣時のスナップショット。Enemy.base_atk の変更に'
            '追随すると、進行中の戦闘が途中から別物になる',
        )
        self.assertEqual(
            Enemy.objects.get(key='ice_witch').base_atk, 999,
            'master data 側は確かに書き換わっていること (テストが空振りしていない証明)',
        )

    # ── D ────────────────────────────────────────────────────────────────
    def test_d_level_scaling_is_anchored_at_unlock_level(self):
        """【D】level_scaling を使う場合、追随の基点が unlock_level であること。

        `level_scaling` を式から外さなかった意味がここにある。0 でなくても
        「**解禁時のダメージ = 設定値**」は常に成立しなければならない。
        """
        # ice_witch: unlock_level=25, base_atk=37
        Enemy.objects.filter(key='ice_witch').update(level_scaling=0.1)

        # 解禁レベルちょうど → 追随ゼロ = 設定値そのまま
        self._set_level(25)
        self.assertEqual(
            self._start('ice_witch')['enemy']['atk'], 37,
            'level_scaling が 0 でなくても、解禁時のダメージは設定値と一致すること',
        )

        # 解禁より下 → max(0, ...) で下振れしない
        self._set_level(10)
        self.assertEqual(
            self._start('ice_witch')['enemy']['atk'], 37,
            'unlock_level 未満で負のスケールが掛かっていないこと',
        )

        # 解禁 +10 Lv → 37 * (1 + 0.1 * 10) = 74
        self._set_level(35)
        self.assertEqual(
            self._start('ice_witch')['enemy']['atk'], 74,
            'unlock_level からの差分に比例すること',
        )
