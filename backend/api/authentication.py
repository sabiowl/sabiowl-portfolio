"""
カスタムトークン認証クラス。

DRF 標準の TokenAuthentication を継承し、
トークンに 30 日間の有効期限を設ける。
有効期限切れのトークンは認証時に自動削除される。

FEAT-187: ゲストモード用の GuestTokenAuthentication を追加。
`Authorization: GuestToken <token>` ヘッダーでゲストセッションを認証する。

BUG-147 Phase B-1: ゲストトークンが無効なときの 401 に**機械可読な code**を載せる。
Mobile はこの code を見て「恒久的に無効」と判別できたときだけセッションを
作り直す (401 そのものをトリガにすると FEAT-193 が防いだデータロス事故に戻る)。
"""

from datetime import timedelta

from django.utils import timezone
from rest_framework import authentication
from rest_framework.authentication import TokenAuthentication
from rest_framework.exceptions import AuthenticationFailed

from .services.auth_token import AccountSuspended

# トークン有効期間（日）
TOKEN_EXPIRY_DAYS = 30

# 【BUG-155 (2026-09-11)】`created` を書き戻す間隔。
#
# 🔴 **間引かないと全リクエストが `Token` 行に UPDATE を打つ。**
# ホーム起動時に 10 本以上が並列で飛ぶ設計なので、同じ 1 行への書き込みが
# 競合し、**行ロックの待ちを認証層 (= 全リクエストが通る最ホットパス) に
# 持ち込む**ことになる。
#
# 🔵 1 日粒度なら実質「1 日 1 回だけ 1 行 UPDATE」に収まり、それでいて
# 「最後に使ってから 30 日」は正確に表現できる (最大で 1 日ぶん保守的に
# 短くなるだけ)。
#
# ⚠️ **`TOKEN_EXPIRY_DAYS` と連動させないこと。** 連動させると
# 「30 日の 1/30」のような導出規則を読む人が生まれ、変更時に
# **両方の意味を考えさせられる**。固定値でよい。
TOKEN_REFRESH_THRESHOLD = timedelta(days=1)


def _guest_auth_error(code: str, message: str) -> dict:
    """【BUG-147 Phase B-1 (2026-08-20)】401 body を `error_response()` と同形にする。

    ## なぜ dict を渡すのか

    DRF の `exception_handler` は `exc.detail` が `list` / `dict` のときは
    **それをそのままレスポンス body にする** (文字列のときだけ `{'detail': ...}`
    に包む)。したがって dict を渡すだけで

        {"error": {"code": "...", "message": "..."}}

    が 401 で返り、Mobile の `ApiError.fromResponse()` がそのまま parse できる。
    **カスタム例外ハンドラは不要。**

    ## なぜ code を分けるのか

    Mobile がゲストセッションを作り直してよいのは、サーバが
    **「そんなトークンは無い」と断定した**ときだけである
    (`auth_guest_token_invalid`)。ヘッダ形式不正
    (`auth_guest_token_malformed`) はクライアント側の不具合の可能性があり、
    自動再初期化するとバグを隠す。

    ## 形式を揃える理由

    `authentication.py` は `backend/api/views/` の外なので
    `test_error_response_format.py` のソース走査対象に入らない。それでも
    **Mobile 側の parser は 1 つしかない**ので形式は揃える。
    不変条件は `test_guest_token_auth_error_code.py` が縛る。
    """
    return {'error': {'code': code, 'message': message}}


