import logging

from django.apps import AppConfig

_logger = logging.getLogger(__name__)


class ApiConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'api'
    verbose_name = 'Sabiowl API'

    def ready(self):
        """BUG-29: Django 起動時に Firebase Admin を初期化する。

        旧実装は push_service._get_firebase_app() がプッシュ通知送信時にしか
        呼ばれず、Render コールドスタート後の初回 Google 連携リクエストで
        firebase_admin の default app が未初期化のまま verify_id_token が呼ばれ、
        ValueError → 401 → Dio が DRF セッション失効と誤判定 → 強制ログアウト
        という連鎖が発生していた。
        FIREBASE_SERVICE_ACCOUNT_JSON 未設定のローカル開発環境では skip。

        BUG-31: 初期化の成否を起動ログに残し、Render の env 漏れを即検知できるようにする。
        """
        try:
            from .services.push_service import _get_firebase_app
            app = _get_firebase_app()
            if app is None:
                _logger.warning(
                    'Firebase Admin SDK が初期化されませんでした。'
                    'FIREBASE_SERVICE_ACCOUNT_JSON が未設定の可能性があります。'
                    'Google / Apple 認証は動作しません。'
                )
            else:
                _logger.info('Firebase Admin SDK の初期化に成功しました。')
        except Exception as exc:
            _logger.error('Firebase Admin SDK の初期化中に例外が発生しました: %s', exc)

        # 【新規 (2026-06-26)】SabiMessage post_save / post_delete signal の登録。
        # admin で セリフを編集・削除した瞬間に sabi_loader.py の Django cache
        # を invalidate し、次の GET /api/sabi/message/ で最新値を即時反映する。
        from . import signals  # noqa: F401 (import で side-effect 登録)
