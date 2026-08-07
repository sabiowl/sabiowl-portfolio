"""【FEAT-436 Phase 2 (2026-06-17)】RevenueCat webhook の契約テスト (10 シナリオ)。

S1: 正常な webhook (NON_RENEWING_PURCHASE) → 200 + ダイヤ付与
S2: 同一 event_id 二重受信 → 200 (skipped) (冪等性)
S3: Authorization 不一致 → 401
S4: 未知 product_id → 400 + IAPReceipt(status='failed')
S5: 不在 app_user_id → 200 (skipped) + IAPReceipt(player=null, status='failed')
    【Phase 3 hotfix (2026-06-17)】400 → 200 (skipped) に変更
    (RevenueCat Test Event のランダム仮 ID 対応)
S6: CANCELLATION event → 200 + IAPReceipt(status='refunded')
S7: 反復冪等性 (同一 event_id を 5 回 sequential POST) → 1 granted + 4 skipped
    【Phase 3 hotfix (2026-06-17)】真の並列 threading テストは Django TestCase の
    transaction isolation で worker thread から setUp データが見えないため flaky 化
    + ワーカースレッドの DB connection リークで test DB が destroy 不可になる問題が
    発生したため、5 回連続 POST の反復冪等性テストに書き換え。真の race condition
    は DB レベル (Postgres UNIQUE 制約 + INSERT の atomic 性) で構造的に保証され
    ているため、アプリ層テストの価値は限定的と判断。
S8: UNCANCELLATION (返金取消) → 200 (skipped) + ダイヤ重複付与なし
    【FEAT-459 P1-A (2026-06-22)】event_type acceptlist hotfix
S9: TRANSFER (アカウント間移動) → 200 (skipped) + ダイヤ付与なし
S10: TEMPORARY_ENTITLEMENT_GRANT (Apple promotional) → 200 (skipped)
"""
import uuid

from django.contrib.auth.models import User
from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from api.models import IAPReceipt, PlayerProfile
from ._error_assert import error_code, error_fields, error_message  # 【FEAT-515】


_WEBHOOK_AUTH = 'Bearer test-secret-token-xxx'
_TEST_OVERRIDES = {
    'REVENUECAT_WEBHOOK_AUTH': _WEBHOOK_AUTH,
}


def _build_payload(
    event_id: str | None = None,
    event_type: str = 'NON_RENEWING_PURCHASE',
    product_id: str = 'diamond_pack_120',
    app_user_id: str = '1',
    transaction_id: str = '1000000123456789',
    store: str = 'APP_STORE',
) -> dict:
    """RevenueCat 公式 webhook 仕様の最小ペイロードを作る。"""
    return {
        'api_version': '1.0',
        'event': {
            'id':             event_id or f'evt-{uuid.uuid4().hex[:32]}',
            'type':           event_type,
            'app_user_id':    app_user_id,
            'product_id':     product_id,
            'transaction_id': transaction_id,
            'store':          store,
            'purchased_at_ms': 1700000000000,
            'price':           120,
            'currency':        'JPY',
            'environment':     'SANDBOX',
        },
    }


