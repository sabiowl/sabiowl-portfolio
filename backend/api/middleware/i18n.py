"""【FEAT-489 Phase 4】request.locale を確定するカスタム i18n ミドルウェア。

優先順位 (【2026-08-02 hotfix】で 1 と 2 を入れ替えた):
  1. Accept-Language header
  2. request.user.player_profile.settings.preferred_language (認証済)
  3. 'ja' default

## なぜ Accept-Language が先なのか

`preferred_language` は `default='ja'` の非 null field で、「未設定」を表現
できない。したがって旧順序では **認証済ユーザーは常に 1 段目で 'ja' に確定**
し、Accept-Language が構造的に到達不能だった。app_locale.dart が
「PATCH に失敗しても Accept-Language が fallback として効く」と書いていた
契約が成立していなかった (2026-08-02 実機 QA で検出)。

Mobile は毎リクエストで `ServiceL10n.current` = **アプリが今表示している
言語**を Accept-Language に載せる (api_client.dart)。保存済みの設定値より
リクエスト時点のヘッダの方が新しいので、こちらを優先する方が実態に合う。

`preferred_language` は引き続き 2 段目 (ヘッダを送らない旧バージョン /
API 直叩き) と、リクエストが存在しないサーバー起点の配信 (FCM 等) のために
保持する。

全 response に Vary: Accept-Language を付与し、CDN / Mobile cache が
locale 別に保持できるようにする。
"""
from typing import Callable

from django.utils.cache import patch_vary_headers
from django.utils.functional import SimpleLazyObject


class I18nMiddleware:
    """FEAT-489 Phase 4: request.locale を確定する。AuthenticationMiddleware より後に登録必須。"""

    SUPPORTED_LOCALES = ('ja', 'en')
    DEFAULT_LOCALE = 'ja'

    def __init__(self, get_response: Callable):
        self.get_response = get_response

    def __call__(self, request):
        # 【2026-08-02 hotfix】遅延評価する。
        #
        # ミドルウェアが走る時点で `request.user` は Django の
        # AuthenticationMiddleware が解決したもの = **セッション認証の結果**
        # しか入っていない。Mobile は全リクエストが DRF TokenAuthentication で、
        # これは APIView.initialize_request の中で初めて走る。
        # つまり即時評価すると認証済ユーザーでも AnonymousUser に見え、
        # **優先順位 1 (preferred_language) が永久に発火しない**。
        #
        # SimpleLazyObject にすると view が `request.locale` に触れた時点
        # ——DRF 認証の後——で解決される。DRF の Request.user setter は
        # `self._request.user` にも代入するので、そこでは Token 認証済の
        # user が見える。`request.user` 自身が同じ遅延パターンで実装されて
        # いるのと同じ理屈。
        #
        # 消費側 (views/sabi.py, announcements.py, battle/list.py 等) は
        # locale を `== 'en'` の比較にしか使っておらず、遅延プロキシで問題ない。
        request.locale = SimpleLazyObject(lambda: self._resolve_locale(request))
        response = self.get_response(request)
        # 【2026-08-02】代入ではなく追記する。代入だと本 middleware より内側の
        # middleware / view が設定した Vary を捨てる。現在の登録順では
        # GZipMiddleware 等が本 middleware より外側にあり process_response が
        # 後に走るため実害は出ていないが、順序を変えた瞬間に静かに壊れる。
        patch_vary_headers(response, ('Accept-Language',))
        return response

    def _resolve_locale(self, request) -> str:
        # 1. Accept-Language header ('en-US,en;q=0.9,ja;q=0.8' 形式を parse)
        #    Mobile が毎リクエストで「アプリが今表示している言語」を載せる。
        accept = request.META.get('HTTP_ACCEPT_LANGUAGE', '')
        for tag in accept.split(','):
            code = tag.split(';')[0].strip().lower()[:2]
            if code in self.SUPPORTED_LOCALES:
                return code

        # 2. PlayerSettings.preferred_language (認証済 user のみ)
        #    ヘッダを送らないクライアント (旧バージョン / API 直叩き) 向け。
        #
        #    `player.settings` プロパティ (get_or_create) は使わない —— locale の
        #    解決という読み取り操作のために PlayerSettings 行を **INSERT** して
        #    しまい、GET リクエストが書き込みを伴う。ここは 1 SELECT で済ませる。
        #    行が無ければ 3 の default に落ちるだけで実害はない。
        #
        #    【2026-08-04】`request.user` の **None チェックが必須**。
        #    `GuestTokenAuthentication` は `(None, guest_session)` を返す設計なので、
        #    ゲストのリクエストでは `request.user` が **AnonymousUser ではなく None**
        #    になる。`None.is_authenticated` は AttributeError で 500 になる。
        #    ゲストは Accept-Language が付いていれば 1 で確定するため表面化しにくく、
        #    **ヘッダを送らないゲストだけが落ちる**という見つけにくい形だった。
        user = getattr(request, 'user', None)
        if user is not None and user.is_authenticated:
            try:
                from api.models import PlayerSettings
                lang = (
                    PlayerSettings.objects
                    .filter(player__user=user)
                    .values_list('preferred_language', flat=True)
                    .first()
                )
                if lang in self.SUPPORTED_LOCALES:
                    return lang
            except Exception:
                pass  # ゲスト / テーブル未作成 → 次の経路へ

        # 3. Default
        return self.DEFAULT_LOCALE
