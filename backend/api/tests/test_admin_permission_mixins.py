"""【2026-08-07】admin 権限 mixin の契約テスト。

`admin.py` に散在していた `has_*_permission` の `return False` × 29 箇所を
`admin_mixins.py` の 5 mixin に集約した。この移行には **無言で壊れる経路** が
2 つあるので、権限マトリクスをここで固定する。

## 壊れ方 1: MRO の順序ミス

    class FooAdmin(admin.ModelAdmin, ReadOnlyAdminMixin):   # ❌

Python の MRO は左から解決するため、`ModelAdmin` の実装が先に見つかり
**mixin は一切効かない**。例外も警告も出ず、admin 画面に編集ボタンが復活する
だけ。CI で落ちないと誰も気づかない。

## 壊れ方 2: mixin の付け忘れ

class 宣言から mixin 名が消えても Python 的には正常なコード。
「監査用の view-only admin が、いつのまにか編集可能になっていた」は
気づいた時には手遅れ (領収書が書き換えられている) の類の事故。

## このテストが守らないもの

各 admin が「なぜ」その権限なのかの妥当性は守らない (それは設計判断)。
守るのは「意図した権限が実際にそうなっているか」の一点。
権限を意図的に変える場合は本テストの期待値も一緒に更新すること。
"""
from django.contrib import admin as django_admin
from django.contrib.auth import get_user_model
from django.test import RequestFactory, TestCase

from api.admin_mixins import (
    NoAddAdminMixin,
    NoBulkDeleteAdminMixin,
    NoChangeAdminMixin,
    NoDeleteAdminMixin,
    ReadOnlyAdminMixin,
)
from api.models import (
    AccountDeletionFeedback,
    ChallengeParticipation,
    Friendship,
    GachaHistory,
    IAPReceipt,
    MaintenanceConfig,
    Message,
    Notification,
    OwnedCharacter,
    PendingDuplicateReward,
    PlayerBattleState,
    PlayerEconomyState,
    PlayerGachaStatus,
    PlayerSettings,
    PlayerStatsMatrix,
    PlayerStreakState,
    TaskSuggestion,
)

User = get_user_model()


# (model, add 可, change 可, delete 可, 一括削除 action 可)
#
# 最終列について: Django の `ModelAdmin.get_actions` は `delete_selected` を
# `has_delete_permission` で自動フィルタするため、delete 可 = False の行では
# 一括削除も **自動的に** False になる (mixin の効果ではない)。
# `NoBulkDeleteAdminMixin` の効果を実際に検証しているのは
# **delete 可 = True かつ 一括削除 = False** の 4 行 (Friendship / Message /
# Notification / GachaHistory)。ここが True に転じたら mixin が外れた合図。
_PERMISSION_MATRIX = [
    # ── 完全 view-only (監査 / 分析用) ────────────────────────────────
    (IAPReceipt,               False, False, False, False),
    (AccountDeletionFeedback,  False, False, False, False),
    (PendingDuplicateReward,   False, False, False, False),

    # ── OneToOne state 系: 削除だけ禁止 ───────────────────────────────
    # 消すと property の get_or_create で累計値 0 の新しい行が生える。
    (PlayerEconomyState,       True,  True,  False, False),
    (PlayerBattleState,        True,  True,  False, False),
    (PlayerStreakState,        True,  True,  False, False),
    (PlayerSettings,           True,  True,  False, False),
    (PlayerGachaStatus,        True,  True,  False, False),

    # ── 論理削除を強制 ────────────────────────────────────────────────
    (TaskSuggestion,           True,  True,  False, False),

    # ── Backend 生成物: 追加と削除を禁止、編集のみ ────────────────────
    (ChallengeParticipation,   False, True,  False, False),

    # ── pivot ビュー: inline 編集が主目的なので change は許可 ──────────
    (PlayerStatsMatrix,        False, True,  False, False),

    # ── 社交機能: 個別 delete は残し、一括削除だけ塞ぐ ────────────────
    #    (この 4 行が NoBulkDeleteAdminMixin の実質的な検証対象)
    (Friendship,               False, True,  True,  False),
    (Message,                  False, False, True,  False),
    (Notification,             False, False, True,  False),
    (GachaHistory,             False, False, True,  False),

    # ── 譲渡に相当する change のみ禁止 ────────────────────────────────
    (OwnedCharacter,           True,  False, True,  True),
]


