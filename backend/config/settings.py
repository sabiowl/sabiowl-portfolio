"""
Sabiowl Django settings

環境変数は .env ファイルまたはデプロイ先のシークレット設定から読み込む。
- ローカル開発: .env を使用（DATABASE_URL 未設定 → SQLite）
- 本番        : DATABASE_URL に PostgreSQL URL を設定
"""

from pathlib import Path
from urllib.parse import urlparse
import os

from dotenv import load_dotenv

# .env ファイルの読み込み（存在しなくてもエラーにならない）
BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / '.env')


# ── 基本設定 ──────────────────────────────────────────────────

DEBUG = os.environ.get('DEBUG', 'False').lower() in ('true', '1', 'yes')

SECRET_KEY = os.environ.get('SECRET_KEY')
if not SECRET_KEY:
    if DEBUG:
        # ローカル開発（DEBUG=True）では仮鍵で起動を許容（.env を設定すること）
        SECRET_KEY = 'django-insecure-local-dev-only-set-env-var'  # noqa: S105
    else:
        raise RuntimeError(
            'SECRET_KEY environment variable is not set. '
            'Set it in .env (local) or Render dashboard (production).'
        )

# 【SEC-13 C-02】ALLOWED_HOSTS defense in depth。
# 本番 (DEBUG=False) で ALLOWED_HOSTS 未設定の場合は ['localhost'] フォールバックで
# 黙って全リクエスト 400 を返すのではなく、起動時に明示的に失敗させる。
# render.yaml では `ALLOWED_HOSTS=sabiowl-backend.onrender.com,sabiowl.com,www.sabiowl.com`
# が設定済みのため通常パスは通る。本ガードは「環境変数が誤って消えた」「新環境
# でデプロイ時に設定し忘れた」等の運用ミスを早期検出するための backstop。
_allowed = os.environ.get('ALLOWED_HOSTS', '')
if _allowed:
    ALLOWED_HOSTS = [h.strip() for h in _allowed.split(',') if h.strip()]
elif DEBUG:
    # ローカル開発 (.env で ALLOWED_HOSTS 未指定) は全ホスト許可
    ALLOWED_HOSTS = ['*']
else:
    raise RuntimeError(
        'ALLOWED_HOSTS environment variable is required when DEBUG=False. '
        'Set it in Render dashboard (production) or .env (staging).'
    )


# ── Application definition ────────────────────────────────────

INSTALLED_APPS = [
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    # Third-party
    'rest_framework',
    'rest_framework.authtoken',
    'whitenoise.runserver_nostatic',  # 開発時も whitenoise を使用
    'waffle',                         # 【FEAT-477】Feature Flag (段階リリース / A/B テスト)
    # Local
    'api',
]

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'django.middleware.gzip.GZipMiddleware',  # P0-1: 全レスポンスを gzip 圧縮（30–70% 削減）
    'whitenoise.middleware.WhiteNoiseMiddleware',  # 静的ファイル配信（本番用）
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'api.middleware.i18n.I18nMiddleware',               # 【FEAT-489 Phase 4】request.locale 確定
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
    # 【2026-06-29】admin 画面の OTP MFA 強制。AuthenticationMiddleware の **後** に置く
    # 必要あり (request.user.is_staff を見る)。本番では常に強制 ON、DEBUG=True かつ
    # ADMIN_MFA_REQUIRED=False のときのみ bypass。
    'api.middleware.admin_mfa.AdminMFARequiredMiddleware',
    'api.middleware.maintenance.MaintenanceMiddleware',  # 【FEAT-463】末尾追加
    'waffle.middleware.WaffleMiddleware',               # 【FEAT-477】Feature Flag
]

# 【FEAT-477】waffle 設定 — 明示的に admin で作成した flag のみ有効。
# 未定義 flag 参照は False を返すため、Mobile 側は always-safe な fallback になる。
WAFFLE_CREATE_MISSING_FLAGS = False

ROOT_URLCONF = 'config.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = 'config.wsgi.application'


# ── データベース ───────────────────────────────────────────────
# DATABASE_URL が設定されていれば PostgreSQL、なければ SQLite（ローカル開発用）

_db_url = os.environ.get('DATABASE_URL', '').strip()

