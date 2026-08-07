"""【2026-07-09 機能レビュー 20260709 §5 P3 対応】

CharacterStat Lv UP の順方向 (`apply_stat_level_up_step`) と
逆算 (`stat_max_exp_at_level`) の **契約テスト**。

【2026-08-07】逆算関数は admin.py から services/exp_service.py に移設した
(ゲームの計算式が presentation 層に住んでいたため)。旧名は
`api.admin._recalc_character_stat_max_exp` (grep 用に残す)。

背景:
    `int(max_exp * 1.2)` は以前 habits.py / player.py / admin.py の 3 箇所に
    直書きされており、habits.py の倍率変更時に他 2 経路が silent drift する
    リスクを機能レビュー 20260709 §5 が P3 として指摘した。同レビューへの
    対応で `STAT_LEVEL_UP_MULTIPLIER` + `apply_stat_level_up_step` (真実値)
    に集約したが、drift 経路が本当に消滅しているかを構造的に lock するのが
    本テストの役割。

検証内容:
    - Lv 1 (初期値 100) から `apply_stat_level_up_step` を N-1 回まわした
      stat.max_exp が `stat_max_exp_at_level(N)` と完全一致すること
    - N = 1〜25 の全レベルで一致 (境界: N=1 は初期値 100 のまま返る)

将来 drift 検知:
    - 誰かが `stat_max_exp_at_level` を単独で書き換えた
      → 順方向との一致が崩れて本テストが落ちる
    - 誰かが habits.py / player.py で直書きの `* 1.15` を再導入した
      → apply_stat_level_up_step 経由でなくなり回帰テスト側 (habit / player)
      で落ちる想定 (本テストは helper 経由で真実値を確認する立場)
    - 誰かが exp_service.STAT_LEVEL_UP_MULTIPLIER を書き換えた
      → game と admin が同時に追従、本テストは PASS (=drift しない設計)
"""
from django.contrib.auth import get_user_model
from django.test import TestCase

from api.models import CharacterStat, PlayerProfile
from api.services.exp_service import (
    STAT_INITIAL_MAX_EXP,
    STAT_LEVEL_UP_MULTIPLIER,
    apply_stat_level_up_step,
    stat_max_exp_at_level,
)

User = get_user_model()


class CharacterStatLevelUpContractTest(TestCase):
    """順方向と逆算が完全に同一の max_exp シーケンスを生成するか。"""

    MAX_LEVELS_TO_CHECK = 25  # Lv 1〜25 (通常プレイヤーの上限を大きく上回る範囲)

    def setUp(self):
        self.user = User.objects.create_user(
            username='stat_contract', password='pw',
        )
        self.player = PlayerProfile.objects.create(user=self.user)

    def _make_stat(self) -> CharacterStat:
        """初期値 (Lv1 / current_exp=0 / max_exp=100) の stat を作る。"""
        return CharacterStat.objects.create(
            player=self.player, name='運動力',
            level=1, current_exp=0, max_exp=STAT_INITIAL_MAX_EXP,
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: 契約 lock — game 経路と admin 逆算が完全一致
    # ─────────────────────────────────────────────────────────────────
    def test_game_and_admin_max_exp_sequences_match_for_all_levels(self):
        """apply_stat_level_up_step を N-1 回まわした max_exp が
        stat_max_exp_at_level(N) と完全一致する (Lv 1〜25)。"""
        stat = self._make_stat()

        # Lv 1 の境界: iteration 0 回 → 初期値 100 のまま
        self.assertEqual(
            stat.max_exp,
            stat_max_exp_at_level(1),
            msg='Lv1 は初期値 100 が返るはず (iteration 0 回)',
        )

        for target_level in range(2, self.MAX_LEVELS_TO_CHECK + 1):
            # game 経路: 1 反復回す (Lv N-1 → Lv N)
            # ※ current_exp は再増加させないと apply_stat_level_up_step 内で
            #    stat.current_exp -= stat.max_exp によりマイナスになるが、
            #    max_exp / level の追従だけ確認できれば契約テストとしては十分。
            stat.current_exp += stat.max_exp  # 次の Lv UP 分の EXP を注入
            apply_stat_level_up_step(stat)

            expected = stat_max_exp_at_level(target_level)
            self.assertEqual(
                stat.max_exp, expected,
                msg=(
                    f'Lv{target_level}: game 経路 max_exp={stat.max_exp} '
                    f'vs admin 逆算 max_exp={expected} — 両者は drift 不可能な設計のはず。'
                    ' apply_stat_level_up_step / stat_max_exp_at_level のどちらかが'
                    ' STAT_LEVEL_UP_MULTIPLIER を経由せず直書きに戻っていないか確認。'
                ),
            )
            self.assertEqual(
                stat.level, target_level,
                msg=f'Lv{target_level}: apply_stat_level_up_step の level 増分が意図と不一致',
            )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: 実測値の絶対 lock (backup regression)
    # ─────────────────────────────────────────────────────────────────
    def test_admin_helper_returns_expected_absolute_values(self):
        """将来の bug で apply_stat_level_up_step / helper が同じ間違い方をした場合の
        backup regression。事前実測した絶対値 (Lv1=100 ... Lv20=3154) を hardcode 比較。

        Lv1〜Lv10 は機能レビュー 20260709 §2 で shell 検証済みの値。
        """
        # habits.py:156 の `int(x * 1.2)` を手動 iteration した実測値
        # (Python shell 検証: 2026-07-09、詳細は commit message 参照)
        expected_sequence = {
            1: 100,   2: 120,   3: 144,   4: 172,   5: 206,
            6: 247,   7: 296,   8: 355,   9: 426,  10: 511,
            15: 1269, 20: 3154,
        }
        for level, expected in expected_sequence.items():
            actual = stat_max_exp_at_level(level)
            self.assertEqual(
                actual, expected,
                msg=(
                    f'Lv{level}: expected max_exp={expected} but got {actual}. '
                    'STAT_LEVEL_UP_MULTIPLIER (現 1.2) が変更されたか、'
                    'iteration の実装が変わった可能性あり。'
                ),
            )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: 倍率の存在確認 (constant が定義されているか)
    # ─────────────────────────────────────────────────────────────────
    def test_multiplier_constant_is_defined_and_positive(self):
        """STAT_LEVEL_UP_MULTIPLIER が exp_service.py に定義され、意味のある値であること。

        誰かが誤って削除 / 0 / 負値にした場合の即時検出用。
        """
        self.assertGreater(
            STAT_LEVEL_UP_MULTIPLIER, 1.0,
            msg='max_exp が減る/変わらない倍率は Lv UP カーブとして不正',
        )
        self.assertLess(
            STAT_LEVEL_UP_MULTIPLIER, 2.0,
            msg='2 倍以上は明らかに balance 破壊 (v1.0 balance は 1.2)',
        )
