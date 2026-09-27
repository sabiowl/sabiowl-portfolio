"""【FEAT-543 (2026-09-23)】AppUpdateConfig の 60 秒 TTL cache。

`services/maintenance_cache.py` (FEAT-471) と同じ形。起動のたびに
`GET /api/app-update/` が SELECT を撃つのを避ける。

⚠️ null は `'none'` sentinel で cache する。`cache.get()` の None 返却
(= cache miss) と「DB に config なし」を区別するため。

🔵 Gunicorn の worker ごとに cache が独立するので、admin の保存が全 worker に
行き渡るまで最大 60 秒かかる。**事故ったら `is_enabled` を OFF にすれば
60 秒で全ユーザーから消える**、というのがこの TTL の意味である。
"""
from django.core.cache import cache

_CACHE_KEY = 'sabiowl:app_update_config'
_TTL_SECONDS = 60


def get_app_update_config():
    """AppUpdateConfig を cache 経由で取得。

    Returns:
        AppUpdateConfig instance または None。
    """
    cached = cache.get(_CACHE_KEY)
    if cached == 'none':
        return None
    if cached is not None:
        return cached

    from ..models import AppUpdateConfig  # 循環 import 回避のため遅延 import
    config = AppUpdateConfig.objects.filter(pk=1).first()
    cache.set(_CACHE_KEY, config if config is not None else 'none',
              timeout=_TTL_SECONDS)
    return config


def invalidate_app_update_cache():
    """cache を即時削除する。admin save 時に呼ぶことで設定変更を即時反映する。"""
    cache.delete(_CACHE_KEY)
