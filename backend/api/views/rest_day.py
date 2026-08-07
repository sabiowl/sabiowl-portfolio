"""【FEAT-424 (2026-06-11)】休息の果実 + 休息日機能の廃止 (Phase 1)。

旧 `RestDayView` / `RestDayBuyFruitView` の実体は撤去し、410 Gone を返す
deprecation スタブに置き換えた。

- `PlayerProfile.rest_fruits` フィールドと `RestDay` model/table は
  Phase 2 (v1.2+) で management command 経由で cleanup する設計のため、
  本 Phase 1 では削除しない (CLAUDE.md「破壊的データマイグレーション禁止」準拠)。
- `urls.py` の `/rest-day/` `/rest-day/buy-fruit/` ルートは deprecation 期間
  維持のため、本ファイルのスタブ View を引き続き参照する。

【FEAT-475 Phase 4 (2026-08-04)】旧形式 `{'error': '<文言>'}` から
`error_response()` へ移行した。

FEAT-515 Phase 1 では「廃止スタブなので移行の価値なし」として
ガードテストの allowlist に入れていたが、**Phase 4 (Flutter の旧形式 parser 削除)
の前提が「旧形式の生成側がゼロ」** なので、ここだけ残すと parser を消せない。
移行コストは 4 行なので、allowlist を残すより移行してしまう方が安い。
"""

from rest_framework.views import APIView

from ..permissions import IsAuthenticatedOrGuest  # FEAT-187
from ._error_helpers import error_response  # 【FEAT-475 Phase 4】新形式へ統一
from .mixins import PlayerMixin


class RestDayView(PlayerMixin, APIView):
    """【FEAT-424】廃止済み。常に 410 Gone を返す。"""

    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        return error_response(
            code='rest_day_feature_removed',
            message='休息日機能は廃止されました 🪶',
            status=410,
        )

    def post(self, request):
        return error_response(
            code='rest_day_feature_removed',
            message='休息日機能は廃止されました 🪶',
            status=410,
        )

    def delete(self, request):
        return error_response(
            code='rest_day_feature_removed',
            message='休息日機能は廃止されました 🪶',
            status=410,
        )


class RestDayBuyFruitView(PlayerMixin, APIView):
    """【FEAT-424】廃止済み。常に 410 Gone を返す。"""

    permission_classes = [IsAuthenticatedOrGuest]

    def post(self, request):
        return error_response(
            code='rest_fruit_feature_removed',
            message='休息の果実は廃止されました 🪶',
            status=410,
        )