if _db_url:
    # PostgreSQL (例: postgres://user:pass@host:5432/dbname)
    _parsed = urlparse(_db_url)
    DATABASES = {
        'default': {
            'ENGINE':   'django.db.backends.postgresql',
            'NAME':     _parsed.path.lstrip('/'),
            'USER':     _parsed.username or '',
            'PASSWORD': _parsed.password or '',
            'HOST':     _parsed.hostname or 'localhost',
            'PORT':     str(_parsed.port or 5432),
            'OPTIONS':  {
                # 【SEC-13 C-03】SSL モードは env-var 駆動 (defense in depth)。
                # 旧実装は DEBUG フラグに連動していたため、誤って DEBUG=True を
                # 残したまま PostgreSQL に接続すると平文通信になるリスクがあった。
                # default='require' で「明示指定がない限り常に SSL を要求」、
                # ローカル PG での平文接続が必要な場合のみ DB_SSL_MODE=prefer
                # (もしくは disable) を .env に設定する escape hatch を残す。
                'sslmode': os.environ.get('DB_SSL_MODE', 'require'),
            },
            # 【FEAT-394 (2026-05-30)】Neon Pooled (PgBouncer transaction mode) 対応
            # PgBouncer 経由では persistent connection を Django に持たせるとプールが
            # 詰まるため CONN_MAX_AGE=0、PgBouncer transaction mode では SET LOCAL や
            # server-side cursors が使えないため DISABLE_SERVER_SIDE_CURSORS=True。
            # Django 公式推奨設定:
            # https://docs.djangoproject.com/en/4.2/ref/databases/#transaction-pooling-server-side-cursors
            # Render PostgreSQL (移行前) でも問題なく動作するため、移行前後で同コードで OK。
            'CONN_MAX_AGE':                0,
            'DISABLE_SERVER_SIDE_CURSORS': True,
        }
    }
else:
    # SQLite（ローカル開発）
    DATABASES = {
        'default': {
            'ENGINE': 'django.db.backends.sqlite3',
            'NAME':   BASE_DIR / 'db.sqlite3',
        }
    }


# ── パスワードバリデーション ──────────────────────────────────

AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator'},
    {'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator'},
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator'},
]


# ── 国際化 ───────────────────────────────────────────────────

LANGUAGE_CODE = 'ja'
TIME_ZONE     = 'Asia/Tokyo'
USE_I18N      = True
USE_TZ        = True


# ── 静的ファイル ──────────────────────────────────────────────

STATIC_URL  = '/static/'
STATIC_ROOT = BASE_DIR / 'staticfiles'   # collectstatic の出力先（本番用）

# 【2026-06-27】メディアファイル (ImageField の upload_to 配下) 設定。
# Announcement.image (お知らせ画像) 等のユーザーアップロード画像を格納。
# Render 本番は ephemeral filesystem (再 deploy で消失) のため、頻繁な画像
# 更新があれば v1.1+ で S3 等 external storage に migrate (django-storages)。
# 短期運用 (お知らせ画像は月数件程度) は MEDIA_ROOT で許容、再 deploy 時に
# 運営が手動で再アップロード可能。
MEDIA_URL  = '/media/'
MEDIA_ROOT = BASE_DIR / 'media'   # ImageField 等の保存先

# Whitenoise: gzip 圧縮+長期キャッシュ
# 【2026-06-29 hotfix】config/storage.py の WhiteNoiseStaticFilesStorage に変更。
# manifest_strict=False で「manifest entry 不在ファイルは素 URL フォールバック」になり、
# collectstatic 部分失敗時の 500 を防ぐ (本番 admin 画面の defense in depth)。
STORAGES = {
    'default': {
        'BACKEND': 'django.core.files.storage.FileSystemStorage',
    },
    'staticfiles': {
        'BACKEND': 'config.storage.WhiteNoiseStaticFilesStorage',
    },
}

DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'


# ── 本番セキュリティ設定 ──────────────────────────────────────
# DEBUG=False の場合のみ有効

if not DEBUG:
    # HTTPS リダイレクト。本番 Render は proxy で HTTPS 終端するため True が正しい。
    # CI テスト環境では SECURE_SSL_REDIRECT=False を env 注入して無効化する。
    SECURE_SSL_REDIRECT            = os.environ.get('SECURE_SSL_REDIRECT', 'True').lower() in ('true', '1', 'yes')
    SECURE_PROXY_SSL_HEADER        = ('HTTP_X_FORWARDED_PROTO', 'https')
    # HSTS（ブラウザに HTTPS を強制）
    SECURE_HSTS_SECONDS            = 31536000  # 1年
    SECURE_HSTS_INCLUDE_SUBDOMAINS = True
    SECURE_HSTS_PRELOAD            = True
    # Cookie のセキュリティ
    SESSION_COOKIE_SECURE          = True
    CSRF_COOKIE_SECURE             = True
    CSRF_COOKIE_HTTPONLY           = True
    # クリックジャッキング対策
    X_FRAME_OPTIONS                = 'DENY'