@override_settings(**_TEST_OVERRIDES)
class RevenueCatWebhookTest(TestCase):
    """RevenueCat webhook の契約テスト。"""

    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(username='iap_user', password='pw')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='テスター', diamonds=0,
        )

    def _post(self, payload: dict, auth: str = _WEBHOOK_AUTH):
        return self.client.post(
            '/api/iap/webhook/',
            payload,
            format='json',
            HTTP_AUTHORIZATION=auth,
        )

    # ─────────────────────────────────────────────────────────────────
    # S1: 正常な webhook → ダイヤ付与
    # ─────────────────────────────────────────────────────────────────
    def test_S1_normal_purchase_grants_diamonds(self):
        payload = _build_payload(
            app_user_id=str(self.player.pk),
            product_id='diamond_pack_120',
        )
        res = self._post(payload)

        self.assertEqual(res.status_code, 200, res.data)
        self.assertEqual(res.data['status'], 'granted')
        self.assertEqual(res.data['diamonds'], 120)

        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 120)
        self.assertEqual(self.player.diamonds_total, 120)

        # IAPReceipt が status='granted' で 1 件記録
        receipt = IAPReceipt.objects.get(event_id=payload['event']['id'])
        self.assertEqual(receipt.status, 'granted')
        self.assertEqual(receipt.granted_diamonds, 120)
        self.assertEqual(receipt.player, self.player)

    # ─────────────────────────────────────────────────────────────────
    # S2: 同一 event_id 二重受信 → skipped (冪等性)
    # ─────────────────────────────────────────────────────────────────
    def test_S2_duplicate_event_id_is_skipped(self):
        payload = _build_payload(
            app_user_id=str(self.player.pk),
            product_id='diamond_pack_120',
        )
        # 1 回目
        res1 = self._post(payload)
        self.assertEqual(res1.status_code, 200)
        self.assertEqual(res1.data['status'], 'granted')

        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 120)

        # 2 回目 (同一 event_id)
        res2 = self._post(payload)
        self.assertEqual(res2.status_code, 200)
        self.assertEqual(res2.data['status'], 'skipped')
        self.assertEqual(res2.data['reason'], 'already_processed')

        # ダイヤは増えていない (冪等性)
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 120)

    # ─────────────────────────────────────────────────────────────────
    # S3: Authorization 不一致 → 401
    # ─────────────────────────────────────────────────────────────────
    def test_S3_invalid_authorization_returns_401(self):
        payload = _build_payload(app_user_id=str(self.player.pk))
        res = self._post(payload, auth='Bearer wrong-token')
        self.assertEqual(res.status_code, 401)
        # 【FEAT-475 Phase 3a (2026-07-04)】新形式 {'error': {'code', 'message'}}
        self.assertEqual(error_code(res), 'iap_webhook_unauthorized')

        # IAPReceipt も作成されていない
        self.assertEqual(IAPReceipt.objects.count(), 0)
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 0)

    # ─────────────────────────────────────────────────────────────────
    # S3-b: Authorization に非 ASCII → 401 (500 にしない)
    #
    # 【2026-08-05】シークレット比較を `!=` から `hmac.compare_digest` へ
    # 変更した際の回帰ガード。compare_digest は str 同士だと非 ASCII で
    # TypeError を投げるため、bytes へ落としてから比較している。
    # この変換を外すと本テストが 500 で落ちる。
    # ─────────────────────────────────────────────────────────────────
    def test_S3b_non_ascii_authorization_returns_401_not_500(self):
        payload = _build_payload(app_user_id=str(self.player.pk))
        res = self._post(payload, auth='Bearer 日本語トークン😀')
        self.assertEqual(
            res.status_code, 401,
            '非 ASCII の Authorization で 500 になっている '
            '(compare_digest に str を渡すと TypeError)',
        )
        self.assertEqual(error_code(res), 'iap_webhook_unauthorized')
        self.assertEqual(IAPReceipt.objects.count(), 0)

    # ─────────────────────────────────────────────────────────────────
    # S3-c: 正しいシークレットの前方一致部分だけでは通らない
    #
    # 定数時間比較へ変えても「前方一致で通る」ような実装ミス
    # (例: startswith や切り詰め比較) を入れていないことを固定する。
    # ─────────────────────────────────────────────────────────────────
    def test_S3c_prefix_of_valid_secret_is_rejected(self):
        payload = _build_payload(app_user_id=str(self.player.pk))
        valid = _WEBHOOK_AUTH
        self.assertGreater(len(valid), 4, 'テスト用シークレットが短すぎる')

        for candidate in (valid[:-1], valid[:4], valid + 'x'):
            with self.subTest(candidate=candidate):
                res = self._post(payload, auth=candidate)
                self.assertEqual(res.status_code, 401)

        self.assertEqual(IAPReceipt.objects.count(), 0)
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 0)

    # ─────────────────────────────────────────────────────────────────
    # S4: 未知 product_id → 400 + status='failed'
    # ─────────────────────────────────────────────────────────────────
    def test_S4_unknown_product_id_fails(self):
        payload = _build_payload(
            app_user_id=str(self.player.pk),
            product_id='unknown_product_xxx',
        )
        res = self._post(payload)
        self.assertEqual(res.status_code, 400)
        # 【FEAT-475 Phase 3a (2026-07-04)】新形式 + fields で product_id を検証
        self.assertEqual(error_code(res), 'iap_webhook_unknown_product')
        self.assertEqual(error_fields(res)['product_id'], 'unknown_product_xxx')

        # IAPReceipt は status='failed' で記録
        receipt = IAPReceipt.objects.get(event_id=payload['event']['id'])
        self.assertEqual(receipt.status, 'failed')
        self.assertIn('unknown product_id', receipt.error_message)

        # ダイヤは増えていない
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 0)

    # ─────────────────────────────────────────────────────────────────
    # S5: 不在 app_user_id → 200 skipped + status='failed' + player=null
    # 【Phase 3 hotfix (2026-06-17)】RevenueCat Test Event のランダム仮 ID 対応で
    # missing_player は 400 → 200 skipped に変更 (リトライ抑制 + ダッシュボード
    # ノイズ低減)。IAPReceipt の status='failed' / error_message は維持で監査経路
    # を保つため、本テストは「200 OK だが内部 status=failed」を縛る。
    # ─────────────────────────────────────────────────────────────────
    def test_S5_missing_player_skipped_with_failed_receipt(self):
        payload = _build_payload(
            app_user_id='999999',  # 存在しない player.id
            product_id='diamond_pack_120',
        )
        res = self._post(payload)
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.data['status'], 'skipped')
        self.assertEqual(res.data['reason'], 'missing_player')

        # IAPReceipt は player=null + status='failed' で監査用に保存
        receipt = IAPReceipt.objects.get(event_id=payload['event']['id'])
        self.assertIsNone(receipt.player)
        self.assertEqual(receipt.status, 'failed')
        self.assertIn('PlayerProfile not found', receipt.error_message)

    # ─────────────────────────────────────────────────────────────────
    # S6: CANCELLATION event → 200 + status='refunded' (ダイヤは自動減算しない)
    # ─────────────────────────────────────────────────────────────────
    def test_S6_cancellation_is_recorded_without_auto_refund(self):
        # 先に正常購入してダイヤを 120 にしておく
        purchase_payload = _build_payload(
            app_user_id=str(self.player.pk),
            product_id='diamond_pack_120',
        )
        self._post(purchase_payload)
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 120)

        # CANCELLATION event を別 event_id で送信
        cancel_payload = _build_payload(
            event_type='CANCELLATION',
            app_user_id=str(self.player.pk),
            product_id='diamond_pack_120',
        )
        res = self._post(cancel_payload)
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.data['status'], 'refunded')

        # IAPReceipt は status='refunded'
        receipt = IAPReceipt.objects.get(event_id=cancel_payload['event']['id'])
        self.assertEqual(receipt.status, 'refunded')

        # v1.0.1 ではダイヤは自動減算しない (PM 手動確認)
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 120)

    # ─────────────────────────────────────────────────────────────────
    # S7: 反復冪等性 (同一 event_id を 5 回連続 POST) → 1 度しか付与されない
    # ─────────────────────────────────────────────────────────────────
    # 【Phase 3 hotfix (2026-06-17)】真の並列 threading テストは Django TestCase
    # の transaction isolation で worker thread から setUp の player が見えず flaky
    # 化 + DB connection リークで test DB destroy 不可になる問題が発生したため、
    # 5 回連続 POST に書き換え。真の race condition は DB レベル (Postgres UNIQUE
    # 制約 + INSERT の atomic 性) で構造的に保証され、アプリ層では IntegrityError
    # の catch 経路が S2 で deterministic に検証済。本 S7 は「多重再送への耐性」
    # を補強する位置付け。
    def test_S7_repeated_duplicate_webhooks_all_idempotent(self):
        """同一 event_id を 5 回連続 POST → 1 granted + 4 skipped。

        DB の unique 制約 + IntegrityError catch で必ず 1 度しか付与されない。
        webhook の多重再送 (RevenueCat の自動 5 回リトライ等) に対する耐性を縛る。
        """
        payload = _build_payload(
            app_user_id=str(self.player.pk),
            product_id='diamond_pack_120',
        )

        results = []
        for _ in range(5):
            res = self._post(payload)
            self.assertEqual(res.status_code, 200, res.data)
            results.append(res.data.get('status'))

        # 5 リクエスト中 1 つは 'granted'、残り 4 つは 'skipped'
        granted_count = results.count('granted')
        skipped_count = results.count('skipped')
        self.assertEqual(granted_count, 1,
                         f'expected exactly 1 granted, got {granted_count}: {results}')
        self.assertEqual(skipped_count, 4,
                         f'expected 4 skipped, got {skipped_count}: {results}')

        # ダイヤは 120 (重複加算なし)
        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 120)
        self.assertEqual(IAPReceipt.objects.count(), 1)

    # ─────────────────────────────────────────────────────────────────
    # S8: UNCANCELLATION (返金取消) → 200 skipped、ダイヤ重複付与なし
    # 【FEAT-459 P1-A (2026-06-22)】CANCELLATION とは別 event_id で来るため、
    # acceptlist がなければ grant 経路に流れてしまう (経済リスク)。
    # ─────────────────────────────────────────────────────────────────
    def test_S8_uncancellation_returns_skipped(self):
        payload = _build_payload(
            event_type='UNCANCELLATION',
            app_user_id=str(self.player.pk),
            product_id='diamond_pack_120',
        )
        res = self._post(payload)
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.data['status'], 'skipped')
        self.assertEqual(res.data['reason'], 'unhandled_event_type')

        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 0,
                         'UNCANCELLATION では diamonds 増えないこと')

        receipt = IAPReceipt.objects.get(event_id=payload['event']['id'])
        self.assertEqual(receipt.status, 'skipped')
        self.assertIn('UNCANCELLATION', receipt.error_message)

    # ─────────────────────────────────────────────────────────────────
    # S9: TRANSFER (アカウント間移動) → 200 skipped、ダイヤ付与なし
    # ─────────────────────────────────────────────────────────────────
    def test_S9_transfer_returns_skipped(self):
        payload = _build_payload(
            event_type='TRANSFER',
            app_user_id=str(self.player.pk),
            product_id='diamond_pack_660',
        )
        res = self._post(payload)
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.data['status'], 'skipped')
        self.assertEqual(res.data['reason'], 'unhandled_event_type')

        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 0)

    # ─────────────────────────────────────────────────────────────────
    # S10: TEMPORARY_ENTITLEMENT_GRANT (Apple promotional) → 200 skipped
    # PM が promotional code を意図して使う場合は別経路で diamonds 付与すべき。
    # Backend は防衛側として「想定外 event_type は付与しない」を厳守する。
    # ─────────────────────────────────────────────────────────────────
    def test_S10_temporary_entitlement_grant_returns_skipped(self):
        payload = _build_payload(
            event_type='TEMPORARY_ENTITLEMENT_GRANT',
            app_user_id=str(self.player.pk),
            product_id='diamond_pack_120',
        )
        res = self._post(payload)
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.data['status'], 'skipped')
        self.assertEqual(res.data['reason'], 'unhandled_event_type')

        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 0)

    # ─────────────────────────────────────────────────────────────────
    # S11: diamond_pack_1440 (新規 1200 円 / 1440 個、+20% ボーナス) →
    #      正常付与 1440 ダイヤ
    # ─────────────────────────────────────────────────────────────────
    def test_S11_diamond_pack_1440_grants_1440_diamonds(self):
        payload = _build_payload(
            app_user_id=str(self.player.pk),
            product_id='diamond_pack_1440',
        )
        res = self._post(payload)

        self.assertEqual(res.status_code, 200, res.data)
        self.assertEqual(res.data['status'], 'granted')
        self.assertEqual(res.data['diamonds'], 1440)

        self.player.refresh_from_db()
        self.assertEqual(self.player.diamonds, 1440)
        self.assertEqual(self.player.diamonds_total, 1440)

        receipt = IAPReceipt.objects.get(event_id=payload['event']['id'])
        self.assertEqual(receipt.status, 'granted')
        self.assertEqual(receipt.granted_diamonds, 1440)
        self.assertEqual(receipt.product_id, 'diamond_pack_1440')
