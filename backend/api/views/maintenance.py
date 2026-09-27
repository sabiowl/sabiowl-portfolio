"""【FEAT-463 (2026-06-22)】緊急メンテナンス状態取得 View。
【FEAT-471 (2026-07-02)】MaintenanceConfig 取得を cache 経由に変更。
【FEAT-536 (2026-08-29)】locale 解決を追加。それまで生の日本語を返していた。
"""
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from ..serializers import get_i18n_field
from ..services.maintenance_cache import get_maintenance_config

# 【FEAT-536】英語ロケールで `_en` が空だったときの既定文言。
#
# 🔴 **`mobile/lib/l10n/app_en.arb` の `coreMaintenancePlaceholder*` と
# 同じ文字列にすること。** 揃っていないと、overlay が
# 「仮の英文 → 別の英文」に化ける（FEAT-536 §2.2 が指摘した化けの、
# 日本語版が英語版に変わるだけの状態）。
#
# ⚠️ **2 箇所に同じ英文がある。** テストで縛っていない —— ARB は Flutter 側、
# 本定数は Django 側で、揃っているかを見るには CI をまたぐ機構が要る。
# 割に合わないので `doc/runbook/maintenance_mode.md` に
# 「文言を変えるときは 2 箇所」と書いて残してある（FEAT-536 Pre-mortem #2）。
_EN_FALLBACK = {
    'title': "We're currently performing system maintenance.",
    'body': 'Please wait a moment and try again. 🪶',
}


def _text(config, field: str, locale: str) -> str:
    """`field` を locale に応じて解決する。

    通常の master data は `get_i18n_field` の ja fallback で十分だが、
    🔴 **ここだけは違う**。この行を書くのは **障害対応の最中** であり、
    `_en` が空のまま ON にされる確率が構造的に高い。そして出る先は
    **障害中の唯一の画面** である。

    実際、2026-08-29 の dev 実機検証では **既定値のまま ON にされ**、
    英語端末に日本語のタイトルと本文が出た（FEAT-536 §5 Phase 0）。
    「admin が `_en` を埋め忘れる」ではなく「**そもそも埋める欄が無く、
    既定値のまま出る**」のが現実の姿だった。

    一般論としての一貫性より、**この 1 画面が読めること**を優先する。
    （通常の master data と違い `translate_master_data` で事前に埋めておけない
    —— 文面がその場で決まるため）
    """
    value = get_i18n_field(config, field, locale)
    if locale == 'en' and not (getattr(config, f'{field}_en', '') or '').strip():
        return _EN_FALLBACK[field]
    return value


class MaintenanceStatusView(APIView):
    """緊急メンテナンス状態を返す AllowAny endpoint。

    GET /api/maintenance/

    Mobile が起動時 / overlay の再試行ボタンタップ時に叩く。middleware で
    全 API レスポンス header `X-Maintenance: 1` も付与されるため実質二重防御だが、
    本 endpoint は「明示的に最新状態 (title/body/expires_at) を取得」する用途。

    `Accept-Language` は `I18nMiddleware` が `request.locale` に解決済み。
    Mobile は毎リクエストで送っている（`api_client.dart`）。

    Response:
        {
          "is_enabled": false,
          "title": "...",
          "body": "...",
          "expires_at": "2026-06-22T15:00:00Z" or null
        }
    """
    authentication_classes = []
    permission_classes = [AllowAny]

    # 【BUG-158 (2026-09-12)】throttle を走らせない。
    #
    # 🔴 認証を通らないので `AnonRateThrottle` (IP キー) が適用されていた。
    # **アプリを開くたびに anon バケットを 1 本消費する** (`/health/` と
    # 合わせて 2 本)。旧 anon は 60/hour だったので、起動 30 回で枯れる。
    #
    # ⚠️ **メンテ状態は障害時にこそ取得できなければならない。**
    # 枠が枯れると、admin が明示的に出したメンテ告知が届かなくなり、
    # 代わりに「通信できませんでした」が出る —— 事実と逆の表示になる。
    #
    # 🔵 濫用リスクは低い。読み取り専用で、`MaintenanceConfig` は cache 経由
    # (`services/maintenance_cache.py`) なので通常 DB にすら当たらない。
    # ⚠️ ただし**無制限にするので、Render 側のレート制御に依存する形になる**。
    throttle_classes: list = []

    def get(self, request):
        config = get_maintenance_config()
        if config is None or not config.is_enabled_now():
            return Response({
                'is_enabled': False,
                'title': '',
                'body': '',
                'expires_at': None,
            })
        locale = getattr(request, 'locale', 'ja')
        return Response({
            'is_enabled': True,
            'title': _text(config, 'title', locale),
            'body': _text(config, 'body', locale),
            'expires_at': config.expires_at.isoformat() if config.expires_at else None,
        })
