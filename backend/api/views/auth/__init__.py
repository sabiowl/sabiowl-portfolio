"""
auth サブパッケージ — 認証関連 View を機能ごとに分割して管理する。

外部（views/__init__.py, urls.py）からは
    from .auth import SocialAuthView, ...
の形式でインポートできる。

FEAT-178 で Magic Link / メール連携を完全廃止し、Google / Apple サインインのみに集約。
"""

from .logout import LogoutView

from .social import (
    SocialAuthView,
    SocialAccountListView,
    SocialLinkView,
    SocialPromoteConfirmView,
    SocialUnlinkView,  # 【BUG-129 (2026-06-14)】社会的連携解除 (誤連携救済)
)

from .guest import (
    DevLoginView,
    GuestInitView,
)

__all__ = [
    # logout
    'LogoutView',
    # social
    'SocialAuthView',
    'SocialAccountListView',
    'SocialLinkView',
    'SocialPromoteConfirmView',
    'SocialUnlinkView',  # 【BUG-129 (2026-06-14)】
    # guest
    'DevLoginView',
    'GuestInitView',
]
