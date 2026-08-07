"""FEAT-213 / FEAT-223 関連の exp_service 単体テスト。

`get_stat_allocations` の整数丸め補正（P2-1 = FEAT-223、機能レビュー 20260515）
を中心に検証する。合計が元 EXP と完全一致することを 11 カテゴリ × 14 EXP 値
= 154 ケースで網羅する `subTest` を含む。
"""
from django.test import TestCase

from api.services.exp_service import get_stat_allocations


class GetStatAllocationsTest(TestCase):
    """【FEAT-223】`get_stat_allocations()` の合計値完全保証テスト。"""

    def test_sum_always_equals_input_for_all_categories(self):
        """全カテゴリ × 多様な EXP 値で、合計が元 EXP と完全一致することを確認。"""
        categories = [
            '運動', '学習', '仕事', '体力', '美容', '健康',
            '精神', '創造', '社交', '休息', 'その他',
        ]
        exp_values = [1, 2, 3, 5, 7, 10, 13, 19, 20, 30, 40, 60, 100, 1000]

        for category in categories:
            for exp in exp_values:
                with self.subTest(category=category, exp=exp):
                    result = get_stat_allocations(category, exp)
                    total = sum(value for _, value in result)
                    self.assertEqual(
                        total, exp,
                        f'{category} × {exp} EXP: 合計 {total} != 元 {exp}',
                    )

    def test_single_stat_categories(self):
        """100% マッピング（単一 stat 1.0）カテゴリでは元値そのまま返ることを確認。"""
        for category, expected_stat in [
            ('運動', '運動力'),
            ('美容', '健康力'),
            ('健康', '健康力'),
            ('精神', '精神力'),
            ('創造', '創造力'),
            ('社交', '貢献力'),
        ]:
            result = get_stat_allocations(category, 17)
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0], (expected_stat, 17))

    def test_dual_stat_50_50_categories(self):
        """50/50 分散カテゴリでは余りを最初の stat に加算することを確認。"""
        # 体力 → 運動力 0.5 + 健康力 0.5
        result = get_stat_allocations('体力', 5)
        # int(2.5) = 2 → (運動力 2, 健康力 2) → 余り 1 を運動力（先頭）に
        self.assertEqual(result, [('運動力', 3), ('健康力', 2)])
        # 体力 × 10 は余りゼロ
        result = get_stat_allocations('体力', 10)
        self.assertEqual(result, [('運動力', 5), ('健康力', 5)])

    def test_other_category_distribution(self):
        """「その他」（6 stat × 1/6）で余りが運動力に集中することを確認。"""
        # int(10/6) = 1 を 6 stat に → 合計 6 → 余り 4 を運動力に
        result = get_stat_allocations('その他', 10)
        total = sum(v for _, v in result)
        self.assertEqual(total, 10)
        # 運動力（先頭）に余り集中
        self.assertEqual(result[0][0], '運動力')
        self.assertEqual(result[0][1], 5)  # int(10/6)=1 + 余り 4 = 5
        # 残り 5 stat はそれぞれ int(10/6) = 1
        for name, value in result[1:]:
            self.assertEqual(value, 1)

    def test_unmapped_category_returns_empty(self):
        """旧マップカテゴリ（'メンタル' 等）が来た場合は空リストを返す。"""
        result = get_stat_allocations('メンタル', 10)
        self.assertEqual(result, [])

    def test_zero_exp(self):
        """EXP 0 を渡した場合、全 stat 0 加算で合計 0 を返す。"""
        result = get_stat_allocations('その他', 0)
        self.assertEqual(sum(v for _, v in result), 0)
