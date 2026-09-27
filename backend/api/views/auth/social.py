import logging
from datetime import timedelta

from ...authentication import ExpiringTokenAuthentication  # 【BUG-163】DRF 素の ExpiringTokenAuthentication は停止検査も期限も持たない
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView

from django.contrib.auth import get_user_model
# SEC-08 / H-02-new: SocialAccount.provider_uid の競合（並列リクエスト）を
# IntegrityError として捕捉して既存ユーザー経路に合流させるため import を拡張。
from django.db import IntegrityError, transaction
from django.utils import timezone

from ...models import GuestPromotePending, GuestSession, PlayerProfile, SocialAccount
from ...services.auth_token import issue_token
from ...services.exp_service import create_default_stats
from ...services.seed_default import seed_new_user_defaults
from .._error_helpers import error_response  # 【FEAT-475 Phase 3c】新形式統一

_logger = logging.getLogger(__name__)
User = get_user_model()


def _create_user_with_profile(email, name):
    user = User.objects.create_user(username=email, email=email)
    user.set_unusable_password()
    user.save()
    player = PlayerProfile.objects.create(user=user, name=name or '勇者', gender='f')
    create_default_stats(player)

    # FEAT-179: 新規ユーザー向けデフォルトデータ自動付与
    # （習慣 3 件 / ToDo 2 件 / タイムライン 4 件）
    # 冪等チェック付きなので二重呼び出しは安全。
    seed_new_user_defaults(player)

    return user, player


def _create_user_only(email, name):
    """User だけを作る（PlayerProfile は既存のゲスト用を使うため作らない）。FEAT-189"""
    user = User.objects.create_user(username=email, email=email)
    user.set_unusable_password()
    if name:
        # User.first_name は使わないが、参考までに保存（任意）
        user.first_name = name[:30]
    user.save()
    return user


def _resolve_guest_session(guest_token):
    """ゲストトークンから GuestSession を取得（無効なら None）。FEAT-189"""
    if not guest_token:
        return None
    try:
        return GuestSession.objects.select_related(
            'player_profile',
        ).get(token=guest_token)
    except GuestSession.DoesNotExist:
        return None


