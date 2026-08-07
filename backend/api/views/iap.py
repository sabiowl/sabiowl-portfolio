"""【FEAT-436 Phase 2 (2026-06-17)】RevenueCat webhook 受信 View。

POST /api/iap/webhook/ で RevenueCat → Backend の購入イベントを受信し、
PlayerProfile.diamonds を加算する。

【認証】
RevenueCat ダッシュボードで設定する `Authorization` ヘッダー値を環境変数
`REVENUECAT_WEBHOOK_AUTH` と照合 (DRF 認証クラスではなく view 内検証)。
未設定 / 不一致は 401 で拒否。

【冪等性】
IAPReceipt.event_id に unique 制約。同一 event を 2 回受信した場合、
2 回目は IntegrityError catch → 200 (skipped) で返却。

【RevenueCat 公式 webhook 仕様】
https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields
"""
from datetime import datetime, timezone as _tz
import hmac  # 【2026-08-05】webhook シークレットの定数時間比較
import logging

from django.conf import settings
from django.db import IntegrityError, transaction
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from ..constants import IAP_PRODUCTS
from ..models import IAPReceipt, PlayerProfile
from ..services.diamond_service import award_iap_diamonds
from ._error_helpers import error_response  # 【FEAT-475 Phase 3a】新形式統一

_logger = logging.getLogger(__name__)

# 【FEAT-459 (2026-06-22)】RevenueCat event_type acceptlist (P1-A hotfix)。
# 経済リスク防御: `CANCELLATION` 以外すべて grant 経路に流すと UNCANCELLATION
# (返金取消) 等で重複付与可能 → defense-in-depth で明示的に分類する。
# RevenueCat の event_type 全種は以下参照:
#   https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields
_GRANT_EVENT_TYPES = {
    'INITIAL_PURCHASE',
    'NON_RENEWING_PURCHASE',  # 買い切り (Sabiowl の主用途)
    'RENEWAL',                # 将来 subscription 投入時の備え (現状未使用)
}
_REFUND_EVENT_TYPES = {
    'CANCELLATION',  # 返金
    'EXPIRATION',    # subscription 失効 (現状未使用だが defense-in-depth)
}


