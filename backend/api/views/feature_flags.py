"""【FEAT-477 (2026-07-03)】Mobile 向け Feature Flag 一覧 API。

GET /api/feature-flags/ で django-waffle の Switch / Sample / Flag を
{flags: {name: bool}} 形式で返す。

flag 命名規約: <domain>_<action>_<state>
  例: iap_pack_120_enabled / battle_ui_v2_enabled / challenge_beta_active

waffle の 3 種類:
  Switch  — admin で ON/OFF (全ユーザー共通)
  Sample  — 確率ベース (random %)
  Flag    — 条件付き (認証ユーザー / group / % など)

Mobile クライアントは FeatureFlagService.isEnabled(flagName) 経由で参照し、
未定義 flag は false (機能 OFF) にフォールバックする (Pre-mortem S2 対策)。
DB 障害時は {} を返して Mobile 側を全 flag=False にフォールバックさせる (S4 対策)。
"""
from rest_framework.response import Response
from rest_framework.views import APIView

from ..permissions import IsAuthenticatedOrGuest


class FeatureFlagsView(APIView):
    """GET /api/feature-flags/ — flag 一覧返却。

    waffle.Switch / Sample / Flag を全件取得し、{name: bool} 形式で返す。
    Switch: active フィールド直参照。
    Sample: sample.is_active() (内部で random)。
    Flag:   flag.is_active(request) (user / group / % などの複合条件)。
    """

    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        try:
            from waffle.models import Flag, Sample, Switch

            flags: dict[str, bool] = {}

            for sw in Switch.objects.all():
                flags[sw.name] = sw.active

            for sa in Sample.objects.all():
                flags[sa.name] = sa.is_active()

            for fl in Flag.objects.all():
                flags[fl.name] = bool(fl.is_active(request))

        except Exception:
            flags = {}

        return Response({'flags': flags})