class SocialAuthView(APIView):
    """
    POST /api/auth/social/verify/
    Firebase ID トークンを検証し、DRF トークンを返す。

    レスポンスパターン:
      {"status": "ok",       "token": "..."}                              — 既存ユーザー
      {"status": "new_user", "token": "...", "needs_name": true}          — 新規ユーザー
    """
    authentication_classes = []
    permission_classes     = [AllowAny]
    throttle_classes       = [ScopedRateThrottle]
    throttle_scope         = 'social_auth'

    @transaction.atomic
    def post(self, request):
        id_token   = (request.data.get('id_token') or '').strip()
        provider   = (request.data.get('provider') or '').strip()
        # FEAT-189: ゲスト時のみ送られる
        guest_token  = (request.data.get('guest_token') or '').strip()
        # FEAT-189: ゲスト時のオンボーディングで入力された名前（オプション）
        player_name_input = (request.data.get('player_name') or '').strip()

        if not id_token or provider not in ('google', 'apple'):
            return error_response(
                       code='social_verify_missing_params',
                       message='id_token と provider (google|apple) は必須です',
                       status=400,
                   )

        # ── Firebase ID トークンを検証 ──────────────────────────────
        try:
            import firebase_admin.auth as _fb_auth
            decoded = _fb_auth.verify_id_token(id_token)
        except Exception as exc:
            _logger.warning('Firebase token verification failed: %s', exc)
            # BUG-29: 401 は DRF 認証失敗専用。Firebase 検証エラーで 401 を返すと
            # Dio インターセプターがセッション失効と誤判定して強制ログアウトに
            # 飛ばされるため 400（Bad Request）に変更する。
            return error_response(
                       code='social_verify_firebase_failed',
                       message='Firebase トークンの検証に失敗しました',
                       status=400,
                   )

        uid            = decoded['uid']
        email          = decoded.get('email', '')
        email_verified = decoded.get('email_verified', False)
        name           = decoded.get('name', '')

        # ── ゲストセッション取得（あれば）──────────────────────────
        guest_session = _resolve_guest_session(guest_token)

        # ── 既存 SocialAccount を検索 ──────────────────────────────
        existing_sa = SocialAccount.objects.select_related('user').filter(provider_uid=uid).first()

        # ────────────────────────────────────────────────────────────
        # FEAT-189 Case A: ゲスト + 既存ユーザー衝突
        # → 409 + merge_token で「確認ダイアログ」を Flutter に促す
        # ────────────────────────────────────────────────────────────
        if existing_sa and guest_session:
            # SEC-08 / H-01-new: GuestPromotePending.guest_session は OneToOneField のため、
            # 同一 guest_session に既存の pending があると create() で IntegrityError → 500 になる。
            # 確認ダイアログを閉じずに再試行する経路で発生していたため、
            # update_or_create で target_user と expires_at を上書きして 409 を返す。
            #
            # 副作用: 既存 pending の `token` は維持される（defaults で上書きしないため）。
            # Flutter が古い merge_token をキャッシュしていた場合は同じ token で再 promote-confirm が可能。
            # `expires_at` のみ再生成して期限切れ 410 を防ぐ。
            pending, _created = GuestPromotePending.objects.update_or_create(
                guest_session=guest_session,
                defaults={
                    'target_user': existing_sa.user,
                    # 既存ユーザー側の TTL を再起算（衝突確認ダイアログ表示後 10 分以内に確定する想定）
                    'expires_at':  timezone.now() + timedelta(minutes=10),
                },
            )
            try:
                existing_user_name = existing_sa.user.player_profile.name
            except PlayerProfile.DoesNotExist:
                existing_user_name = None
            return Response({
                'status':              'conflict_existing_user',
                'merge_token':         pending.token,
                'existing_user_name':  existing_user_name,
                'existing_provider':   provider,
            }, status=409)

        # ────────────────────────────────────────────────────────────
        # FEAT-189 Case B: ゲスト昇格（衝突なし）
        # → ゲスト PlayerProfile に user を紐付け、SocialAccount 作成
        # ────────────────────────────────────────────────────────────
        if guest_session and not existing_sa:
            player = guest_session.player_profile

            # 未検証メールは uid ベースのダミーアドレスを使用
            effective_email = email if email_verified else (
                f'{uid}@social.sabiowl' if not email else f'{uid}@social.{provider}.sabiowl'
            )

            # SEC-08 / H-02-new + 【BUG-67】: 並列の新規作成で SocialAccount.provider_uid
            # または User.username が競合した場合は IntegrityError → 既存ユーザー経路に合流する。
            # 入れ子の `with transaction.atomic():` で savepoint を切ることで、外側の
            # `@transaction.atomic` トランザクションが aborted 状態にならないよう保護する。
            # （savepoint なしで catch すると後続クエリが InFailedSqlTransaction で 500 になる。
            #  Django 公式が明示的に警告するアンチパターン:
            #  https://docs.djangoproject.com/en/4.2/topics/db/transactions/#django.db.transaction.atomic）
            try:
                with transaction.atomic():
                    user = _create_user_only(effective_email, name)
                    player.user = user
                    # 名前の引き継ぎ（既定値の場合のみ上書き）
                    update_fields = ['user']
                    if player_name_input and player.name in ('', 'ゲスト', '勇者'):
                        player.name = player_name_input[:32]
                        update_fields.append('name')
                    player.save(update_fields=update_fields)

                    SocialAccount.objects.create(
                        user=user,
                        provider=provider,
                        provider_uid=uid,
                        # 【FEAT-289】Apple 2 回目以降サインインで email='' のとき
                        # effective_email (uid ベースのダミー) を fallback として使う。
                        # 空文字 SA を作って UI が「-」表示になるのを防ぐ。
                        email=email or effective_email,
                    )
                # 【BUG-67】savepoint 確定後の副作用処理。GuestSession 削除と
                # Token 発行は savepoint 外でも問題なし（失敗しても致命的ではない）。
                guest_session.delete()
                token_key = issue_token(user)
                return Response({'status': 'ok', 'token': token_key})
            except IntegrityError:
                # 【BUG-67】savepoint がロールバックされ、外側のトランザクションは
                # 生きている → 以下の SocialAccount 検索クエリが正常実行される。
                # 並列リクエストが先に SocialAccount を作成 or username 衝突した場合の
                # 既存ユーザー経路への合流。
                existing_sa = SocialAccount.objects.select_related('user').filter(provider_uid=uid).first()
                if not existing_sa:
                    _logger.error(
                        'SocialAuth Case B IntegrityError but no existing SA for uid=%s',
                        uid,
                    )
                    return error_response(
                        code='social_auth_conflict',
                        message='認証処理が競合しました。少し時間をおいて、もう一度お試しください 🪶',
                        status=409,
                    )
                token_key = issue_token(existing_sa.user)
                return Response({'status': 'ok', 'token': token_key})

        # ────────────────────────────────────────────────────────────
        # 既存フロー: ゲストセッションなし
        # ────────────────────────────────────────────────────────────
        # ── Case 1: 既存の SocialAccount → トークン発行 ───────────
        if existing_sa:
            token_key = issue_token(existing_sa.user)
            return Response({'status': 'ok', 'token': token_key})

        # ── Case 2: 新規ユーザー作成 ───────────────────────────────
        if email and not email_verified:
            _logger.warning(
                'SocialAuth: unverified email provider=%s uid=%s, falling back to dummy address',
                provider, uid,
            )
        effective_email = email if email_verified else (
            f'{uid}@social.sabiowl' if not email else f'{uid}@social.{provider}.sabiowl'
        )

        # SEC-08 / H-02-new + 【BUG-67】: 並列の新規作成で SocialAccount.provider_uid
        # または User.username が競合した場合は IntegrityError → 既存ユーザー経路に合流する。
        # 入れ子の `with transaction.atomic():` で savepoint を切ることで、外側の
        # `@transaction.atomic` トランザクションが aborted 状態にならないよう保護する。
        # （Case B と同じパターン。savepoint なしで catch すると後続クエリが
        #  InFailedSqlTransaction で 500 になる Django 公式の警告アンチパターン）
        try:
            with transaction.atomic():
                user, _ = _create_user_with_profile(effective_email, name)
                SocialAccount.objects.create(
                    user=user,
                    provider=provider,
                    provider_uid=uid,
                    # 【FEAT-289】Apple 2 回目以降サインインで email='' のとき
                    # effective_email (uid ベースのダミー) を fallback として使う。
                    email=email or effective_email,
                )
            # 【BUG-67】savepoint 確定後に Token 発行（失敗しても致命的ではない部分は外で実行）
            token_key = issue_token(user)
            return Response(
                {'status': 'new_user', 'token': token_key, 'needs_name': True},
                status=201,
            )
        except IntegrityError:
            # 【BUG-67】savepoint がロールバックされ、外側のトランザクションは生きている。
            # ── 並列救済: 既に同 uid で先行作成済み（H-02-new）────────────────
            existing_sa = SocialAccount.objects.select_related('user').filter(provider_uid=uid).first()
            if existing_sa:
                token_key = issue_token(existing_sa.user)
                return Response({'status': 'ok', 'token': token_key})

            # ── 【BUG-70】email 衝突時の SocialAccount rebind ─────────────────
            # User.username=email の UNIQUE 違反による IntegrityError。同 email の
            # 既存 User が存在する。Firebase 検証済み (email_verified=True) なら
            # 「同 email = 同人物」と扱い、既存 User の同 provider SA を新 uid に
            # rebind して PlayerProfile / 習慣 / タイムライン等の関連データを保護する。
            #
            # 想定シナリオ:
            #   - OAuth プロバイダー側で uid が変わる (アカウント復元 / デバイス変更等)
            #   - 過去の uid 不整合や migration 0073 で消えなかった stale SA の救済
            #
            # セキュリティ:
            #   - email_verified=True を必須 (なりすまし防止、Firebase の検証に委譲)
            #   - 同 provider の SA がある場合のみ rebind (別 provider 経由の乗っ取り防止)
            if email_verified and email:
                existing_user = User.objects.filter(email=email).first()
                if existing_user:
                    existing_user_sa = SocialAccount.objects.filter(
                        user=existing_user,
                        provider=provider,
                    ).first()
                    if existing_user_sa:
                        existing_user_sa.provider_uid = uid
                        # 【FEAT-289】email が空文字なら既存値を保持する。
                        # Apple Sign in は初回ログインしか email を返さない仕様のため、
                        # 2 回目以降の rebind で `email=''` で上書きすると初回保存した
                        # relay アドレスが消えて UI の表示が空欄になる事故が起きる。
                        update_fields = ['provider_uid']
                        if email:
                            existing_user_sa.email = email
                            update_fields.append('email')
                        existing_user_sa.save(update_fields=update_fields)
                        _logger.info(
                            'BUG-70 rebind: provider=%s user_id=%s new uid=%s',
                            provider, existing_user.id, uid,
                        )
                        token_key = issue_token(existing_user)
                        return Response({'status': 'ok', 'token': token_key})

            _logger.error(
                'SocialAuth Case 2 IntegrityError but no existing SA for uid=%s',
                uid,
            )
            return error_response(
                code='social_auth_conflict',
                message='認証処理が競合しました。少し時間をおいて、もう一度お試しください 🪶',
                status=409,
            )