class RevenueCatWebhookView(APIView):
    """RevenueCat → Backend の webhook 受信 endpoint。

    POST /api/iap/webhook/
    Headers:
        Authorization: <REVENUECAT_WEBHOOK_AUTH の値>
    Body: RevenueCat 標準 webhook ボディ (event オブジェクトを含む)

    Response:
        200 {"status": "granted", "diamonds": 120}        正常付与
        200 {"status": "skipped", "reason": "..."}        既処理 / 対象外
        200 {"status": "skipped", "reason": "missing_player", "app_user_id": ...}
                                                          PlayerProfile 不在
                                                          (Test Event / Mobile bug、
                                                          IAPReceipt.status='failed' で監査)
        200 {"status": "refunded"}                        返金処理
        401 {"error": {"code": "iap_webhook_unauthorized", ...}}       認証失敗
        400 {"error": {"code": "iap_webhook_invalid_payload", ...}}    ボディ不正
        400 {"error": {"code": "iap_webhook_unknown_product",
                       "fields": {"product_id": "..."}}}               未知 product_id
                                                                       (Apple/Google 設定漏れ)
        500 {"error": {"code": "iap_webhook_server_misconfigured",
                       ...}}                                           REVENUECAT_WEBHOOK_AUTH 未設定
        500 {"error": {"code": "iap_webhook_internal", ...}}           その他
        【FEAT-475 Phase 3a (2026-07-04)】エラー形式を新形式に統一。
    """
    authentication_classes = []  # webhook は Authorization ヘッダーで独自認証
    permission_classes     = [AllowAny]

    def post(self, request):
        # ── 1. Authorization ヘッダー検証 ──────────────────────────────────
        expected = getattr(settings, 'REVENUECAT_WEBHOOK_AUTH', '') or ''
        provided = request.headers.get('Authorization', '')
        if not expected:
            _logger.error('[iap.webhook] REVENUECAT_WEBHOOK_AUTH not configured')
            return error_response(
                code='iap_webhook_server_misconfigured',
                message='購入処理の設定に問題があります。少し時間をおいてお試しください 🪶',
                status=500,
            )
        # 【2026-08-05】`provided != expected` から `hmac.compare_digest` へ変更。
        # 素の `!=` は最初に不一致となったバイトで打ち切るため、比較時間が
        # 「先頭何バイトが一致したか」に依存する (タイミング攻撃の足がかり)。
        # HTTPS 越しの共有シークレットなので実効性は低いが、秘密の比較は
        # 定数時間で行うのが定石であり、コストも 1 行なので合わせる。
        #
        # compare_digest は str 同士だと非 ASCII で TypeError を投げるため、
        # 明示的に UTF-8 バイト列へ落としてから比較する
        # (Authorization ヘッダーに非 ASCII が来ても 500 にしないため)。
        if not hmac.compare_digest(provided.encode('utf-8'), expected.encode('utf-8')):
            _logger.warning(
                '[iap.webhook] auth mismatch: provided=%s...',
                (provided[:8] + '...') if provided else '(empty)',
            )
            return error_response(
                code='iap_webhook_unauthorized',
                message='認証に失敗しました 🪶',
                status=401,
            )

        # ── 2. ペイロード抽出 ──────────────────────────────────────────────
        payload = request.data or {}
        event   = payload.get('event') or {}
        event_id       = event.get('id')
        event_type     = event.get('type', 'UNCATEGORIZED_PURCHASE')
        product_id_raw = event.get('product_id', '')
        app_user_id    = str(event.get('app_user_id') or '')
        transaction_id = str(event.get('transaction_id') or '')
        store_raw      = str(event.get('store') or '').upper()

        if not event_id or not app_user_id:
            _logger.warning('[iap.webhook] invalid_payload: missing event.id or app_user_id')
            return error_response(
                code='iap_webhook_invalid_payload',
                message='購入情報の形式が正しくありません 🪶',
                status=400,
            )

        # store 正規化
        if store_raw == 'APP_STORE':
            store = 'app_store'
        elif store_raw == 'PLAY_STORE':
            store = 'play_store'
        else:
            store = 'sandbox'

        # product_id 正規化 (Apple/Google が com.sabiowl.app.diamond_pack_120 等の
        # 接頭辞付き ID で送ることがあるため suffix match で吸収)
        product_id = _normalize_product_id(product_id_raw)

        # ── 3. 冪等性ガード: event_id で IAPReceipt 作成試行 ──────────────────
        # 同一 event_id を 2 回受信したら IntegrityError → 200 skipped
        try:
            with transaction.atomic():
                receipt = IAPReceipt.objects.create(
                    event_id       = event_id,
                    event_type     = event_type,
                    product_id     = product_id,
                    transaction_id = transaction_id,
                    store          = store,
                    app_user_id    = app_user_id,
                    status         = 'pending',
                    raw_payload    = payload,
                )
        except IntegrityError:
            _logger.info('[iap.webhook] duplicate event_id=%s, skipping', event_id)
            return Response({'status': 'skipped', 'reason': 'already_processed'},
                            status=200)

        # ── 4. event_type 分岐 (FEAT-459 P1-A: 明示 acceptlist) ─────────────
        if event_type in _REFUND_EVENT_TYPES:
            return _handle_cancellation(receipt, app_user_id, product_id)
        if event_type not in _GRANT_EVENT_TYPES:
            # UNCANCELLATION / TRANSFER / TEMPORARY_ENTITLEMENT_GRANT 等の
            # 「想定外 event_type」は skipped で記録のみ (ダイヤ付与しない)。
            receipt.status = 'skipped'
            receipt.error_message = f'unhandled event_type={event_type}'
            receipt.save(update_fields=['status', 'error_message'])
            _logger.warning(
                '[iap.webhook] unhandled event_type=%s event_id=%s app_user_id=%s',
                event_type, event_id, app_user_id,
            )
            return Response({
                'status':     'skipped',
                'reason':     'unhandled_event_type',
                'event_type': event_type,
            }, status=200)

        # ── 5. PlayerProfile 解決 ──────────────────────────────────────────
        try:
            player_pk = int(app_user_id)
            player = PlayerProfile.objects.get(pk=player_pk)
        except (ValueError, PlayerProfile.DoesNotExist):
            # 【FEAT-436 Phase 3 hotfix (2026-06-17)】missing_player は 200 skipped
            # に変更 (旧 400)。理由:
            #   1. RevenueCat の Test Event はランダム仮 app_user_id で送信され、
            #      実 PlayerProfile を持たないため必ずここに来る (本番設定確認時のノイズ)
            #   2. 400 だと RevenueCat が 5 回リトライしてダッシュボードが Failed
            #      で埋まる。再送しても player が出現しないため retry は無意味
            #   3. 真の Mobile bug (Purchases.logIn(playerId) し忘れ等) は
            #      IAPReceipt.status='failed' + error_message + _logger.warning で
            #      引き続き検出可能 (Render Logs で grep `missing_player` 監視)
            receipt.status = 'failed'
            receipt.error_message = f'PlayerProfile not found for app_user_id={app_user_id}'
            receipt.save(update_fields=['status', 'error_message'])
            _logger.warning('[iap.webhook] missing_player app_user_id=%s', app_user_id)
            return Response({'status': 'skipped',
                             'reason': 'missing_player',
                             'app_user_id': app_user_id}, status=200)

        # ── 6. 商品 ID 検証 ────────────────────────────────────────────────
        product_info = IAP_PRODUCTS.get(product_id)
        if not product_info:
            receipt.status = 'failed'
            receipt.error_message = f'unknown product_id={product_id_raw} (normalized: {product_id})'
            receipt.save(update_fields=['status', 'error_message'])
            _logger.warning(
                '[iap.webhook] unknown_product raw=%s normalized=%s',
                product_id_raw, product_id,
            )
            return error_response(
                code='iap_webhook_unknown_product',
                message='商品が見つかりませんでした。少し時間をおいてお試しください 🪶',
                fields={'product_id': product_id_raw},
                status=400,
            )

        diamonds = product_info['diamonds']

        # ── 7. ダイヤ付与 ──────────────────────────────────────────────────
        try:
            receipt.player = player
            new_balance = award_iap_diamonds(
                player     = player,
                product_id = product_id,
                diamonds   = diamonds,
                event_id   = event_id,
            )
            receipt.status           = 'granted'
            receipt.granted_diamonds = diamonds
            receipt.processed_at     = datetime.now(_tz.utc)
            receipt.save(update_fields=[
                'player', 'status', 'granted_diamonds', 'processed_at',
            ])
            _logger.info(
                '[iap.webhook] granted player=%s product=%s diamonds=%s balance=%s',
                player.pk, product_id, diamonds, new_balance,
            )
            return Response({
                'status':   'granted',
                'diamonds': diamonds,
            }, status=200)

        except Exception as exc:
            receipt.status = 'failed'
            receipt.error_message = f'award_iap_diamonds failed: {exc}'
            receipt.save(update_fields=['status', 'error_message'])
            _logger.exception(
                '[iap.webhook] internal error player=%s product=%s',
                player.pk, product_id,
            )
            return error_response(
                code='iap_webhook_internal',
                message='購入の処理中に問題が発生しました。少し時間をおいてお試しください 🪶',
                status=500,
            )