class ExpiringTokenAuthentication(TokenAuthentication):
    """**最後に使ってから** 30 日で期限切れになるトークン認証。

    有効期限切れのトークンに対しては 401 を返し、
    DB からトークンを削除してクリーンアップする。

    ## 🔴 【BUG-155 (2026-09-11)】これは「アイドル期限」であって「絶対期限」ではない

    以前は `token.created` を**誰も更新していなかった** ——
    発行はすべて `Token.objects.get_or_create(user=user)` で、
    `get_or_create` は既存行の `created` を触らない。結果として
    `created` は**初回ログインの日時で永久に固定**され、
    **毎日使っていても 30 日後に必ず 401 になっていた**。

    v1.1.0 / v1.1.1 のユーザーが、それぞれの初回ログインから 30 日目に
    順次失効していく時限装置になっていた (実際に報告が来た)。

    ## ⚠️ 承知のうえで受け入れている trade-off

    🔴 **スライディング期限は、使われ続けるトークンの寿命を無限に延ばす。**
    漏洩したトークンが使われ続ければ、期限では止まらない。

    それでもこの形を採るのは:

      - **失効させる手段は別にある** —— admin の「認証トークン」から行を
        削除すれば即座に無効化できる
      - **絶対期限の代償が大きすぎる** —— 30 日ごとに全アクティブユーザーを
        ログアウトさせるのは、**継続が資産の習慣化アプリ**として致命的である

    ⚠️ **「期限が効いていない」と見て絶対期限に戻さないこと。** 戻すと
    BUG-155 が再発する。`test_token_sliding_expiry.py` の
    `test_31_days_of_daily_use_still_authenticates` がこれを仕様として
    固定している。
    """

    def authenticate_credentials(self, key):
        model = self.get_model()
        try:
            token = model.objects.select_related('user').get(key=key)
        except model.DoesNotExist:
            raise AuthenticationFailed('無効なトークンです')

        if not token.user.is_active:
            # 🔴 【FEAT-541 (2026-09-06)】ここは **403** でなければならない。
            #
            # 401 (`AuthenticationFailed`) にすると、Mobile の既存 interceptor が
            # **問答無用でトークンを消してログイン画面へ飛ばす** ——
            # ログインし直す → また 401 → …… と続き、
            # **「停止されました」ではなく「ログインし直してください」が延々出る。**
            # 停止画面が表示される隙が無い。
            #
            # 意味論としても 403 が正しい: 401 は「認証できていない」であり、
            # 停止は「**誰かは分かっている、その上で許可しない**」である。
            #
            # ⚠️ `GuestTokenAuthentication` は触らない。ゲストは `User` を
            #    持たない (`GuestSession` → `PlayerProfile` 直結) ので、
            #    止める対象そのものが無い (案 A の割り切り)。
            raise AccountSuspended()

        # 有効期限チェック (最後に使ってからの経過時間)
        token_age = timezone.now() - token.created
        if token_age > timedelta(days=TOKEN_EXPIRY_DAYS):
            token.delete()
            raise AuthenticationFailed(
                'トークンの有効期限が切れています。再度ログインしてください'
            )

        # 【BUG-155】期限を「最後に使った時点」から測り直す (スライディング)。
        #
        # ⚠️ `token.save()` ではなく `filter().update()` を使う:
        #   1. `Token.created` は `auto_now_add=True` である。`save()` 経由は
        #      「挿入時のみ設定」の意味論と混ざって読み手を惑わせる。
        #      `update()` は SQL の UPDATE 1 本で、意図が一目で分かる。
        #   2. **1 クエリで済む。** 認証は全リクエストで通る最ホットパスなので、
        #      ここに余分な往復を足してはならない。
        #
        # ⚠️ 停止チェック (上) より**後**に置くこと。停止済アカウントの
        #    トークンを延命しない。
        if token_age > TOKEN_REFRESH_THRESHOLD:
            model.objects.filter(pk=token.pk).update(created=timezone.now())

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
            raise AuthenticationFailed(_guest_auth_error(
                'auth_guest_token_malformed',
                'ゲストセッションの情報が読み取れませんでした。'
                '少し時間をおいて、もう一度お試しください 🪶',
            ))

        try:
            token = auth_header[1].decode()
        except UnicodeError:
            raise AuthenticationFailed(_guest_auth_error(
                'auth_guest_token_malformed',
                'ゲストセッションの情報が読み取れませんでした。'
                '少し時間をおいて、もう一度お試しください 🪶',
            ))

        # 遅延 import: モデルロード順の循環参照を避ける
        from .models.auth import GuestSession
        try:
            guest_session = GuestSession.objects.select_related(
                'player_profile',
            ).get(token=token)
        except GuestSession.DoesNotExist:
            # 【BUG-147 Phase B-1】**サーバが「そんなトークンは無い」と断定した**
            # 唯一の経路。Mobile はこの code のときだけゲストセッションを
            # 作り直す (api_client.dart)。形式不正と分けているのはそのため。
            raise AuthenticationFailed(_guest_auth_error(
                'auth_guest_token_invalid',
                'ゲストセッションの有効期限が切れました。'
                '再度お試しください 🪶',
            ))

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
