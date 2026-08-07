"""【2026-06-29】Django 管理画面 メール OTP MFA の view 実装。

Endpoints:
    GET  /admin/mfa/challenge/  : OTP コード生成 + メール送信 + /admin/mfa/verify/ へ redirect
    POST /admin/mfa/challenge/  : 「再送信」ボタン (同経路、rate-limit 60 秒)
    GET  /admin/mfa/verify/     : 6 桁コード入力フォーム表示
    POST /admin/mfa/verify/     : コード検証 → 成功で session 設定 + /admin/ へ redirect

セキュリティ仕様:
    - OTP 有効期限: 10 分
    - 試行回数上限: 5 回 (超過で used=True、再送信が必要)
    - 再送信 throttle: 同 user で前 challenge から 60 秒以内は新規発行禁止
    - 旧 active challenge は新規発行時に全 used=True で無効化 (旧コード使い回し防止)
    - 検証成功時に request.session.cycle_key() で session fixation 対策
    - メール送信は Resend HTTP API (FEAT-395 と同経路、SMTP は使わない)

【Pre-mortem 対策】
    - メール送信失敗時: ユーザーに 500 ではなく verify ページに error message を返す
      (challenge レコードは作成されてしまうが、used=True で破棄して次回発行を促す)
    - Resend API キー未設定 (RESEND_API_KEY=''): メール送信は no-op + verify ページに警告表示
      → ローカル開発時の早期検出 (本番では Render dashboard で必ず設定済の前提)
    - csrf_exempt は使わない (Django 標準 CSRF middleware が保護)
    - 他ユーザーの challenge を参照しない (filter(user=request.user) で厳密に絞る)
"""
import logging
import os
import secrets
from datetime import timedelta

from django.conf import settings
from django.contrib.auth.decorators import login_required, user_passes_test
from django.http import HttpResponseRedirect
from django.shortcuts import redirect, render
from django.urls import reverse
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from ..middleware.admin_mfa import MFA_SESSION_KEY
from ..models import AdminMFAChallenge

_logger = logging.getLogger(__name__)

# OTP 有効期限 (分)
_OTP_TTL_MINUTES = 10
# 試行回数上限 (超過で used=True 強制)
_OTP_MAX_ATTEMPTS = 5
# 再送信 throttle (秒、直前の active challenge があるとき新規発行禁止)
_OTP_RESEND_THROTTLE_SECONDS = 60


def _admin_url_prefix() -> str:
    """config/urls.py と同じ ADMIN_URL 環境変数から admin パス prefix を組み立て。"""
    return '/' + os.environ.get('ADMIN_URL', 'admin/')


def _generate_otp_code() -> str:
    """6 桁の OTP コードを暗号論的に安全な乱数で生成。

    secrets.randbelow は CSPRNG ベースのため、_random.randint より安全。
    """
    return f'{secrets.randbelow(1_000_000):06d}'


def _send_otp_email(user, code: str) -> bool:
    """Resend HTTP API で OTP メール送信。成功 True、失敗 False。

    health.py:ContactView の FEAT-395 パターンと同経路 (SMTP は使わない)。
    本番 (Render) では RESEND_API_KEY 環境変数で API キーが設定されている前提。
    """
    api_key = getattr(settings, 'RESEND_API_KEY', '')
    if not api_key:
        # ローカル開発で未設定の場合: console 出力で代替 (DEBUG=True のみ想定)
        _logger.warning(
            '[admin_mfa] RESEND_API_KEY 未設定のため OTP メール送信を skip: '
            'user=%s code=%s (本番では Render dashboard で設定すること)',
            user.email, code,
        )
        return False

    try:
        import resend
        resend.api_key = api_key
        # サビ口調 (CLAUDE.md): 〜です/〜ます、感嘆符なし、🪶 マーカー
        html_body = (
            f'<p>Sabiowl 管理画面の認証コードをお届けします 🪶</p>'
            f'<p style="font-size: 28px; font-weight: bold; letter-spacing: 4px;">{code}</p>'
            f'<p>10 分以内に管理画面の認証ページにご入力ください。</p>'
            f'<p>心当たりがない場合は本メールを破棄してください。'
            f'第三者が不正にログインを試みている可能性があります。</p>'
            f'<hr>'
            f'<p style="font-size: 11px; color: #888;">'
            f'Sabiowl Admin Security (本メールは自動送信です)'
            f'</p>'
        )
        resend.Emails.send({
            'from':    settings.DEFAULT_FROM_EMAIL,
            'to':      [user.email],
            'subject': '【Sabiowl 管理画面】認証コードをお届けします',
            'html':    html_body,
        })
        return True
    except Exception as e:
        # メール送信失敗は最重要ログ (admin にログインできないと運用が止まる)
        _logger.error(
            '[admin_mfa] Resend OTP メール送信失敗: user=%s error=%s',
            user.email, e,
        )
        return False