# ── Django REST Framework ──────────────────────────────────────

REST_FRAMEWORK = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        # FEAT-187: ゲストモードのサーバー化。
        # ExpiringTokenAuthentication（DRF Token）と GuestTokenAuthentication
        # （Authorization: GuestToken <token>）を両方試す。先に通ったものが採用される。
        'api.authentication.ExpiringTokenAuthentication',
        'api.authentication.GuestTokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_THROTTLE_CLASSES': [
        'rest_framework.throttling.AnonRateThrottle',
        'rest_framework.throttling.UserRateThrottle',
    ],
    'DEFAULT_THROTTLE_RATES': {
        # 【BUG-158 (2026-09-12)】anon 60 → 300 / user 300 → 1200。
        #
        # 🔴 **旧値は通常利用で枯れていた。** 実測 (Sentry 2026-09-11):
        # 知人テスターの `GachaService.pullGacha` が 429。枯れたのは user である。
        #
        # 1 時間あたりの消費見積もり:
        #   ガチャ 43 連 (Daily 30 / Weekly 10 / Monthly 3) × 3 本  ≈ 130
        #   ホーム cold start 10 回 × 10 本以上                     ≈ 100-150
        #   バトル 10 戦 × 3 本                                     ≈  30
        #                                                     合計 ≈ 310
        # 旧 user の 300/hour は **5 リクエスト/分**で、この実測レンジそのもの。
        # 濫用ではなく**通常利用で当たる**。プロダクトが「Daily 30 枚をまとめて
        # 引く」を促しているのに、上限がそれを許していなかった。
        # → 見積もり 310 に対して約 4 倍の余裕を取り user 1200 とする。
        # anon (ゲスト / 未認証、IP キー) も同じ比率で 300 に引き上げる。
        #
        # ⚠️ **これは濫用防止を弱める判断である。** 承知の上で採る根拠:
        #   1. 実効的な防御は**個別 scope とゲームロジック側**にある ——
        #      下の contact / habit_action / friend_search / social_auth /
        #      guest_init + 日次バトル上限 10 戦 + ガチャチケット上限
        #   2. グローバル throttle は**粗い backstop** であり、通常利用を
        #      妨げてまで厳しくする価値がない
        #   3. 1200/hour = **20 リクエスト/分**。スクリプトによる大量アクセスは
        #      依然として止まる
        #
        # 🔴 **「緩すぎる」と判断して戻さないこと。** 戻すと BUG-158 が再発する。
        # 下げるなら先に上の見積もりを更新すること。不変条件は
        # `api/tests/test_throttle_rates.py` が縛っている (値と本コメントの整合も)。
        'anon': '300/hour',
        'user': '1200/hour',
        # 【SEC-15 L-01 (2026-05-30)】magic_link scope 削除 (FEAT-178 で MagicLink 撤去済、参照ゼロ)
        # 【SEC-11】sabi_navigate scope は SabiNavigate(LLM) 廃止（2026-05-15）で削除
        'contact': '3/hour',
        'habit_action':  '120/hour',
        'friend_search': '30/hour',
        'social_auth':   '20/hour',  # H-02: Firebase ID トークン検証コール（外部 API・課金対象）の濫用防止
        # SEC-08 / H-03-new: ゲストセッション作成 (GuestSession + PlayerProfile + 既定習慣 / ToDo /
        # ガチャチケット seed) は DB を 5〜10 レコード消費する重量級操作。通常デバイスは
        # 初回インストール時にしか叩かないため 5/hour で十分余裕がある。本番ログを監視して
        # 正規利用での 429 発生率が高ければ緩める。
        'guest_init':    '5/hour',
    },
}


# ── メール設定 ────────────────────────────────────────────────

EMAIL_BACKEND    = os.environ.get('EMAIL_BACKEND', 'django.core.mail.backends.console.EmailBackend')
DEFAULT_FROM_EMAIL = os.environ.get('DEFAULT_FROM_EMAIL', 'Sabiowl <noreply@sabiowl.com>')  # OPS-01: ドメイン + アプリ名変更

# SMTP 設定（EMAIL_BACKEND=smtp 時に使用）
EMAIL_HOST          = os.environ.get('EMAIL_HOST', '')
EMAIL_PORT          = int(os.environ.get('EMAIL_PORT', '587'))
EMAIL_USE_TLS       = os.environ.get('EMAIL_USE_TLS', 'True').lower() in ('true', '1', 'yes')
EMAIL_HOST_USER     = os.environ.get('EMAIL_HOST_USER', '')
EMAIL_HOST_PASSWORD = os.environ.get('EMAIL_HOST_PASSWORD', '')
# SMTP 接続タイムアウト（秒）— Gunicorn worker timeout より短く設定してワーカー道連れを防ぐ
EMAIL_TIMEOUT = int(os.environ.get('EMAIL_TIMEOUT', '15'))

