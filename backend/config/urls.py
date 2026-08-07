"""
URL configuration for Sabiowl Django backend.
"""
import os

from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.urls import path, include

from api.views.admin_mfa import admin_mfa_challenge, admin_mfa_verify  # 【2026-06-29】

# ADMIN_URL: 環境変数で予測困難なパスに変更（defense-in-depth）
# Render に ADMIN_URL=hg-admin-xxxxxxxx/ 等を設定することを推奨
ADMIN_URL = os.environ.get('ADMIN_URL', 'admin/')

urlpatterns = [
    # 【2026-06-29】admin メール OTP MFA。
    # admin.site.urls (path(ADMIN_URL, ...)) より **前** に登録する必要あり。
    # Django は urlpatterns の登録順で前方一致 → 後方に書くと admin.site.urls が
    # mfa/challenge/ も飲み込んでしまう (404)。先に置くことで MFA 経路を優先する。
    path(f'{ADMIN_URL}mfa/challenge/', admin_mfa_challenge, name='admin_mfa_challenge'),
    path(f'{ADMIN_URL}mfa/verify/',    admin_mfa_verify,    name='admin_mfa_verify'),
    path(ADMIN_URL, admin.site.urls),
    path('api/', include('api.urls')),
]

# 【2026-06-27 → 2026-07-03 hotfix】メディアファイル (ImageField の upload_to 配下) の配信。
#
# 旧: `if settings.DEBUG:` ガードで開発時のみ配信 → Render 本番 (DEBUG=False) では
#     `/media/xxx.png` が 404 になり、お知らせ / チュートリアル画像が Mobile で
#     表示されない (Image.network の errorBuilder に落ちる) 不具合が判明。
#
# 新: DEBUG に関係なく Django の `static()` helper で `/media/*` を配信する。
#     `django.views.static.serve` は WSGI 経由の低速な file streaming だが、
#     Sabiowl の運用規模 (お知らせ / チュートリアル画像は月数枚〜数十枚、各 <500KB)
#     では十分許容範囲。1 万リクエスト/月レベルの負荷は Render Starter で問題なし。
#
# 【本番運用の注意】
# ① Render Starter プランは ephemeral filesystem = 再 deploy でコンテナ再作成 →
#    アップロード済 media も消失する。運営は再 deploy 後に admin から画像を
#    再 upload する運用が必要 (お知らせ / チュートリアル 数枚レベルは実運用可)。
# ② 長期的な解決策は v1.1+ で S3 (django-storages) 等 external storage に移行、
#    または Render Persistent Disk 契約 ($1/GB/月) の検討。
urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