@login_required
@user_passes_test(lambda u: u.is_staff)
@require_http_methods(['GET', 'POST'])
def admin_mfa_challenge(request):
    """OTP コード生成 + メール送信 + verify ページへ redirect。

    GET / POST いずれも同経路 (POST は「再送信」ボタンから叩かれる、rate-limit あり)。
    """
    user = request.user
    now = timezone.now()

    # 再送信 throttle: 60 秒以内に発行された active challenge があれば skip
    recent_active = AdminMFAChallenge.objects.filter(
        user=user, used=False,
        created_at__gte=now - timedelta(seconds=_OTP_RESEND_THROTTLE_SECONDS),
    ).first()
    if recent_active:
        # 既存 challenge が有効、verify ページに送る (新規発行なし)
        return redirect(f'{_admin_url_prefix()}mfa/verify/')

    # 旧 active challenge を全 used=True で無効化 (使い回し防止)
    AdminMFAChallenge.objects.filter(user=user, used=False).update(used=True)

    # 新 challenge 生成 + メール送信
    code = _generate_otp_code()
    challenge = AdminMFAChallenge.objects.create(user=user, code=code)
    sent = _send_otp_email(user, code)

    if not sent and not settings.DEBUG:
        # 本番でメール送信失敗 → challenge を used=True にして verify ページにエラー表示
        challenge.used = True
        challenge.save(update_fields=['used'])
        return render(request, 'admin/mfa/verify.html', {
            'error':         'メール送信に失敗しました。しばらく時間をおいてから再度お試しください 🪶',
            'admin_url':     _admin_url_prefix(),
            'resend_path':   f'{_admin_url_prefix()}mfa/challenge/',
            'verify_path':   f'{_admin_url_prefix()}mfa/verify/',
        })

    return redirect(f'{_admin_url_prefix()}mfa/verify/')


@login_required
@user_passes_test(lambda u: u.is_staff)
@require_http_methods(['GET', 'POST'])
def admin_mfa_verify(request):
    """OTP コード入力 + 検証 + session 設定。

    GET: 入力フォーム表示
    POST: 検証 → 成功で /admin/ へ redirect、失敗で再入力画面 + エラー表示
    """
    user = request.user
    now = timezone.now()
    admin_prefix = _admin_url_prefix()

    if request.method == 'GET':
        # 直接アクセスされた場合: active challenge があるか確認、なければ challenge へ送り直し
        active = AdminMFAChallenge.objects.filter(
            user=user, used=False,
            created_at__gte=now - timedelta(minutes=_OTP_TTL_MINUTES),
        ).first()
        if not active:
            return redirect(f'{admin_prefix}mfa/challenge/')
        return render(request, 'admin/mfa/verify.html', {
            'admin_url':     admin_prefix,
            'resend_path':   f'{admin_prefix}mfa/challenge/',
            'verify_path':   f'{admin_prefix}mfa/verify/',
            'user_email':    user.email,
        })

    # POST: 検証
    code_input = (request.POST.get('code') or '').strip()
    if not code_input or not code_input.isdigit() or len(code_input) != 6:
        return render(request, 'admin/mfa/verify.html', {
            'error':         '6 桁の数字を入力してください 🪶',
            'admin_url':     admin_prefix,
            'resend_path':   f'{admin_prefix}mfa/challenge/',
            'verify_path':   f'{admin_prefix}mfa/verify/',
            'user_email':    user.email,
        })

    # 期限内 + 未使用の最新 challenge を取得
    challenge = AdminMFAChallenge.objects.filter(
        user=user, used=False,
        created_at__gte=now - timedelta(minutes=_OTP_TTL_MINUTES),
    ).order_by('-created_at').first()

    if not challenge:
        return render(request, 'admin/mfa/verify.html', {
            'error':         'コードの有効期限が切れました。再送信してください 🪶',
            'admin_url':     admin_prefix,
            'resend_path':   f'{admin_prefix}mfa/challenge/',
            'verify_path':   f'{admin_prefix}mfa/verify/',
            'user_email':    user.email,
        })

    # brute-force ガード
    if challenge.attempt_count >= _OTP_MAX_ATTEMPTS:
        challenge.used = True
        challenge.save(update_fields=['used'])
        return render(request, 'admin/mfa/verify.html', {
            'error':         '試行回数の上限に達しました。再送信してください 🪶',
            'admin_url':     admin_prefix,
            'resend_path':   f'{admin_prefix}mfa/challenge/',
            'verify_path':   f'{admin_prefix}mfa/verify/',
            'user_email':    user.email,
        })

    # 比較は secrets.compare_digest で timing attack 耐性 (本ケースは 6 桁数字なので
    # 実害は小さいが、業界標準パターンとして採用)
    if not secrets.compare_digest(challenge.code, code_input):
        challenge.attempt_count += 1
        challenge.save(update_fields=['attempt_count'])
        remaining = _OTP_MAX_ATTEMPTS - challenge.attempt_count
        return render(request, 'admin/mfa/verify.html', {
            'error':         f'コードが一致しません (残り {remaining} 回) 🪶',
            'admin_url':     admin_prefix,
            'resend_path':   f'{admin_prefix}mfa/challenge/',
            'verify_path':   f'{admin_prefix}mfa/verify/',
            'user_email':    user.email,
        })

    # 検証成功: used=True + session 設定 + session rotation
    challenge.used = True
    challenge.save(update_fields=['used'])
    request.session[MFA_SESSION_KEY] = now.isoformat()
    request.session.cycle_key()  # session fixation 対策
    _logger.info('[admin_mfa] OTP verified: user=%s', user.email)
    return HttpResponseRedirect(admin_prefix)
