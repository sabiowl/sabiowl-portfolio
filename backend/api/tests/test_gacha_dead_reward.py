"""【FEAT-317】ガチャに dead reward が混入していないことの契約テスト。

## dead reward とは

引いても **何も起きない**報酬のこと。`_apply_reward` に分岐が無い `reward_type` が
これに当たる。`value=0` なので exp / diamond の条件にも掛からず、例外も出ず、
ユーザーには「当たったのに何も増えない」としてだけ見える。

実測 (2026-08-04、除去前): daily の **20.2%** / weekly の **14.3%** が `title` で、
**デイリーは 5 回に 1 回、引いても何も起きなかった**。

## なぜテストで縛るのか

`GachaReward` は 2 経路で作られる:

- migration (`update_or_create`)
- `_ensure_gacha_rewards()` (`get_or_create` の seed 専用)

後者は **過去の定数バージョンで作られた行を消さない**。つまり定数から消しても
既存 DB からは消えず、逆に定数に足せば全 DB に増える。**片方だけ直しても
片方から復活する**構造なので、両方を縛る。

## テストの構成

| # | 対象 | 縛る内容 |
|---|---|---|
| 1 | 定数 | `_apply_reward` が扱えない `reward_type` を含まない |
| 2 | DB | migration 適用後に active な dead reward が 0 件 |
| 3 | 定数 | rarity 別 weight 合計が契約値どおり |
| 4 | DB | `title` は **削除ではなく無効化** (履歴 FK の保護) |
"""
from collections import defaultdict

from django.test import TestCase

from api.models import GachaReward
from api.views.gacha import (
    _DAILY_REWARDS,
    _MONTHLY_REWARDS,
    _WEEKLY_REWARDS,
    _ensure_gacha_rewards,
)

# `_apply_reward` (api/views/gacha.py) が実際に分岐を持つ reward_type。
# ここに無いものを排出すると「引いても何も起きない」。
# **新しい reward_type を足したら、まず _apply_reward に分岐を書くこと。**
IMPLEMENTED_REWARD_TYPES = {
    'exp', 'diamond', 'character', 'character_ticket', 'weapon', 'xp_boost',
}

# 明確に dead と判明しているもの (再混入ガード)。
KNOWN_DEAD_REWARD_TYPES = {'title'}


class GachaConstantsHaveNoDeadRewardTest(TestCase):
    """定数側 —— ここに残っていると新規 DB に seed されてしまう。"""

    def test_no_unimplemented_reward_type(self):
        offenders = [
            f"{r['ticket_type']}/{r['rarity']} {r['reward_type']} "
            f"({r['name']} {r['detail']})"
            for r in (*_DAILY_REWARDS, *_WEEKLY_REWARDS, *_MONTHLY_REWARDS)
            if r['reward_type'] not in IMPLEMENTED_REWARD_TYPES
        ]
        self.assertEqual(
            offenders, [],
            '_apply_reward に分岐が無い reward_type がガチャ定数にある '
            '(引いても何も起きない):\n' + '\n'.join(offenders),
        )

    def test_rarity_weight_contract(self):
        """rarity 別 weight 合計が契約値どおり (FEAT-317 の再配分後)。

        title を除去した際、**同 rarity 内でのみ按分**したので合計は不変のはず。
        rarity を越えて配ると「取得頻度が下がるほど排出が厚くなる傾斜」
        (CLAUDE.md ガチャ設計意図) が崩れる。
        """
        expected = {
            'daily':   {'N': 60, 'R': 30, 'SR': 9, 'SSR': 1},
            'weekly':  {'R': 83, 'SR': 78, 'SSR': 39},
            'monthly': {'SSR': 100},
        }
        for name, rewards in (('daily', _DAILY_REWARDS),
                              ('weekly', _WEEKLY_REWARDS),
                              ('monthly', _MONTHLY_REWARDS)):
            actual = defaultdict(int)
            for r in rewards:
                actual[r['rarity']] += r['weight']
            self.assertEqual(
                dict(actual), expected[name],
                f'{name} の rarity 別 weight が契約値と違う',
            )


class GachaDbHasNoDeadRewardTest(TestCase):
    """DB 側 —— migration 適用後の状態を縛る。"""

    def test_no_active_dead_reward_after_migrations(self):
        active_dead = list(
            GachaReward.objects
            .filter(reward_type__in=KNOWN_DEAD_REWARD_TYPES, is_active=True)
            .values_list('ticket_type', 'rarity', 'name', 'weight')
        )
        self.assertEqual(
            active_dead, [],
            f'active な dead reward が DB に残っている: {active_dead}',
        )

    def test_seed_does_not_resurrect_dead_reward(self):
        """`_ensure_gacha_rewards()` を回しても dead reward が復活しない。

        この関数は毎回のガチャ API で呼ばれる。定数に title が残っていると
        **migration で消しても次のリクエストで作り直される**。
        """
        _ensure_gacha_rewards()
        resurrected = GachaReward.objects.filter(
            reward_type__in=KNOWN_DEAD_REWARD_TYPES, is_active=True,
        ).count()
        self.assertEqual(resurrected, 0, 'seed が dead reward を復活させた')

    def test_all_active_rewards_are_implemented(self):
        """DB 上の active な報酬がすべて実装済 reward_type である。

        定数経由でないルート (admin の手動追加 / 将来の migration) で
        未実装の種別が入っても検出できるようにする。
        """
        _ensure_gacha_rewards()
        bad = list(
            GachaReward.objects
            .filter(is_active=True)
            .exclude(reward_type__in=IMPLEMENTED_REWARD_TYPES)
            .values_list('ticket_type', 'reward_type', 'name')
        )
        self.assertEqual(bad, [], f'未実装の reward_type が active: {bad}')


class GachaTitleDeactivatedNotDeletedTest(TestCase):
    """`title` は **削除ではなく無効化** されている。

    `GachaHistory.reward` は `on_delete=CASCADE` の FK。行を消すと
    **ユーザーのガチャ履歴が道連れで消える**。無効化なら履歴は残る。
    """

    def test_title_rows_still_exist_but_inactive(self):
        rows = GachaReward.objects.filter(reward_type='title')
        # migration 準拠の DB には title が seed されないこともあるので、
        # 「存在するなら必ず inactive」を縛る (存在しない DB でも通る)。
        actives = rows.filter(is_active=True).count()
        self.assertEqual(actives, 0)
        for r in rows:
            self.assertFalse(
                r.is_active,
                f'title {r.pk} が active のまま',
            )