# 【FEAT-395 (2026-05-31)】Resend HTTP API キー (お問い合わせメール送信用)
# 旧 SMTP (smtp.resend.com:587) は Render 環境で TCP 接続 timeout 多発 (本日 FEAT-394
# Neon 移行後の検証で再現)。Resend HTTP API (HTTPS) に切替で構造解消。
# Render dashboard で手動設定 (sync: false、commit に API キーを含めない)。
# SMTP 関連設定 (EMAIL_HOST 等) は他の用途用に維持。
RESEND_API_KEY = os.environ.get('RESEND_API_KEY', '')

# 【FEAT-395 (2026-05-31)】お問い合わせメールの宛先 (環境変数化)。
# 旧: views/health.py の to=['support@sabiowl.com'] ハードコード
# 新: 環境変数化で「Resend ドメイン未認証時は運営 Gmail 宛、認証完了後は support@」を
#     Render dashboard だけで切替可能にする (コード変更不要)。
# 既定値は本来の運用宛先 (support@sabiowl.com、Resend ドメイン認証完了済の前提)。
CONTACT_TO_EMAIL = os.environ.get('CONTACT_TO_EMAIL', 'support@sabiowl.com')


# 【SEC-15 L-01 (2026-05-30)】MAGIC_LINK_BASE_URL 削除。
# FEAT-178 (2026-05-XX) で MagicLink 経路を完全撤去 (migration 0061) しており、
# `MAGIC_LINK_BASE_URL` を参照するコード経路はゼロ。dead path として整理。

# ── 開発用ログイン（Render に DEV_LOGIN_ENABLED=true を設定時のみ有効） ────
# ⚠ 本番リリースでは絶対に true にしない
DEV_LOGIN_ENABLED = os.environ.get('DEV_LOGIN_ENABLED', 'False').lower() in ('true', '1', 'yes')


# ── 【2026-06-29】admin 画面 OTP MFA 設定 ──────────────────────────────────
# Django admin にログインする際に、username/password 認証後に 6 桁の OTP コードを
# メール送信 (Resend HTTP API、FEAT-395 と同経路) → コード入力で 2 要素認証を強制する。
#
# 本番 (Render): 常に強制 ON (環境変数 ADMIN_MFA_REQUIRED=true、または未設定で true)
# ローカル (DEBUG=True): ADMIN_MFA_REQUIRED=false で bypass 可能
#
# MFA 有効期限 (verified session 保持): デフォルト 12 時間。短くしたい場合は
# 環境変数 ADMIN_MFA_SESSION_SECONDS=1800 (= 30 分) 等で上書き可能。
#
# 真実値: api/middleware/admin_mfa.py + api/views/admin_mfa.py
ADMIN_MFA_REQUIRED = os.environ.get('ADMIN_MFA_REQUIRED', 'True').lower() in ('true', '1', 'yes')


# ── FEAT-436 Phase 2: RevenueCat webhook 認証 ──────────────────────────────
# RevenueCat → Backend の webhook 受信時に Authorization ヘッダーを照合する値。
# RevenueCat ダッシュボード (Integrations → Webhooks → Authorization Header) で
# 設定した値と完全一致する文字列を Render 環境変数に登録する。
# 未設定時は webhook が 500 (server_misconfigured) を返すため、Phase 2 リリース
# 前に必ず Render dashboard で設定すること (sync: false でリポジトリに含めない)。
#
# 🔵 【2026-08-28 確認済、改名しないこと】この値はデバッグページで伏せ字になる。
# `SafeExceptionReporterFilter.hidden_settings` は
# `API|AUTH|TOKEN|KEY|SECRET|PASS|SIGNATURE|HTTP_COOKIE` (Django 6.0) を
# **settings の属性名**に当てており、"AUTH" が含まれるので掛かる。
# 一度 `REVENUECAT_WEBHOOK_SECRET` への改名を検討したが、**改名しても結果は同じ**で、
# 移行期の後方互換読みと env var 差し替えのコストだけが残るため見送った。
#
# ⚠️ ただし判定は **属性名だけ**で、値は見ない。ここの左辺に秘密らしい語が
# 入らない名前 (例: `..._HEADER`) を付けると平文で出る。新しい秘密を足すときは
# 上の正規表現に掛かる名前にすること。
REVENUECAT_WEBHOOK_AUTH = os.environ.get('REVENUECAT_WEBHOOK_AUTH', '')
# オプション: 失敗 receipt の手動再確認等で RevenueCat REST API を叩く場合に使用
# (v1.0.1 では未使用、v1.1+ で導入検討)
REVENUECAT_REST_API_KEY = os.environ.get('REVENUECAT_REST_API_KEY', '')


