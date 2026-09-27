"""【FEAT-543 (2026-09-23)】バージョンアップ告知の状態取得 View。

`MaintenanceStatusView` (FEAT-463) をそのまま写している。
"""
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from ..serializers import get_i18n_field
from ..models.app_update import EN_FALLBACK
from ..services.app_update_cache import get_app_update_config

# 【FEAT-536 の教訓】英語欄が空のまま ON にされたときの既定文。
#
# 🔴 **実際に起きている。** FEAT-536 §5 の dev 実機検証で
# 「`_en` が空のまま ON にされ、英語端末に日本語のタイトルと本文が出た」。
# 「admin が埋め忘れる」ではなく「**そもそも埋める欄が無く、既定値のまま出る**」
# のが現実の姿だった。
#
# 🔴 【FEAT-544 (2026-09-23)】**model の定数を import する。**
#
# FEAT-536 は「2 箇所に同じ英文がある」ことを申し送り事項として残していた
# (`doc/runbook/maintenance_mode.md` に「文言を変えるときは 2 箇所」と書く運用)。
# ここでは **model 側の `EN_FALLBACK` を単一の真実値**にして、
# 構造的に食い違わないようにした。
# 🔵 一致は `test_app_update_notice.py` が assert している。
_EN_FALLBACK = EN_FALLBACK


def _text(config, field: str, locale: str) -> str:
    """`field` を locale に応じて解決する。

    通常の master data は `get_i18n_field` の ja fallback で十分だが、
    🔴 **ここは違う**。埋め忘れたまま ON にされる確率が構造的に高く、
    出る先は**全画面を覆う告知**である。日本語が英語端末に出るより、
    汎用の英文が出るほうがましである。
    """
    value = get_i18n_field(config, field, locale)
    if locale == 'en' and not (getattr(config, f'{field}_en', '') or '').strip():
        return _EN_FALLBACK[field]
    return value


class AppUpdateStatusView(APIView):
    """バージョンアップ告知の状態を返す AllowAny endpoint。

    GET /api/app-update/

    Mobile が**起動時に 1 回だけ**叩く。

    Response:
        {
          "is_enabled": true,
          "latest_version": "1.1.4",
          "min_supported_version": "",
          "title": "...",
          "body": "...",
          "mandatory_title": "...",
          "mandatory_body": "..."
        }

    ## ⛔ `X-App-Update` ヘッダーは付けない

    メンテナンスは全レスポンスにヘッダーを付けて即座に割り込むが、
    **更新告知はそうしない**。更新は「今すぐ止める必要がある事象」ではなく、
    毎レスポンスに判定を載せると**メンテ告知で踏んだ誤発火の系統**を
    増やすだけである。起動時に 1 回聞けば足りる。

    ## 🔴 判定はアプリの中で行う

    サーバは各ユーザーがどの版を使っているかを知らない
    (`api_client.dart` が送るのは `Accept-Language` と `Authorization` だけ)。
    ここが返すのは**しきい値と文面だけ**で、比較はアプリがする。
    """
    # 【BUG-147】認証を一切走らせない。
    authentication_classes: list = []
    permission_classes = [AllowAny]

    # 🔴 【BUG-158 (2026-09-12)】throttle を走らせない。
    #
    # 認証を通らないので `AnonRateThrottle` (IP キー) が適用され、
    # **アプリを開くたびに anon の枠を消費する**。枠が枯れると
    # **告知が届かず、代わりに「通信できませんでした」が出る** ——
    # 告知したいときに限って届かない、という形になる。
    #
    # 🔵 濫用リスクは低い。読み取り専用で、cache 経由なので通常 DB にすら当たらない。
    throttle_classes: list = []

    def get(self, request):
        config = get_app_update_config()
        if config is None or not config.is_enabled:
            # ⚠️ しきい値も空で返す。アプリ側は `is_enabled` だけで打ち切るが、
            #    万一そこを読み違えても比較で「更新なし」に倒れる形にしておく。
            return Response({
                'is_enabled': False,
                'latest_version': '',
                'min_supported_version': '',
                'title': '',
                'body': '',
                'mandatory_title': '',
                'mandatory_body': '',
            })
        locale = getattr(request, 'locale', 'ja')
        return Response({
            'is_enabled': True,
            'latest_version': config.latest_version or '',
            'min_supported_version': config.min_supported_version or '',
            'title': _text(config, 'title', locale),
            'body': _text(config, 'body', locale),
            # 【FEAT-544】必須更新の文面。
            # 🔵 旧アプリ (v1.1.2 以前) は**未知のキーを無視する**ので、
            #    Backend を先に出しても壊れない。
            'mandatory_title': _text(config, 'mandatory_title', locale),
            'mandatory_body': _text(config, 'mandatory_body', locale),
        })
