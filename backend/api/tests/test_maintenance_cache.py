"""【FEAT-471 (2026-07-02)】MaintenanceConfig 60 秒 TTL cache の契約テスト。

C1: cache miss → DB クエリ発生、2 回目は cache hit (DB クエリなし)
C2: DB 直接更新は cache に反映されないが、invalidate 後は最新値を返す
C3: MaintenanceConfigAdmin.save_model() が cache を自動 invalidate する
"""
from unittest.mock import MagicMock

from django.contrib.admin.sites import AdminSite
from django.contrib.auth.models import User
from django.core.cache import cache
from django.test import TestCase, override_settings

from api.admin import MaintenanceConfigAdmin
from api.models import MaintenanceConfig
from api.services.maintenance_cache import (
    _CACHE_KEY,
    get_maintenance_config,
    invalidate_maintenance_cache,
)

_LOCMEM = {
    'default': {'BACKEND': 'django.core.cache.backends.locmem.LocMemCache'}
}


@override_settings(CACHES=_LOCMEM)
class MaintenanceCacheTests(TestCase):
    """Django cache framework を通じた MaintenanceConfig の取得/無効化の契約テスト。"""

    def setUp(self):
        cache.clear()

    def test_c1_cache_miss_then_hit(self):
        """C1: 初回 get_maintenance_config() は DB クエリ (miss)、2 回目は cache hit (DB なし)。"""
        MaintenanceConfig.objects.create(pk=1, is_enabled=True, title='テスト')

        # 1 回目: cache miss → SELECT 1 件
        with self.assertNumQueries(1):
            config = get_maintenance_config()
        self.assertIsNotNone(config)
        self.assertTrue(config.is_enabled)

        # 2 回目: cache hit → SELECT 0 件
        with self.assertNumQueries(0):
            config2 = get_maintenance_config()
        self.assertTrue(config2.is_enabled)

    def test_c2_stale_cache_then_invalidate(self):
        """C2: DB 直接更新は cache に反映されない。invalidate 後は最新 DB 値を返す。"""
        MaintenanceConfig.objects.create(pk=1, is_enabled=False, title='旧タイトル')
        get_maintenance_config()  # cache に is_enabled=False を書き込み

        # DB を直接更新 (cache は stale のまま)
        MaintenanceConfig.objects.filter(pk=1).update(is_enabled=True, title='新タイトル')

        # cache hit → stale 値 (is_enabled=False) が返る、DB クエリなし
        with self.assertNumQueries(0):
            stale = get_maintenance_config()
        self.assertFalse(stale.is_enabled)

        # invalidate → cache 削除
        invalidate_maintenance_cache()
        self.assertIsNone(cache.get(_CACHE_KEY))

        # 次の取得は DB から再取得 (is_enabled=True が返る)
        with self.assertNumQueries(1):
            fresh = get_maintenance_config()
        self.assertTrue(fresh.is_enabled)
        self.assertEqual(fresh.title, '新タイトル')

    def test_c3_admin_save_model_invalidates_cache(self):
        """C3: MaintenanceConfigAdmin.save_model() が cache を自動 invalidate する。"""
        obj = MaintenanceConfig.objects.create(pk=1, is_enabled=False, title='旧')
        get_maintenance_config()  # cache に is_enabled=False を書き込み
        self.assertIsNotNone(cache.get(_CACHE_KEY))  # cache に値がある

        # admin save_model を実行 (is_enabled=True に変更)
        obj.is_enabled = True
        obj.title = '新'
        user = User.objects.create_user('admin_test', password='pass')
        mock_request = MagicMock(user=user)
        admin_obj = MaintenanceConfigAdmin(MaintenanceConfig, AdminSite())
        admin_obj.save_model(mock_request, obj, MagicMock(), change=True)

        # save_model が invalidate → cache は空になっている
        self.assertIsNone(cache.get(_CACHE_KEY))

        # 次の get_maintenance_config() は DB から再取得 → 最新値 (is_enabled=True)
        fresh = get_maintenance_config()
        self.assertTrue(fresh.is_enabled)
        self.assertEqual(fresh.title, '新')
