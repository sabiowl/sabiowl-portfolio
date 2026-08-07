"""Django signals 集約ファイル。

apps.py の `ApiConfig.ready()` から import されることで自動登録される。
side-effect (signal receiver の dispatch hook) を発火させる目的のため、
モジュール本体には class / function 定義のみ置き、トップレベルで receiver
を `@receiver` デコレータ経由で登録する。
"""
from django.db.models.signals import post_save, post_delete
from django.dispatch import receiver

from .models import SabiMessage


@receiver([post_save, post_delete], sender=SabiMessage)
def _invalidate_sabi_cache(sender, **kwargs):
    """SabiMessage の create / update / delete 直後に sabi_loader cache を invalidate。

    admin 画面でセリフを編集・追加・削除した瞬間、次の GET /api/sabi/message/
    で最新値を反映するようにする。cache の TTL (60s) を待つ必要がなくなる。
    """
    # 遅延 import (apps.py の ready() より前に sabi_loader が呼ばれることを回避)
    from .sabi_loader import clear_cache
    clear_cache()