class SocialAccountListView(APIView):
    """
    GET /api/auth/social/accounts/
    現在のユーザーの連携済みアカウント情報を返す。

    レスポンス:
      {
        "google": {"is_linked": bool, "email": str|null},
        "apple":  {"is_linked": bool, "email": str|null}
      }
    """
    authentication_classes = [ExpiringTokenAuthentication]
    permission_classes     = [IsAuthenticated]

    def get(self, request):
        social_accounts = list(SocialAccount.objects.filter(user=request.user))
        accounts_by_provider = {sa.provider: sa for sa in social_accounts}

        def _entry(provider):
            sa = accounts_by_provider.get(provider)
            return {
                'is_linked': sa is not None,
                'email':     (sa.email or None) if sa else None,
            }

        # FEAT-178: メール連携は廃止。レスポンスは google / apple のみ。
        return Response({
            'google': _entry('google'),
            'apple':  _entry('apple'),
        })


class SocialLinkView(APIView):
    """
    POST /api/auth/social/link/
    Firebase ID トークンを検証し、現在のアカウントにソーシャルアカウントを紐付ける。

    レスポンス:
      {"status": "linked"}          — 連携成功
      {"status": "already_linked"}  — 同一ユーザーに既に同プロバイダ連携済み
      {"error": "...", "code": "already_linked_other_provider", "current_provider": "..."} 409
                                      — 別プロバイダで既に連携済み（FEAT-178: 1 ユーザー 1 プロバイダ制約）
      {"error": "..."} 400/401/409  — その他のエラー
    """
    authentication_classes = [ExpiringTokenAuthentication]
    permission_classes     = [IsAuthenticated]

    def post(self, request):
        id_token = (request.data.get('id_token') or '').strip()
        provider = (request.data.get('provider') or '').strip()

        if not id_token or provider not in ('google', 'apple'):
            return error_response(
                       code='social_verify_missing_params',
                       message='id_token と provider (google|apple) は必須です',
                       status=400,
                   )

        # FEAT-178: 1 ユーザー 1 プロバイダ制約。
        # 既に別プロバイダで連携済みの場合は 409 で拒否する。
        # アカウント切り替えは「アカウント削除 → 別アカウントで新規サインイン」の経路に限定。
        existing_link = SocialAccount.objects.filter(user=request.user).first()
        if existing_link and existing_link.provider != provider:
            current_label = 'Google' if existing_link.provider == 'google' else 'Apple'
            return Response(
                {
                    'error': {
                        'code': 'social_link_already_linked',
                        'message': (
                            f'既に別のアカウント（{current_label}）と連携済みです。'
                            'アカウントを切り替えるには、現在のデータを削除してから'
                            '新しいアカウントでサインインしてください 🪶'
                        ),
                    },
                    'code': 'already_linked_other_provider',
                    'current_provider': existing_link.provider,
                },
                status=409,
            )

        try:
            import firebase_admin.auth as _fb_auth
            decoded = _fb_auth.verify_id_token(id_token)
        except Exception as exc:
            _logger.warning('Firebase token verification failed in link: %s', exc)
            # BUG-29: 401 は DRF 認証失敗専用。Firebase 検証エラーで 401 を返すと
            # Dio インターセプターがセッション失効と誤判定して強制ログアウトに
            # 飛ばされるため 400（Bad Request）に変更する。
            return error_response(
                code='social_link_firebase_verify_failed',
                message='Firebase トークンの検証に失敗しました 🪶',
                status=400,
            )

        uid            = decoded['uid']
        email          = decoded.get('email', '')
        email_verified = decoded.get('email_verified', False)
        if email and not email_verified:
            _logger.warning(
                'SocialLink: unverified email provider=%s uid=%s',
                provider, uid,
            )

        # 既に他のユーザーに連携されているか確認
        existing = SocialAccount.objects.filter(
            provider_uid=uid
        ).select_related('user').first()
        if existing:
            if existing.user == request.user:
                return Response({'status': 'already_linked'})
            return error_response(
                       code='social_link_already_linked',
                       message='このアカウントは別の Sabiowl アカウントに連携されています',
                       status=409,
                   )

        # 【FEAT-289】Apple 2 回目以降サインインで email='' のとき、
        # uid ベースのダミーアドレスを fallback として保存。
        # 空文字 SA を作って UI が「-」表示になるのを防ぐ。
        effective_email = email if email else (
            f'{uid}@social.sabiowl' if not email else f'{uid}@social.{provider}.sabiowl'
        )
        SocialAccount.objects.create(
            user=request.user,
            provider=provider,
            provider_uid=uid,
            email=email or effective_email,
        )
        return Response({'status': 'linked'})


