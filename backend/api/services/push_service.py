import json
import logging
import os

from ..models import Notification

_logger = logging.getLogger(__name__)


def create_notification(player, notif_type, title, body, related_id=None, *, skip_push=False):
    """アプリ内通知を作成し、FCM プッシュを送信する。

    push 送信は transaction.on_commit 経由で実行する。
    これにより:
      - atomic ブロック内の push 失敗がトランザクションをロールバックしない
      - push の HTTP 待ち時間が API レスポンスに乗らない

    【BUG-66】`skip_push=True` の場合、In-app Notification DB row は作成するが
    FCM プッシュ通知は送信しない。ユーザー自身の操作で発火する self-triggered
    イベント（level_up 等）に使用し、ダイアログとプッシュバナーの二重表示や
    dialog dispose 中のプッシュ受信による defunct assertion を回避する。
    通知タブの履歴閲覧は維持されるため、ユーザーは後から確認できる。
    """
    from django.db import transaction as _tx

    notif = Notification.objects.create(
        player=player,
        notif_type=notif_type,
        title=title,
        body=body,
        related_id=related_id,
    )

    # 【BUG-66】skip_push=True なら DB 通知作成のみで push は送らない。
    if skip_push:
        return notif

    # コミット確定後に push — atomic 内から呼ばれても安全
    _player_fcm  = player.fcm_token
    _title       = title
    _body        = body
    _notif_type  = notif_type
    _related_id  = related_id

    def _do_push():
        # 【BUG-101 (2026-06-14)】FCM data payload に notif_type / related_id を載せ、
        # Mobile 側 NotificationDeepLink.resolveRoute で deep link を解決できるようにする。
        # foreground / background / terminated の 3 経路すべて message.data からこの 2 値を読む。
        data = {'notif_type': _notif_type}
        if _related_id is not None:
            data['related_id'] = str(_related_id)
        _send_fcm_push_raw(_player_fcm, _title, _body, data)

    _tx.on_commit(_do_push)
    return notif


def create_localized_notification(
    player, notif_type, message_key, related_id=None, *, skip_push=False, **params,
):
    """【FEAT-517】宛先プレイヤーの言語で文面を組み立ててから通知を作る。

    `create_notification` との違いは **文面を呼び出し側が持たない**こと。
    key と параметр だけ渡し、文面は `api/i18n_messages.py` が持つ。

    ## 文面は「作成時点の言語」で固定される

    Notification model は title / body を **文字列として保存**する。したがって
    ユーザーが後から言語を切り替えても、**過去の通知は当時の言語のまま**残る。

    これは意図した割り切りである:

    - FCM のペイロードは文字列なので、**送信時点で必ず確定させる必要がある**
    - 通知はその時点の出来事を伝えるもので、遡って書き換わる方が不自然
    - key + params を保存して閲覧時に解決する案は、model 変更 (migration) と
      Mobile 側の描画変更を伴う。v1.1 の費用対効果に見合わない

    切替直後に通知一覧が混在言語に見えるが、新しい通知から順に新言語になる。
    """
    from ..i18n_messages import notification_text, resolve_player_locale

    locale = resolve_player_locale(player)
    title, body = notification_text(message_key, locale, **params)
    return create_notification(
        player, notif_type, title, body,
        related_id=related_id, skip_push=skip_push,
    )


def _get_firebase_app():
    """firebase-admin アプリをシングルトンで取得する（未設定時は None を返す）"""
    try:
        import firebase_admin
        from firebase_admin import credentials
        if not firebase_admin._apps:
            service_account_json = os.environ.get('FIREBASE_SERVICE_ACCOUNT_JSON', '')
            if not service_account_json:
                return None
            cred = credentials.Certificate(json.loads(service_account_json))
            firebase_admin.initialize_app(cred)
        return firebase_admin.get_app()
    except Exception as e:
        _logger.warning('Firebase init failed: %s', e)
        return None


def send_fcm_push(player, title: str, body: str, data: dict | None = None) -> None:
    """後方互換ラッパー。直接呼ぶ場合は atomic 外から呼ぶこと。"""
    _send_fcm_push_raw(player.fcm_token if hasattr(player, 'fcm_token') else player, title, body, data)


def _send_fcm_push_raw(fcm_token: str | None, title: str, body: str, data: dict | None = None) -> None:
    """FCM プッシュ通知をモバイル端末に送信する。"""
    if not fcm_token:
        return
    app = _get_firebase_app()
    if app is None:
        return
    try:
        from firebase_admin import messaging
        message = messaging.Message(
            notification=messaging.Notification(title=title, body=body),
            data={k: str(v) for k, v in (data or {}).items()},
            token=fcm_token,
            android=messaging.AndroidConfig(
                notification=messaging.AndroidNotification(
                    channel_id='restack_default',
                    sound='default',
                ),
                priority='high',
            ),
            apns=messaging.APNSConfig(
                payload=messaging.APNSPayload(
                    aps=messaging.Aps(sound='default'),
                ),
            ),
        )
        messaging.send(message, app=app)
    except Exception as e:
        _logger.warning('FCM push failed: %s', e)