# ── 【FEAT-536 Phase 0-a (2026-08-28)】ログ出力 ────────────────────────────
#
# 🔴 **これが無いと `DEBUG=False` にした瞬間、500 のトレースバックが消える。**
#
# Django の既定 LOGGING (`DEFAULT_LOGGING`) は console ハンドラに
# `require_debug_true` フィルタを付けている。つまり `DEBUG=False` では console に
# 何も出ず、`django.request` の ERROR は `mail_admins` にしか流れない
# (ADMINS も EMAIL も webhook 用途では未設定なので、事実上どこにも出ない)。
#
# 2026-08-28 に dev を `DEBUG=False` へ倒す際に判明した。それまで dev の
# トレースバックが Render Logs で読めていたのは `DEBUG=True` だったからで、
# 本設定が無いまま倒すと「黄色いデバッグページ」を「沈黙」と交換することになる。
#
# `api` ロガーも明示する。従来 `api.*` は親に handler が無く Python の
# `logging.lastResort` (stderr / WARNING 以上) 経由でしか出ておらず、
# `_logger.info(...)` が本番で見えなかった (`api/views/player.py` の
# 冒頭コメントがその不便を記録している)。ここで INFO を既定にして解消する。
#
# レベルは環境変数で上下できる。ノイズが増えたら Render 側で
# `API_LOG_LEVEL=WARNING` を入れれば、デプロイなしで絞れる。
_DJANGO_LOG_LEVEL = os.environ.get('DJANGO_LOG_LEVEL', 'WARNING').upper()
_API_LOG_LEVEL    = os.environ.get('API_LOG_LEVEL', 'INFO').upper()

LOGGING = {
    'version': 1,
    # 既存ロガーを殺さない。サードパーティ (dj_database_url / sentry_sdk 等) が
    # 自前で取得したロガーを黙らせないため。
    'disable_existing_loggers': False,
    'formatters': {
        'simple': {'format': '[{levelname}] {name}: {message}', 'style': '{'},
    },
    'handlers': {
        # 🔴 `filters` を付けない。既定の `require_debug_true` を外すことが本設定の目的。
        'console': {'class': 'logging.StreamHandler', 'formatter': 'simple'},
    },
    # 明示していないロガー (サードパーティ) の受け皿。lastResort と同じ WARNING。
    'root': {'handlers': ['console'], 'level': 'WARNING'},
    'loggers': {
        # `django.request` は本ロガーの子なので、ここの handler に届く
        # (4xx = WARNING / 5xx = ERROR + traceback)。個別定義は不要。
        'django': {'handlers': ['console'], 'level': _DJANGO_LOG_LEVEL, 'propagate': False},
        'api':    {'handlers': ['console'], 'level': _API_LOG_LEVEL,    'propagate': False},
    },
}


# ── FEAT-470: Sentry エラー監視 ──────────────────────────────────────────────
# DSN は Render 環境変数 SENTRY_DSN_BACKEND で注入 (未設定 or DEBUG=True なら skip)
# 【FEAT-536 Phase 0-a (2026-08-28)】environment を env 変数化した。旧実装は
# `'production'` のハードコードで、**dev を `DEBUG=False` にした瞬間に dev の
# エラーが prod のストリームへ混ざる**構造だった (dev は 2026-08-28 まで
# `DEBUG=True` だったため Sentry 自体が init されず、表面化していなかった)。
# Render の dev サービスには `SENTRY_ENVIRONMENT=dev` を設定すること。
# send_default_pii=False: IP / user info を Sentry に送らない (プライバシーポリシー整合)
# traces_sample_rate=0.1: 10% のトランザクションをパフォーマンス計測に使う
_SENTRY_DSN = os.environ.get('SENTRY_DSN_BACKEND', '')
if _SENTRY_DSN and not DEBUG:
    import sentry_sdk
    from sentry_sdk.integrations.django import DjangoIntegration
    sentry_sdk.init(
        dsn=_SENTRY_DSN,
        integrations=[DjangoIntegration()],
        traces_sample_rate=0.1,
        environment=os.environ.get('SENTRY_ENVIRONMENT', 'production'),
        send_default_pii=False,
    )
