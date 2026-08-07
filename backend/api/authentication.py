"""
カスタムトークン認証クラス。

DRF 標準の TokenAuthentication を継承し、
トークンに 30 日間の有効期限を設ける。
有効期限切れのトークンは認証時に自動削除される。

FEAT-187: ゲストモード用の GuestTokenAuthentication を追加。
`Authorization: GuestToken <token>` ヘッダーでゲストセッションを認証する。
"""

from datetime import timedelta

from django.utils import timezone
from rest_framework import authentication
from rest_framework.authentication import TokenAuthentication
from rest_framework.exceptions import AuthenticationFailed

# トークン有効期間（日）
TOKEN_EXPIRY_DAYS = 30


class ExpiringTokenAuthentication(TokenAuthentication):
    """30日で期限切れになるトークン認証。

    有効期限切れのトークンに対しては 401 を返し、
    DB からトークンを削除してクリーンアップする。
    """

    def authenticate_credentials(self, key):
        model = self.get_model()
        try:
            token = model.objects.select_related('user').get(key=key)
        except model.DoesNotExist:
            raise AuthenticationFailed('無効なトークンです')

        if not token.user.is_active:
            raise AuthenticationFailed('ユーザーが無効です')

        # 有効期限チェック
        token_age = timezone.now() - token.created
        if token_age > timedelta(days=TOKEN_EXPIRY_DAYS):
            token.delete()
            raise AuthenticationFailed(
                'トークンの有効期限が切れています。再度ログインしてください'
            )

        return (token.user, token)


class GuestTokenAuthentication(authentication.BaseAuthentication):
    """ゲストトークンによる認証（FEAT-187）。

    リクエストヘッダー `Authorization: GuestToken <token>` をチェックし、
    対応する GuestSession を `request.auth` として返す。

    DRF の TokenAuthentication と異なり、戻り値は `(None, guest_session)` で、
    `request.user` は AnonymousUser のまま、`request.auth` に GuestSession が入る。
    permission_class `IsAuthenticatedOrGuest` と View の `get_player_for_request()`
    ヘルパーがこれを参照する。
    """

    keyword = 'GuestToken'

    def authenticate(self, request):
        auth_header = authentication.get_authorization_header(request).split()
        if not auth_header or auth_header[0].lower() != self.keyword.lower().encode():
            return None
        if len(auth_header) != 2:
            raise AuthenticationFailed('無効なゲストトークン形式です。')

        try:
            token = auth_header[1].decode()
        except UnicodeError:
            raise AuthenticationFailed('無効なゲストトークン形式です。')

        # 遅延 import: モデルロード順の循環参照を避ける
        from .models.auth import GuestSession
        try:
            guest_session = GuestSession.objects.select_related(
                'player_profile',
            ).get(token=token)
        except GuestSession.DoesNotExist:
            raise AuthenticationFailed('ゲストトークンが無効です。')

        # 【FEAT-392 (2026-05-30)】5 分間隔バッチ化で DB write を 88% 削減。
        # arch_review 20260530 §P1-2: 1,000 ゲスト × 100 API call/日 = 100,000 UPDATE/日 →
        # ~12,000 UPDATE/日 に削減し、Render PostgreSQL Free の IOPS 上限ボトルネック化を予防。
        # last_active_at の精度が 5 分粒度に粗化されるが、Sabiowl 内の用途調査で問題なし確認済。
        # Pre-mortem #2 (race): double-save は値が同じ now で無害、v1.1 で select_for_update 検討。
        now = timezone.now()
        if (guest_session.last_active_at is None
                or (now - guest_session.last_active_at).total_seconds() > 300):
            guest_session.last_active_at = now
            guest_session.save(update_fields=['last_active_at'])

        # request.user は AnonymousUser のまま、auth に GuestSession を入れる
        return (None, guest_session)
