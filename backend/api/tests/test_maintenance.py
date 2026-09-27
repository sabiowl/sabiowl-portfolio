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
from api.views.maintenance import _EN_FALLBACK

# 日本語判定 (ひらがな / カタカナ / 漢字)。
# `test_i18n_api_response_no_japanese.py` の `_CJK` と同じ用途だが、
# あちらは endpoint 走査用の広い集合。ここは「fallback が日本語でない」
# ことだけを見るので最小限に留める。
_CJK = '[぀-ゟ゠-ヿ一-鿿]'


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


# ═══════════════════════════════════════════════════════════════════════════
# 【FEAT-536 Phase 2-3 (2026-08-29)】locale 解決の振る舞い
# ═══════════════════════════════════════════════════════════════════════════


class MaintenanceStatusLocaleTests(TestCase):
    """`/api/maintenance/` が `Accept-Language` を読む。

    ## なぜ必要か —— 障害中の唯一の画面が読めなかった

    本 view は `_en` を持つ他のどの view とも違い、`get_i18n_field` を
    **1 回も呼んでいなかった**。`Accept-Language` は届いており
    (`I18nMiddleware` が `request.locale` を立てている)、
    **読めるのに読んでいない**だけだった (FEAT-536 §2.1)。

    2026-08-29 の dev 実機検証で再現済み。英語端末の overlay は
    `Retry` / `News` / `Contact` / 日付書式まで英語なのに、
    **Backend が返したタイトルと本文だけが日本語**だった。

    ## `_EN_FALLBACK` を持つ理由 (他の view と違う点)

    通常の master data は ja fallback で十分だが、この行を書くのは
    **障害対応の最中**であり、`_en` が空のまま ON にされる確率が構造的に高い。
    実際 Phase 0 では **既定値のまま ON にされた**。
    """

    def setUp(self):
        self.client = APIClient()
        cache.clear()
        self.expires = timezone.now() + timedelta(hours=4)

    def _enable(self, **kwargs):
        defaults = dict(
            pk=1, is_enabled=True,
            title='現在、システムに手当てをしております',
            body='少し時間をおいて、もう一度お試しください 🪶',
            expires_at=self.expires,
        )
        defaults.update(kwargs)
        MaintenanceConfig.objects.create(**defaults)
        invalidate_maintenance_cache()

    def test_l1_english_returns_english_when_en_filled(self):
        """L-1: `Accept-Language: en` + `title_en` あり → 英語が返る。"""
        self._enable(
            title_en='Scheduled maintenance in progress.',
            body_en='We will be back shortly.',
        )
        res = self.client.get('/api/maintenance/', HTTP_ACCEPT_LANGUAGE='en')
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.data['title'], 'Scheduled maintenance in progress.')
        self.assertEqual(res.data['body'], 'We will be back shortly.')

    def test_l2_japanese_is_unchanged(self):
        """L-2: ヘッダ無し / `ja` → 日本語のまま。

        英語対応が「日本語を壊して英語にした」ではないことを縛る。
        """
        self._enable(
            title_en='Scheduled maintenance in progress.',
            body_en='We will be back shortly.',
        )
        for headers in ({}, {'HTTP_ACCEPT_LANGUAGE': 'ja'}):
            with self.subTest(headers=headers):
                res = self.client.get('/api/maintenance/', **headers)
                self.assertEqual(res.status_code, 200)
                self.assertEqual(res.data['title'], '現在、システムに手当てをしております')
                self.assertEqual(res.data['body'], '少し時間をおいて、もう一度お試しください 🪶')

    def test_l3_empty_english_falls_back_to_english_default(self):
        """L-3: `en` + `_en` 空 → `_EN_FALLBACK` が返る (🔴 日本語ではない)。

        他の view は ja に落とすが、**ここだけは英文の既定値に落とす**。
        Phase 0 の実機検証で「既定値のまま ON」が実際に起きており、
        ja fallback では英語ユーザーが**障害中の唯一の画面を読めない**。
        """
        self._enable()  # `_en` は既定の空文字のまま
        res = self.client.get('/api/maintenance/', HTTP_ACCEPT_LANGUAGE='en')
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.data['title'], _EN_FALLBACK['title'])
        self.assertEqual(res.data['body'], _EN_FALLBACK['body'])
        for key in ('title', 'body'):
            self.assertNotRegex(
                res.data[key], _CJK,
                f'英語ロケールなのに {key} に日本語が出ている: {res.data[key]!r}',
            )

    def test_l4_disabled_returns_empty_strings_in_english(self):
        """L-4: `en` + `is_enabled=False` → 空文字 (現行契約の維持)。

        OFF のときは fallback を返さない。`_EN_FALLBACK` を無条件に返すと、
        **メンテしていないのに英文が入った payload** が飛ぶ。
        """
        MaintenanceConfig.objects.create(pk=1, is_enabled=False)
        invalidate_maintenance_cache()
        res = self.client.get('/api/maintenance/', HTTP_ACCEPT_LANGUAGE='en')
        self.assertEqual(res.status_code, 200)
        self.assertFalse(res.data['is_enabled'])
        self.assertEqual(res.data['title'], '')
        self.assertEqual(res.data['body'], '')
        self.assertIsNone(res.data['expires_at'])

    def test_en_fallback_has_no_japanese(self):
        """`_EN_FALLBACK` 自体に日本語が混ざっていない。

        ここが日本語だと L-3 が「日本語が返る」のに緑になる。
        """
        for key, value in _EN_FALLBACK.items():
            self.assertNotRegex(value, _CJK, f'_EN_FALLBACK[{key!r}] に日本語がある')


class MaintenanceConfigSoloTests(TestCase):
    """【FEAT-536 Phase 1-3】`get_solo()` は runbook の緊急経路として使う。

    呼び出し 0 件のデッドコードだったが、**削除ではなく用途を与えた**。
    `get_maintenance_config()` は `.filter(pk=1).first()` で**行を作らない**ため、
    行がまだ無い状態（prod の現状）で **admin UI が使えないとき**に
    ON にする手段が他に無い。`doc/runbook/maintenance_mode.md` の
    「admin が開けないときの緊急 ON」がこれを使う。

    runbook が依存する以上、**振る舞いはテストで固定しておく**
    （デッドコードのまま放置すると、次に誰かが消す）。
    """

    def test_creates_row_at_pk_1(self):
        self.assertFalse(MaintenanceConfig.objects.exists())
        obj = MaintenanceConfig.get_solo()
        self.assertEqual(obj.pk, 1)
        self.assertFalse(obj.is_enabled, '作成しただけでメンテが始まってはいけない')

    def test_is_idempotent(self):
        first = MaintenanceConfig.get_solo()
        first.is_enabled = True
        first.save(update_fields=['is_enabled'])

        second = MaintenanceConfig.get_solo()
        self.assertEqual(second.pk, first.pk)
        self.assertEqual(MaintenanceConfig.objects.count(), 1)
        self.assertTrue(second.is_enabled, '既存行を作り直して設定を消していない')


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