def _normalize_product_id(raw: str) -> str:
    """Apple/Google の product_id を内部識別子に正規化する。

    Apple では `com.sabiowl.app.diamond_pack_120` のようにバンドル ID 配下で
    管理される場合があるため、末尾の `diamond_pack_*` 部分のみを抽出する。
    完全一致 → そのまま、suffix match → 該当 ID を返す。
    """
    if not raw:
        return ''
    if raw in IAP_PRODUCTS:
        return raw
    for key in IAP_PRODUCTS:
        if raw.endswith(key):
            return key
    return raw  # 未知商品はそのまま (呼出側で 400 にする)


def _handle_cancellation(receipt: IAPReceipt, app_user_id: str, product_id: str):
    """CANCELLATION (返金) イベントの処理。

    v1.0.1 では「ダイヤ自動減算」までは実装せず、status='refunded' で記録のみ。
    PM が手動で IAPReceipt を確認し、必要なら別経路で対応する。
    v1.1+ で自動減算ロジックを追加検討 (Pre-mortem S6 + 経済バランスリスク)。
    """
    receipt.status       = 'refunded'
    receipt.processed_at = datetime.now(_tz.utc)
    receipt.save(update_fields=['status', 'processed_at'])
    _logger.warning(
        '[iap.webhook] cancellation received: player_id=%s product=%s '
        '(manual review required for refund handling)',
        app_user_id, product_id,
    )
    return Response({'status': 'refunded'}, status=200)
