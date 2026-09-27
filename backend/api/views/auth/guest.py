from rest_framework import status
from rest_framework.authtoken.models import Token
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle  # SEC-08 H-03-new
from rest_framework.views import APIView

from django.conf import settings as django_settings
from django.contrib.auth import get_user_model
from django.db import transaction

from ...models import GuestSession, PlayerProfile
from ...services.auth_token import issue_token
from ...services.exp_service import create_default_stats
from ...services.seed_default import seed_new_user_defaults

User = get_user_model()


def _issue_token(user):
    """【FEAT-541 (2026-09-06)】発行の実体は `services/auth_token.issue_token`。

    ⚠️ ここで `Token.objects.get_or_create` を直接呼ばないこと。
    停止チェックがヘルパーの中にしかなく、
    `test_account_suspension.py` の走査が**ヘルパー外の発行を禁じている**。
    """
    return issue_token(user)


class GuestInitView(APIView):
    """ゲストセッションの初期化（FEAT-187）。

    アプリ起動時にトークンを持たないクライアントが呼ぶ。
    新規 PlayerProfile (user=null) + GuestSession を作成し、
    トークンとプロフィール情報を返す。

    冪等性: 既に GuestSession を持つクライアントは再度呼ばないこと。
    クライアント側で SecureStorage にトークンを保存し、起動時に
    トークンがなければ本 API を呼ぶ仕様（FEAT-188）。
    """

    authentication_classes = []
    permission_classes     = [AllowAny]
    # SEC-08 / H-03-new: ゲストセッション作成の濫用対策（DB 容量浪費 / DoS 防止）。
    # `guest_init` レート（settings.DEFAULT_THROTTLE_RATES）でクライアント IP 単位に絞る。
    # 通常デバイスは初回インストール時にしか叩かないため 5/hour で運用上問題なし。
    throttle_classes       = [ScopedRateThrottle]
    throttle_scope         = 'guest_init'

    @transaction.atomic
    def post(self, request):
        # ── 1. PlayerProfile (user=null) を作成 ──
        player = PlayerProfile.objects.create(
            user=None,
            name='ゲスト',          # 連携時にユーザー入力で上書き
            gender='f',
        )

        # ── 2. CharacterStat 6 種を生成 ──
        create_default_stats(player)

        # ── 3. デフォルトデータ（習慣・ToDo・タイムライン・チケット） ──
        # seed_new_user_defaults() は冪等チェック付き
        seed_new_user_defaults(player)

        # ── 4. GuestSession を作成（token は自動生成） ──
        guest_session = GuestSession.objects.create(player_profile=player)

        return Response({
            'token':          guest_session.token,
            'player_profile': {
                'id':                 player.id,
                'name':               player.name,
                'level':              player.battle.level,
                'current_exp':        player.battle.current_exp,
                'active_character':   None,
            },
        }, status=201)


# FEAT-189: GuestMigrateView は削除。
# ゲスト基盤サーバー化により、連携時は SocialAuthView 内で
# `user` を紐付けるだけで全データが自動的に引き継がれる。
# 名前・キャラの引き継ぎは SocialAuthView の player_name パラメータ +
# オンボーディング画面の即時 PATCH /api/player/ で対応する。


class DevLoginView(APIView):
    """
    POST /api/auth/dev-login/
    開発用ワンタップログインエンドポイント。
    DEBUG=True の場合のみ有効。本番（DEBUG=False）では 403 を返す。
    固定の開発アカウント（dev@sabiowl.local）を取得 or 作成してトークンを返す。

    【BUG-147 (2026-08-20)】`authentication_classes = []` を明示する。
    DEBUG 限定なので実害は無いが、「AllowAny な view は例外なく認証を切る」という
    不変条件を `test_allow_any_views_skip_authentication.py` が縛っているため、
    ここだけ例外にすると規約が曖昧になる。
    """
    authentication_classes = []
    permission_classes = [AllowAny]

    _DEV_EMAIL = 'dev@sabiowl.local'
    _DEV_NAME  = '開発ユーザー'

    def post(self, request):
        # 三重ガード: DEV_LOGIN_ENABLED=true かつ DEBUG=True かつ SQLite 接続のみ動作
        # PostgreSQL（=本番 DB）では絶対に動作しない
        is_debug  = getattr(django_settings, 'DEBUG', False)
        is_sqlite = django_settings.DATABASES['default']['ENGINE'].endswith('sqlite3')
        enabled   = getattr(django_settings, 'DEV_LOGIN_ENABLED', False)
        if not (enabled and is_debug and is_sqlite):
            from django.http import Http404
            raise Http404

        # 開発アカウントを取得 or 新規作成（冪等）
        user, created = User.objects.get_or_create(
            username=self._DEV_EMAIL,
            defaults={'email': self._DEV_EMAIL},
        )
        if created:
            user.set_unusable_password()
            user.save()
            player = PlayerProfile.objects.create(
                user=user,
                name=self._DEV_NAME,
                gender='f',
            )
            create_default_stats(player)

        token_key = _issue_token(user)
        return Response(
            {'token': token_key, 'email': self._DEV_EMAIL},
            status=status.HTTP_200_OK,
        )
