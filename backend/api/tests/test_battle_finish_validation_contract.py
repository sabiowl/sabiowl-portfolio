"""【2026-08-05】BattleFinishView の入力バリデーション契約テスト。

## なぜ書くか

`views/battle/finish.py` の `post()` は 426 行あり、うち先頭 78 行が
手動の入力パース + バリデーション (`data.get()` を 9 回 + `_parse_used`
クロージャの定義) で占められている。これを DRF Serializer に移行したいが、

  - **エラーコードを縛るテストが 1 件も無かった**
  - Flutter も個別 code を switch しておらず (message 表示のみ)、
    壊しても気づける経路が無い

という状態だったため、**移行の前に現行の挙動をそのまま固定する**。
本テストは移行前の実装に対して pass し、移行後も同じ結果になることで
「挙動を変えていない」ことの証明になる (characterization test)。

## 固定する仕様

| 入力 | 期待 |
|---|---|
| `token` が空 / 非文字列 | 400 `invalid_token` |
| `result` が win/lose/abandon 以外 | 400 `invalid_result` |
| `duration_sec` が **int 以外** | 400 `invalid_duration` |
| `duration_sec` が負 | 400 `invalid_duration` |
| `potions_used` が数値化不能 | 400 `invalid_potions_used` |
| `potions_used` が範囲外 | 400 `potions_used_out_of_range` |
| `*_potion*_used` が数値化不能 | 400 `invalid_<field>` |
| `*_potion*_used` が範囲外 | 400 `<field>_out_of_range` |

## 意図的に残す非対称性

現行実装は **potions 系は `int()` で coerce する** (文字列 "2" を受け付ける)
のに対し、**`duration_sec` は `isinstance(int)` で厳密判定する**
(文字列 "5" を弾く)。この非対称は移行時にも保持する。
「リファクタのついでに挙動を変える」と、退行かどうかの判別がつかなくなるため。
統一するなら別途 FEAT を切って単独で行う。

## 検証順序

現行実装は上から順に検査し、**最初に見つかったエラーだけ**を返す:

    potions_used → recovery_potion_plus_used → attack_potion_used
    → defense_potion_used → token → result → duration_sec

複数フィールドが同時に不正な場合にどの code が返るかも固定する
(DRF Serializer は全フィールドを検証するため、移行時に順序が崩れやすい)。
"""
import datetime

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import (
    Battle, BattleLog, Enemy, PlayerItem, PlayerProfile, WeaponMaster,
)
# 定数の定義元は start.py。finish.py 経由の re-export に依存しない。
from api.views.battle.start import (
    _MAX_NEW_POTIONS_PER_BATTLE,
    _MAX_POTIONS_PER_BATTLE,
)
from ._error_assert import error_code

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
class BattleFinishValidationContractTest(APITestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('vplayer', email='v@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='VPlayer')
        battle_state = self.player.battle
        battle_state.battle_charges      = 3
        battle_state.battle_charges_date = datetime.date.today()
        battle_state.save(update_fields=['battle_charges', 'battle_charges_date'])

        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        Enemy.objects.update_or_create(
            key='goblin',
            defaults={
                'name': 'ゴブリン', 'sprite_key': 'enemy_goblin',
                'base_hp': 60, 'base_atk': 8, 'base_spd': 10,
                'level_scaling': 1.0, 'reward_coins': 10, 'reward_exp': 6,
                'tier': 'zako',
            },
        )
        WeaponMaster.objects.update_or_create(
            key='starter_sword', defaults={'name': '見習いの剣', 'atk_bonus': 10},
        )

        # 有効な battle token を 1 本用意する (バリデーションを通過した後の
        # 経路まで到達させたいケースで使う)
        res = self.client.post(reverse('battle-start'))
        self.assertEqual(res.status_code, 200, res.content)
        self.battle_token = res.data['token']

        self.url = reverse('battle-finish')

    def _finish(self, **overrides):
        payload = {
            'token': self.battle_token,
            'result': 'win',
            'duration_sec': 10,
            'damage_dealt': 10,
            'damage_taken': 0,
            'rounds': 3,
        }
        payload.update(overrides)
        return self.client.post(self.url, payload, format='json')

    # ── token ────────────────────────────────────────────────────

    def test_empty_token_is_invalid_token(self):
        res = self._finish(token='')
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'invalid_token')

    def test_missing_token_is_invalid_token(self):
        payload = {'result': 'win', 'duration_sec': 10}
        res = self.client.post(self.url, payload, format='json')
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'invalid_token')

    def test_non_string_token_is_invalid_token(self):
        res = self._finish(token=12345)
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'invalid_token')

    def test_unknown_token_is_battle_not_found(self):
        """形式は正しいが該当 Battle が無い場合は 404 (400 ではない)。"""
        res = self._finish(token='x' * 40)
        self.assertEqual(res.status_code, 404)
        self.assertEqual(error_code(res), 'battle_not_found')

    # ── result ───────────────────────────────────────────────────

    def test_unknown_result_is_invalid_result(self):
        res = self._finish(result='draw')
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'invalid_result')

    def test_missing_result_is_invalid_result(self):
        payload = {'token': self.battle_token, 'duration_sec': 10}
        res = self.client.post(self.url, payload, format='json')
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'invalid_result')

    def _start_battle(self) -> str:
        """新しい battle を開始して token を返す。

        1 回の出陣で battle_charges を 3 消費するため、
        連続で start するテストでは都度補充する。
        """
        battle_state = self.player.battle
        battle_state.refresh_from_db()
        battle_state.battle_charges      = 3
        battle_state.battle_charges_date = datetime.date.today()
        battle_state.save(update_fields=['battle_charges', 'battle_charges_date'])

        res = self.client.post(reverse('battle-start'))
        self.assertEqual(res.status_code, 200, res.content)
        return res.data['token']

    def test_all_three_results_are_accepted(self):
        """win / lose / abandon はバリデーションを通過する。"""
        for result in ('win', 'lose', 'abandon'):
            with self.subTest(result=result):
                token = self._start_battle()
                res = self._finish(token=token, result=result)
                self.assertNotEqual(
                    res.status_code, 400,
                    f'result={result} がバリデーションで弾かれた',
                )

    # ── duration_sec (厳密 int) ──────────────────────────────────

    def test_string_duration_is_invalid_duration(self):
        """【意図的な非対称】duration_sec は文字列を coerce しない。"""
        res = self._finish(duration_sec='10')
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'invalid_duration')

    def test_negative_duration_is_invalid_duration(self):
        res = self._finish(duration_sec=-1)
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'invalid_duration')

    def test_float_duration_is_invalid_duration(self):
        res = self._finish(duration_sec=1.5)
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'invalid_duration')

    # ── potions_used (coerce する) ───────────────────────────────

    def test_non_numeric_potions_used_is_invalid(self):
        res = self._finish(potions_used='abc')
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'invalid_potions_used')

    def test_numeric_string_potions_used_is_accepted(self):
        """【意図的な非対称】potions 系は文字列を int() で coerce する。"""
        res = self._finish(potions_used='0')
        self.assertNotEqual(
            res.status_code, 400,
            'potions_used の数値文字列が弾かれた (現行は coerce する仕様)',
        )

    def test_negative_potions_used_is_out_of_range(self):
        res = self._finish(potions_used=-1)
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'potions_used_out_of_range')

    def test_too_many_potions_used_is_out_of_range(self):
        res = self._finish(potions_used=_MAX_POTIONS_PER_BATTLE + 1)
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'potions_used_out_of_range')

    def test_none_potions_used_is_treated_as_zero(self):
        """null は 0 扱い (省略と同じ)。"""
        res = self._finish(potions_used=None)
        self.assertNotEqual(res.status_code, 400)

    # ── 新ポーション 3 種 (対称であること) ───────────────────────

    def test_new_potion_fields_invalid_and_range_codes(self):
        fields = (
            'recovery_potion_plus_used',
            'attack_potion_used',
            'defense_potion_used',
        )
        for field in fields:
            with self.subTest(field=field, case='invalid'):
                res = self._finish(**{field: 'abc'})
                self.assertEqual(res.status_code, 400)
                self.assertEqual(error_code(res), f'invalid_{field}')

            with self.subTest(field=field, case='negative'):
                res = self._finish(**{field: -1})
                self.assertEqual(res.status_code, 400)
                self.assertEqual(error_code(res), f'{field}_out_of_range')

            with self.subTest(field=field, case='too_many'):
                res = self._finish(**{field: _MAX_NEW_POTIONS_PER_BATTLE + 1})
                self.assertEqual(res.status_code, 400)
                self.assertEqual(error_code(res), f'{field}_out_of_range')

    # ── 検証順序 (複数エラー時にどれが返るか) ───────────────────

    def test_potions_error_takes_precedence_over_token_error(self):
        """potions_used は token より先に検査される。"""
        res = self._finish(token='', potions_used='abc')
        self.assertEqual(error_code(res), 'invalid_potions_used')

    def test_token_error_takes_precedence_over_result_error(self):
        res = self._finish(token='', result='draw')
        self.assertEqual(error_code(res), 'invalid_token')

    def test_result_error_takes_precedence_over_duration_error(self):
        res = self._finish(result='draw', duration_sec=-1)
        self.assertEqual(error_code(res), 'invalid_result')

    def test_recovery_plus_takes_precedence_over_attack_potion(self):
        res = self._finish(recovery_potion_plus_used='abc', attack_potion_used='abc')
        self.assertEqual(error_code(res), 'invalid_recovery_potion_plus_used')

    # ── 在庫不足 (start 後に在庫が減る race) ─────────────────────
    #
    # `/start/` は宣言時点の所持数を検証するが、その後に別デバイスで消費される
    # ケースがあるため `/finish/` 側でも再検証している (Pre-mortem #5)。
    # `not_enough_potions` / `not_enough_defense_potion` は既存テストが
    # 縛っているが、**上位回復薬と攻撃の薬は未カバー**だったので補う。

    def _start_with_potions(self, item_id: str, field: str, count: int) -> str:
        """指定ポーションを `count` 個持たせて宣言付きで battle を開始する。"""
        battle_state = self.player.battle
        battle_state.refresh_from_db()
        battle_state.battle_charges      = 3
        battle_state.battle_charges_date = datetime.date.today()
        battle_state.save(update_fields=['battle_charges', 'battle_charges_date'])

        PlayerItem.objects.update_or_create(
            player=self.player, item_id=item_id,
            defaults={'quantity': count},
        )
        res = self.client.post(
            reverse('battle-start'), {field: count}, format='json',
        )
        self.assertEqual(res.status_code, 200, res.content)
        return res.data['token']

    def test_not_enough_recovery_potion_plus_on_finish(self):
        token = self._start_with_potions(
            'recovery_potion_plus', 'recovery_potion_plus_to_use', 2,
        )
        # start 後に在庫が消えた状況を作る (他デバイスでの消費を模す)
        PlayerItem.objects.filter(
            player=self.player, item_id='recovery_potion_plus',
        ).update(quantity=0)

        res = self._finish(token=token, recovery_potion_plus_used=2)
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'not_enough_recovery_potion_plus')
        self.assertEqual(res.data['owned'], 0)
        self.assertEqual(res.data['requested'], 2)

    def test_not_enough_attack_potion_on_finish(self):
        token = self._start_with_potions(
            'attack_potion', 'attack_potion_to_use', 2,
        )
        PlayerItem.objects.filter(
            player=self.player, item_id='attack_potion',
        ).update(quantity=0)

        res = self._finish(token=token, attack_potion_used=2)
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'not_enough_attack_potion')
        self.assertEqual(res.data['owned'], 0)
        self.assertEqual(res.data['requested'], 2)

    def test_potion_stock_is_decremented_on_success(self):
        """正常時は宣言・使用したぶんだけ在庫が減る。"""
        token = self._start_with_potions(
            'attack_potion', 'attack_potion_to_use', 3,
        )
        res = self._finish(token=token, attack_potion_used=2)
        self.assertNotEqual(res.status_code, 400, res.content)

        item = PlayerItem.objects.get(player=self.player, item_id='attack_potion')
        self.assertEqual(item.quantity, 1, '在庫が 3 - 2 = 1 になっていない')

    # ── summary_text ─────────────────────────────────────────────

    def test_long_summary_text_is_truncated_not_rejected(self):
        """5000 文字超は 400 ではなく切り詰め (保存先は BattleLog)。"""
        res = self._finish(summary_text='あ' * 6000)
        self.assertNotEqual(res.status_code, 400)
        battle = Battle.objects.get(token=self.battle_token)
        log = BattleLog.objects.get(battle=battle)
        self.assertEqual(
            len(log.summary_text or ''), 5000,
            '5000 文字で切り詰められていない',
        )

    def test_none_summary_text_is_accepted(self):
        res = self._finish(summary_text=None)
        self.assertNotEqual(res.status_code, 400)