class SocialPromoteConfirmView(APIView):
    """ゲスト → 既存ユーザー衝突時の確認後に呼ばれる API（FEAT-189）。

    Flutter で「ゲストデータを破棄して既存アカウントに切り替えますか?」の
    ダイアログで OK が押された後、merge_token を送信して実際の処理を行う。

    処理内容:
      1. ゲスト PlayerProfile + その全データ（CASCADE で habits/timeline/quest 等）削除
      2. GuestSession 削除（CASCADE）
      3. GuestPromotePending 削除
      4. 既存ユーザーの DRF トークンを発行
    """

    authentication_classes = []
    permission_classes     = [AllowAny]
    throttle_classes       = [ScopedRateThrottle]
    throttle_scope         = 'social_auth'

    @transaction.atomic
    def post(self, request):
        merge_token = (request.data.get('merge_token') or '').strip()
        if not merge_token:
            return error_response(code='social_promote_missing_merge_token', message='マージトークンをご確認ください 🪶')

        try:
            pending = GuestPromotePending.objects.select_related(
                'guest_session__player_profile',
                'target_user',
            ).get(token=merge_token)
        except GuestPromotePending.DoesNotExist:
            return error_response(code='social_promote_invalid_merge_token', message='マージトークンが無効です 🪶', status=404)

        if pending.is_expired:
            pending.delete()
            return error_response(code='social_promote_expired_merge_token', message='マージトークンの有効期限が切れています 🪶', status=410)

        # ── ゲストデータの破棄（PlayerProfile を消せば CASCADE で全部消える） ──
        target_user = pending.target_user
        guest_session = pending.guest_session
        guest_player  = guest_session.player_profile
        guest_player.delete()
        # guest_session も CASCADE で削除される
        # pending も CASCADE で削除される

        # ── 既存ユーザーの認証トークン発行 ──
        token_key = issue_token(target_user)

        return Response({
            'status': 'ok',
            'token':  token_key,
        })


