"""【FEAT-463 (2026-06-22)】緊急メンテナンスモードの契約テスト (6 シナリオ)。

S1: config なし (初期状態) → header 付与されない
S2: is_enabled=True → /api/* レスポンスに X-Maintenance: 1
S3: is_enabled=True でも /admin/* には header 付与されない
S4: DEBUG=True では header 付与されない
S5: expires_at が過去でも is_enabled=True なら header 付与されない (自動失効判定)
S6: GET /api/maintenance/ が is_enabled / title / body / expires_at を返す

【2026-07-07】HealthCheckView 拡張の契約テスト (3 シナリオ):
H1: 正常時 → 200 + checks=all true + status=ok
H2: DB 障害 → 503 + status=degraded + checks.db=false (mock で SELECT 1 fail シミュレート)
H3: schema drift → 503 + status=degraded + checks.schema=false (mock で ORM fail シミュレート)
"""
from datetime import timedelta
from unittest.mock import patch

from django.core.cache import cache
from django.db import DatabaseError
from django.http import HttpResponse
from django.test import RequestFactory, TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from api.middleware.maintenance import MaintenanceMiddleware
from api.models import MaintenanceConfig
from api.services.maintenance_cache import invalidate_maintenance_cache


class MaintenanceMiddlewareTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        # 【FEAT-471】cache は DB ロールバックと連動しないため、テスト間の汚染を防ぐ
        cache.clear()

    @override_settings(DEBUG=False)
    def test_disabled_by_default(self):
        """初期状態 (config なし) では header 付与されない。"""
        response = self.client.get('/api/health/')
        self.assertNotIn('X-Maintenance', response)

    @override_settings(DEBUG=False)
    def test_enabled_adds_header_to_api(self):
        """is_enabled=True で /api/* レスポンスに X-Maintenance: 1。"""
        MaintenanceConfig.objects.create(pk=1, is_enabled=True)
        response = self.client.get('/api/health/')
        self.assertEqual(response['X-Maintenance'], '1')

    @override_settings(DEBUG=False)
    def test_admin_path_bypassed(self):
        """is_enabled=True でも /admin/* には header 付与されない。

        実際の Django admin view は staticfiles manifest (collectstatic 未実行の
        テスト環境では未生成) に依存しテンプレートレンダリングが失敗するため、
        middleware の process_response を直接呼んで bypass ロジックのみを検証する。
        """
        MaintenanceConfig.objects.create(pk=1, is_enabled=True)
        request = RequestFactory().get('/admin/login/')
        response = MaintenanceMiddleware(lambda r: HttpResponse()).process_response(
            request, HttpResponse(),
        )
        self.assertNotIn('X-Maintenance', response)

    @override_settings(DEBUG=True)
    def test_debug_mode_bypassed(self):
        """DEBUG=True では header 付与されない。"""
        MaintenanceConfig.objects.create(pk=1, is_enabled=True)
        response = self.client.get('/api/health/')
        self.assertNotIn('X-Maintenance', response)

    @override_settings(DEBUG=False)
    def test_expires_at_past_auto_disabled(self):
        """expires_at が過去でも is_enabled=True なら自動的に header 付与しない。"""
        MaintenanceConfig.objects.create(
            pk=1, is_enabled=True,
            expires_at=timezone.now() - timedelta(hours=1),
        )
        response = self.client.get('/api/health/')
        self.assertNotIn('X-Maintenance', response)

    @override_settings(DEBUG=False)
    def test_status_view_returns_correct_payload(self):
        """GET /api/maintenance/ が is_enabled / title / body / expires_at を返す。"""
        # 未設定時
        response = self.client.get('/api/maintenance/')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['is_enabled'], False)

        # 有効時 (config を作成したら cache を invalidate — admin 経由では自動実行される)
        expires = timezone.now() + timedelta(hours=4)
        MaintenanceConfig.objects.create(
            pk=1, is_enabled=True, title='テスト中', body='テスト本文 🪶',
            expires_at=expires,
        )
        invalidate_maintenance_cache()
        response = self.client.get('/api/maintenance/')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['is_enabled'], True)
        self.assertEqual(response.data['title'], 'テスト中')
        self.assertEqual(response.data['body'], 'テスト本文 🪶')
        self.assertIsNotNone(response.data['expires_at'])


class HealthCheckViewTests(TestCase):
    """【2026-07-07】HealthCheckView 拡張の契約テスト。

    BootGate widget が本 endpoint を叩いて 200/503 の判定を行うため、
    契約の後方互換性を担保する。
    """
    def setUp(self):
        self.client = APIClient()

    def test_healthy_returns_200_with_all_checks(self):
        """正常時: 200 + checks.process/db/schema=all true + status=ok。"""
        response = self.client.get('/api/health/')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['status'], 'ok')
        self.assertTrue(response.data['checks']['process'])
        self.assertTrue(response.data['checks']['db'])
        self.assertTrue(response.data['checks']['schema'])

    def test_db_failure_returns_503_degraded(self):
        """DB 障害: 503 + status=degraded + checks.db=false。

        Django の connection.cursor().execute() を mock で DatabaseError に
        差し替え、view が正しく 503 を返すことを assert。
        """
        with patch('django.db.backends.utils.CursorWrapper.execute') as mock_exec:
            mock_exec.side_effect = DatabaseError('mock: DB connection refused')
            response = self.client.get('/api/health/')
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.data['status'], 'degraded')
        self.assertTrue(response.data['checks']['process'])
        self.assertFalse(response.data['checks']['db'])
        self.assertFalse(response.data['checks']['schema'])
        self.assertIn('db:', response.data['reason'])

    def test_schema_drift_returns_503_degraded(self):
        """Schema drift: 503 + status=degraded + checks.schema=false。

        DB SELECT 1 は通るが PlayerProfile.objects.first() が
        ProgrammingError (column missing) を投げるシナリオ。model.first() を
        mock で例外に置換して view の分岐を検証。
        """
        with patch(
            'api.models.PlayerProfile.objects',
        ) as mock_manager:
            mock_manager.first.side_effect = DatabaseError(
                'mock: column "battle" does not exist'
            )
            response = self.client.get('/api/health/')
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.data['status'], 'degraded')
        self.assertTrue(response.data['checks']['process'])
        self.assertTrue(response.data['checks']['db'])
        self.assertFalse(response.data['checks']['schema'])
        self.assertIn('schema:', response.data['reason'])
