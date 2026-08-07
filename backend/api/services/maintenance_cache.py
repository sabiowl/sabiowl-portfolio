"""【FEAT-471 (2026-07-02)】MaintenanceConfig の 60 秒 TTL cache。

全 API リクエストで毎回 MaintenanceConfig SELECT が発火する問題 (FEAT-463 実装時の
既知 TODOとして保留) を解消。middleware と MaintenanceStatusView が同じ cache キーを
共有することで、1 件のキャッシュで両方の SELECT を吸収する。

【設計判断】
- Django cache framework (LocMemCache, または環境変数で設定した Redis) を使用。
  Render v1.0 では LocMemCache (in-process) で十分 (Pre-mortem S4)。
  Gunicorn 複数 worker 間では worker ごとにキャッシュが独立するが、admin 更新
  から最大 60 秒以内に全 worker が反映するため許容範囲 (Pre-mortem S1)。
- null は 'none' sentinel で cache する。cache.get() の None 返却 (= cache miss)
  と「DB に config なし」を区別するため (Pre-mortem S3)。
"""
from django.core.cache import cache

_CACHE_KEY = 'sabiowl:maintenance_config'
_TTL_SECONDS = 60


def get_maintenance_config():
    """MaintenanceConfig を cache 経由で取得。

    Returns:
        MaintenanceConfig instance (is_enabled フィールドあり) または None。
    """
    cached = cache.get(_CACHE_KEY)
    if cached == 'none':
        return None
    if cached is not None:
        return cached

    from ..models import MaintenanceConfig  # 循環 import 回避のため遅延 import
    config = MaintenanceConfig.objects.filter(pk=1).first()
    cache.set(_CACHE_KEY, config if config is not None else 'none', timeout=_TTL_SECONDS)
    return config


def invalidate_maintenance_cache():
    """cache を即時削除する。admin save 時に呼び出すことで設定変更を即時反映する。"""
    cache.delete(_CACHE_KEY)