class AdminPermissionMatrixTest(TestCase):
    """登録済み admin の権限が意図どおりかを 1 件ずつ確認する。"""

    @classmethod
    def setUpTestData(cls):
        cls.superuser = User.objects.create_superuser(
            username='perm_matrix_admin',
            email='perm_matrix@example.com',
            password='dummy-password-for-test',
        )

    def setUp(self):
        self.request = RequestFactory().get('/admin/')
        self.request.user = self.superuser

    def _admin_for(self, model):
        model_admin = django_admin.site._registry.get(model)
        self.assertIsNotNone(
            model_admin,
            f'{model.__name__} が admin.site に未登録。'
            ' @admin.register が外れていないか確認すること。',
        )
        return model_admin

    def test_permission_matrix(self):
        """superuser でも mixin による禁止が効いていること。

        superuser は Django の permission チェックを素通りするので、
        ここで False が返るなら「mixin が実際に効いている」証拠になる
        (=MRO ミスや付け忘れなら True が返って落ちる)。
        """
        for model, can_add, can_change, can_delete, can_bulk in _PERMISSION_MATRIX:
            with self.subTest(model=model.__name__):
                ma = self._admin_for(model)
                self.assertIs(
                    ma.has_add_permission(self.request), can_add,
                    f'{model.__name__}: add 権限が期待と不一致',
                )
                self.assertIs(
                    ma.has_change_permission(self.request), can_change,
                    f'{model.__name__}: change 権限が期待と不一致',
                )
                self.assertIs(
                    ma.has_delete_permission(self.request), can_delete,
                    f'{model.__name__}: delete 権限が期待と不一致',
                )
                has_bulk = 'delete_selected' in ma.get_actions(self.request)
                self.assertIs(
                    has_bulk, can_bulk,
                    f'{model.__name__}: 一括削除 action の有無が期待と不一致',
                )

    def test_maintenance_config_add_is_singleton_gated(self):
        """MaintenanceConfig の add だけは条件付き (pk=1 が無いときのみ許可)。

        mixin 化していない唯一の add override。ここが `return False` に
        書き換わると、初回セットアップで誰も作れなくなる。
        """
        ma = self._admin_for(MaintenanceConfig)

        MaintenanceConfig.objects.filter(pk=1).delete()
        self.assertTrue(
            ma.has_add_permission(self.request),
            'pk=1 未作成なら add を許可すべき (初回セットアップ経路)',
        )

        MaintenanceConfig.objects.create(pk=1, is_enabled=False, title='t', body='b')
        self.assertFalse(
            ma.has_add_permission(self.request),
            'pk=1 が既にあれば add 禁止 (singleton 制約)',
        )

        # delete は mixin 側で常時禁止
        self.assertFalse(ma.has_delete_permission(self.request))


class AdminMixinMroTest(TestCase):
    """mixin が admin.ModelAdmin より左に置かれていることを構造的に確認する。

    `test_permission_matrix` は結果を見る。こちらは原因側 (MRO 順序) を直接見る。
    片方だけだと「たまたま期待値が一致した」を見逃すため両方置く。
    """

    _MIXINS = (
        NoAddAdminMixin, NoChangeAdminMixin, NoDeleteAdminMixin,
        NoBulkDeleteAdminMixin, ReadOnlyAdminMixin,
    )

    def test_mixins_precede_model_admin_in_mro(self):
        offenders = []
        for model, model_admin in django_admin.site._registry.items():
            mro = type(model_admin).__mro__
            try:
                base_index = mro.index(django_admin.ModelAdmin)
            except ValueError:
                continue
            for mixin in self._MIXINS:
                if mixin in mro and mro.index(mixin) > base_index:
                    offenders.append(
                        f'{type(model_admin).__name__}: {mixin.__name__} が'
                        ' admin.ModelAdmin より後ろにあり無効化されている'
                    )
        self.assertEqual(
            offenders, [],
            'mixin は必ず admin.ModelAdmin より左に置くこと:\n'
            + '\n'.join(offenders),
        )

    def test_read_only_mixin_composes_the_three_bans(self):
        """ReadOnlyAdminMixin が 3 つの禁止 mixin の合成であること。

        将来 ReadOnlyAdminMixin だけ独自実装に書き換えられると、
        NoAddAdminMixin 等への修正が反映されなくなる。
        """
        mro = ReadOnlyAdminMixin.__mro__
        for mixin in (NoAddAdminMixin, NoChangeAdminMixin, NoDeleteAdminMixin):
            self.assertIn(mixin, mro, f'{mixin.__name__} が合成から外れている')
