"""Django admin の権限制限 mixin 集。

`admin.py` には `has_add_permission` / `has_change_permission` /
`has_delete_permission` を `return False` で潰す override が **29 個** 散在して
いた (17 admin)。パターンは実質 4 種類しかなく、しかも「なぜ禁止なのか」は
各所のコメントに散っていて一覧できなかった。本モジュールはその 4 パターンを
名前付きの mixin に集約する。

## 使い方 (MRO 注意)

mixin は **必ず `admin.ModelAdmin` より左** に置くこと:

    class FooAdmin(ReadOnlyAdminMixin, admin.ModelAdmin):   # ✅
    class FooAdmin(admin.ModelAdmin, ReadOnlyAdminMixin):   # ❌ 効かない

右に置くと `ModelAdmin` の実装が先に解決され、**mixin が無言で無効化される**
(例外も警告も出ない)。この事故を検知するため
`tests/test_admin_permission_mixins.py` が全 admin の権限マトリクスを assert
している。

## 「なぜ潰すのか」の分類

| mixin | 意図 |
|---|---|
| `NoAddAdminMixin` | 生成経路が Backend / Mobile 側にあり、admin 手動作成は不整合を生む |
| `NoChangeAdminMixin` | 監査ログ / 履歴レコードで、事後改変させたくない |
| `NoDeleteAdminMixin` | OneToOne の state 系。消すと property の get_or_create で空 state が再生成され累計値が飛ぶ |
| `NoBulkDeleteAdminMixin` | 個別削除は必要だが、一覧の一括削除は誤操作の被害が大きすぎる |
| `ReadOnlyAdminMixin` | 上 3 つの合成。閲覧専用 (監査 / 分析用) |
"""


class NoAddAdminMixin:
    """admin からの新規作成を禁止する。

    レコード生成の真実値が Backend の service / Mobile の API 経路にある場合、
    admin での手動作成は関連レコードや冪等性フラグを伴わない不完全な行を作る。
    """

    def has_add_permission(self, request):
        return False


class NoChangeAdminMixin:
    """admin からの編集を禁止する (詳細画面は閲覧できるが save 不可)。

    Django は `has_change_permission=False` のとき一覧の change link を
    「view link」に差し替えるため、閲覧性は保ったまま改変だけを塞げる。
    """

    def has_change_permission(self, request, obj=None):
        return False


class NoDeleteAdminMixin:
    """admin からの削除を禁止する。

    主に `PlayerProfile` と OneToOne な state 系モデル向け。これらは model 側の
    property が `get_or_create` で遅延生成するため、admin で消しても「無かった
    ことになる」のではなく **累計値 (diamonds_total 等) が 0 の新しい行が
    生える**。データ消失が復旧不能な形で起きるので構造的に塞ぐ。
    """

    def has_delete_permission(self, request, obj=None):
        return False


class NoBulkDeleteAdminMixin:
    """一覧画面の「Action: 選択されたものを削除」だけを取り除く。

    個別削除 (詳細画面の削除ボタン / CASCADE 経路) は残す。checkbox の
    全選択ミスで数千行が一度に消える事故だけを防ぐのが目的なので、
    `has_delete_permission` は触らない。
    """

    def get_actions(self, request):
        actions = super().get_actions(request)
        actions.pop('delete_selected', None)
        return actions


class ReadOnlyAdminMixin(NoAddAdminMixin, NoChangeAdminMixin, NoDeleteAdminMixin):
    """閲覧専用 admin。add / change / delete をすべて禁止する。

    監査証跡 (課金領収書) や分析用データ (退会理由) など、
    「見るためだけに admin 登録した」モデル向け。
    """