class SocialUnlinkView(APIView):
    """【BUG-129 (2026-06-14)】社会的アカウント連携の解除 (誤連携救済)。

    POST /api/auth/social/unlink/
    認証済みユーザー (linked account) の社会的連携を解除し、PlayerProfile を
    ゲストモードに戻す。データ (Habit / Timeline / GachaStatus / OwnedCharacter 等)
    は保持され、新しい GuestSession + ゲストトークンを発行して返す。

    ユーザーは返却されたゲストトークンで一時的にゲストとしてアプリを使用し、
    正しいアカウントで再連携 (Google/Apple サインイン) することで新規昇格として
    別アカウントに紐付け直す。

    【Pre-mortem】
      S1 並列リクエストで二重実行 → select_for_update で User 行ロック
      S2 player.user=None より先に user.delete() → CASCADE で PlayerProfile 喪失
         → 必ず detach (user=None + save) を先に実行
      S3 transaction 内で例外発生 → atomic でロールバック、データ整合性維持
      S4 ゲストトークン発行成功後 Mobile 保存前にクラッシュ → ユーザー row は
         消えており、保存未完了だと旧データへ恒久アクセス不能 (許容、稀)
      S5 Firebase Auth 残留 → best-effort 削除 (account_delete と同パターン)、
         失敗しても Sabiowl 側解除は完了

    レスポンス: {token: <guest_token>, player_profile_id: <id>}
    エラー: 401 (認証なし)、404 (PlayerProfile 不在、運用ミス)
    """
    authentication_classes = [ExpiringTokenAuthentication]
    permission_classes     = [IsAuthenticated]

    def post(self, request):
        with transaction.atomic():
            # User を select_for_update でロック (Pre-mortem S1)
            user = User.objects.select_for_update().get(pk=request.user.pk)
            try:
                player = user.player_profile
            except PlayerProfile.DoesNotExist:
                return error_response(
                           code='player_profile_not_found',
                           message='プロフィールが見つかりません 🪶',
                           status=404,
                       )

            # 【Pre-mortem S5】Firebase Auth uid を削除前に控える
            firebase_uids = list(
                SocialAccount.objects.filter(user=user)
                .values_list('provider_uid', flat=True)
            )

            # 【Pre-mortem S2】player.user=None を user.delete() より先に実行
            # (順序逆だと User CASCADE で PlayerProfile も消える致命バグ)
            player.user = None
            player.save(update_fields=['user'])

            # 新 GuestSession を発行 (token は GuestSession._generate_guest_token で自動生成)
            guest_session = GuestSession.objects.create(player_profile=player)

            # User を削除 (CASCADE: SocialAccount, Token を連鎖削除)
            user.delete()

        # 【Pre-mortem S5】Firebase Auth ユーザー削除 (best-effort、PlayerProfileView.delete
        # の _delete_firebase_users と同パターン)。インポートは局所化。
        if firebase_uids:
            try:
                from ..player import _delete_firebase_users
                _delete_firebase_users(firebase_uids)
            except Exception as exc:
                _logger.warning(
                    'Firebase deletion helper raised during unlink for player_%s: %s',
                    player.id, exc,
                )

        return Response({
            'token':             guest_session.token,
            'player_profile_id': player.id,
        })
