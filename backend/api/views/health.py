import html as _html
import logging
import os as _os
from datetime import datetime as _datetime

from rest_framework import status
from rest_framework.parsers import MultiPartParser, FormParser, JSONParser
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView

from django.conf import settings as django_settings
from django.core.exceptions import ValidationError as DjangoValidationError
from django.core.validators import validate_email

from ._error_helpers import error_response  # 【FEAT-475 Phase 3c】新形式統一

_logger = logging.getLogger(__name__)

# 【FEAT-366 (2026-05-27)】お問い合わせ添付画像の制約定数。
# PM 長期設計セッション 2026-05-27 確定 (Q1 案 B / Q2 案 Z / Q3 案 P / Q4 案 O):
#   - 最大 5 枚 / 1 枚 2MB / 5 枚合計 10MB (Resend / Gmail 添付 25MB に余裕)
#   - MIME は JPEG / PNG / WebP のみ受け入れ (HEIC は Flutter image_picker が自動変換)
#   - メール添付のみ、Backend に永続化なし (Q3 案 P、Render 無料プラン整合 + プライバシー観点)
CONTACT_ATTACHMENT_MAX_COUNT = 5
CONTACT_ATTACHMENT_MAX_BYTES = 2 * 1024 * 1024  # 2MB
# 【SEC-15 M-02 (2026-05-30)】FEAT-366 docstring が謳う「5 枚合計 10MB」を強制する
# 合計サイズ上限。per-file 2MB だけだと 5 × 2MB = 10MB ピッタリの payload が
# 検証なしで Resend SMTP に到達してしまうため、合計サイズもサーバー側で二重防御。
# Resend / Gmail 添付 25MB 上限と整合 + DoS リクエスト遮断の defense in depth。
CONTACT_ATTACHMENT_MAX_TOTAL_BYTES = 10 * 1024 * 1024  # 10MB
CONTACT_ATTACHMENT_ALLOWED_MIME = {
    'image/jpeg',
    'image/png',
    'image/webp',
}


class HealthCheckView(APIView):
    """基本ヘルスチェック + DB 接続 + スキーマ整合性の 3 段確認。

    【2026-07-07】従来の「プロセス生存」だけの返却を拡張し、以下 2 追加チェックで
    Backend の実際の健全性を判定する。Mobile 側の `BootGate` widget が本 endpoint
    を叩いて 503 を受け取った場合、`placeholderOn` maintenance overlay に自動遷移
    することで migration 由来の schema drift 等の障害をユーザーに正しく通知する。

    Checks:
        1. `process`: 本 view に処理が到達すれば True (常に true)
        2. `db`: `SELECT 1` で DB 接続の生存確認
        3. `schema`: `PlayerProfile.objects.first()` で ORM 経由の SELECT を発行
           - Django ORM は model の field list で SELECT を組み立てるため、
             DB 側に model と不整合 (欠損 column 等) があれば ProgrammingError
           - 空テーブルなら None を返すが例外は投げない
           - migration 反映漏れ / drift の検知精度が最も高いチェック

    Response:
        - 全て OK: 200 `{"status": "ok", "checks": {...}, "message": ...}`
        - DB 障害: 503 `{"status": "degraded", "checks": {"db": false, ...}}`
        - Schema drift: 503 `{"status": "degraded", "checks": {"schema": false, ...}}`

    permission_classes = [AllowAny]: BootGate が認証前に叩くため必須。
    """
    permission_classes = [AllowAny]

    def get(self, request):
        checks = {'process': True, 'db': False, 'schema': False}

        # ── Step 1: DB 接続の生存確認 ────────────────────────────
        try:
            from django.db import connection
            with connection.cursor() as cursor:
                cursor.execute('SELECT 1')
            checks['db'] = True
        except Exception as exc:  # noqa: BLE001
            _logger.error('[HealthCheck] DB SELECT 1 failed: %s', exc)
            return Response(
                {
                    'status': 'degraded',
                    'checks': checks,
                    'reason': f'db: {str(exc)[:200]}',
                    'message': 'システムに手当てをしております 🪶',
                },
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )

        # ── Step 2: schema alignment 確認 (migration drift 検知) ────
        # PlayerProfile.objects.first() は Django ORM が全 model field 列で
        # SELECT を組み立てるため、DB 側に不整合 (欠損 column 等) があれば
        # ProgrammingError を throw する。空テーブルでも None を返して成功扱い。
        try:
            # PlayerProfile は 大半の migration が touch するため schema drift の
            # 露出面が最も広い。他の中枢モデル (Habit / TimelineEvent 等) でも
            # 良いが、選択肢を絞る意味で PlayerProfile 1 個に集約。
            from api.models import PlayerProfile
            _ = PlayerProfile.objects.first()
            checks['schema'] = True
        except Exception as exc:  # noqa: BLE001
            _logger.error('[HealthCheck] PlayerProfile.first() failed: %s', exc)
            return Response(
                {
                    'status': 'degraded',
                    'checks': checks,
                    'reason': f'schema: {str(exc)[:200]}',
                    'message': 'システムに手当てをしております 🪶',
                },
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )

        return Response({
            'status':  'ok',
            'checks':  checks,
            'message': 'Sabiowl API is running',
        })


class ContactView(APIView):
    """
    POST /api/contact/
    お問い合わせフォームからメールを support@sabiowl.com に送信する。

    【FEAT-366 (2026-05-27)】スクリーンショット添付 (最大 5 枚 / 2MB / 枚 / JPEG/PNG/WebP)
    対応。multipart/form-data 経由で受信し、EmailMultiAlternatives.attach() で
    メール添付して送信、Backend には永続化しない (Q3 案 P)。
    """
    permission_classes = [AllowAny]
    parser_classes     = [MultiPartParser, FormParser, JSONParser]  # FEAT-366: multipart 受信対応
    throttle_classes   = [ScopedRateThrottle]
    throttle_scope     = 'contact'

    CATEGORY_LABELS = {
        'bug':     'バグ・不具合の報告',
        'feature': '機能のご要望',
        'account': 'アカウントについて',
        'other':   'その他',
    }

    CATEGORY_EMOJIS = {
        'bug':     '🐛',
        'feature': '✨',
        'account': '👤',
        'other':   '💬',
    }

    def _build_auto_reply_html(self, category_label, category_emoji, title, body, received_at):
        body_escaped = _html.escape(body).replace('\n', '<br>')

        return f"""<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>お問い合わせを受け付けました</title>
</head>
<body style="margin:0;padding:0;background:#f1efe8;font-family:'Helvetica Neue',Arial,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#f1efe8;padding:32px 16px;">
  <tr><td align="center">
  <table width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 4px 32px rgba(0,0,0,0.10);">

    <!-- ヘッダーバナー -->
    <tr>
      <td style="background:linear-gradient(135deg,#1e1b4b 0%,#534AB7 60%,#6c5ce7 100%);padding:28px 32px 24px;text-align:center;">
        <div style="font-size:22px;font-weight:900;color:#ffffff;letter-spacing:-0.02em;margin-bottom:4px;">Sabiowl</div>
        <div style="font-size:11px;color:rgba(255,255,255,0.6);letter-spacing:0.12em;text-transform:uppercase;">Support</div>
      </td>
    </tr>

    <!-- 本文エリア -->
    <tr>
      <td style="padding:28px 32px;">
        <p style="font-size:15px;color:#2C2B28;line-height:1.8;margin:0 0 20px;">
          お問い合わせいただきありがとうございます。<br>
          Sabiowl サポートチームです。<br><br>
          以下の内容でお問い合わせを受け付けました。<br>
          内容を確認のうえ、<strong style="color:#534AB7;">2〜3営業日以内</strong>にご返信いたします。
        </p>

        <table width="100%" cellpadding="0" cellspacing="0" style="background:#f0f9ff;border:1px solid #bae6fd;border-radius:12px;margin-bottom:20px;">
          <tr>
            <td style="padding:16px 20px;">
              <table cellpadding="0" cellspacing="0">
                <tr>
                  <td style="font-size:24px;vertical-align:top;padding-right:12px;padding-top:2px;">✅</td>
                  <td>
                    <div style="font-size:14px;font-weight:700;color:#0369a1;margin-bottom:4px;">お問い合わせを受け付けました</div>
                    <div style="font-size:13px;color:#0284c7;line-height:1.5;">担当者が内容を確認します。しばらくお待ちください。</div>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>

        <table width="100%" cellpadding="0" cellspacing="0" style="border:1.5px solid #E8E6DE;border-radius:12px;margin-bottom:8px;overflow:hidden;">
          <tr>
            <td style="background:#f5f4f0;border-bottom:1px solid #E8E6DE;padding:10px 16px;font-size:11px;font-weight:700;color:#888780;letter-spacing:0.06em;text-transform:uppercase;">
              📋 お問い合わせ内容
            </td>
          </tr>
          <tr>
            <td style="padding:16px;">
              <table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:12px;">
                <tr>
                  <td style="font-size:11px;font-weight:700;color:#888780;width:70px;vertical-align:top;padding-top:4px;">カテゴリ</td>
                  <td>
                    <span style="display:inline-block;background:#ede9ff;color:#534AB7;font-size:12px;font-weight:700;padding:3px 12px;border-radius:20px;">
                      {category_emoji} {category_label}
                    </span>
                  </td>
                </tr>
              </table>
              <hr style="border:none;border-top:1px solid #E8E6DE;margin:0 0 12px;">
              <table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:12px;">
                <tr>
                  <td style="font-size:11px;font-weight:700;color:#888780;width:70px;vertical-align:top;padding-top:2px;">タイトル</td>
                  <td style="font-size:14px;color:#2C2B28;line-height:1.6;">{_html.escape(title)}</td>
                </tr>
              </table>
              <hr style="border:none;border-top:1px solid #E8E6DE;margin:0 0 12px;">
              <table width="100%" cellpadding="0" cellspacing="0">
                <tr>
                  <td style="font-size:11px;font-weight:700;color:#888780;width:70px;vertical-align:top;padding-top:2px;">内容</td>
                  <td>
                    <div style="font-size:13px;color:#4a4845;line-height:1.8;background:#faf9f6;border-radius:8px;padding:12px;">
                      {body_escaped}
                    </div>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>

        <p style="font-size:11px;color:#B8B5A8;text-align:right;margin:0 0 20px;">受付日時：{received_at}</p>

        <div style="border-top:1px solid #E8E6DE;padding-top:20px;font-size:14px;color:#4a4845;line-height:1.8;">
          引き続き Sabiowl をよろしくお願いいたします。<br><br>
          Sabiowl サポートチーム<br>
          <span style="color:#534AB7;font-weight:600;">support@sabiowl.com</span>
        </div>
      </td>
    </tr>

    <!-- フッター -->
    <tr>
      <td style="background:#1e1b4b;padding:20px 32px;text-align:center;">
        <div style="font-size:16px;font-weight:800;color:#ffffff;margin-bottom:8px;">Sabiowl</div>
        <div style="font-size:11px;color:rgba(255,255,255,0.4);line-height:1.6;">
          このメールは Sabiowl お問い合わせフォームからの自動送信です。<br>
          心当たりのない場合は、このメールを無視してください。
        </div>
      </td>
    </tr>

  </table>
  </td></tr>
</table>
</body>
</html>"""

    def post(self, request):
        # 【FEAT-395 (2026-05-31)】Resend HTTP API SDK に切替 (SMTP timeout 構造解消)
        # 旧: EmailMultiAlternatives (SMTP via smtp.resend.com:587) は Render 環境で
        # TCP 接続 timeout 多発 (BUG-40/43/49/51 系の延長、FEAT-394 Neon 移行後の検証で再現)
        # 新: resend.Emails.send (HTTPS POST) で構造的解消
        import resend

        category = (request.data.get('category') or '').strip()
        title    = (request.data.get('title')    or '').strip()
        # 'body' と 'content' の両方を受け入れる（Flutter 旧バージョン互換）
        body     = (
            request.data.get('body') or request.data.get('content') or ''
        ).strip()
        email    = (request.data.get('email')    or '').strip()

        if email:
            try:
                validate_email(email)
            except DjangoValidationError:
                # 【FEAT-475 Phase 3c (2026-07-04)】旧 {'errors': {'field': 'msg'}} 形式を
                # 新形式 {'error': {'code', 'message', 'fields'}} に統一。
                return error_response(
                    code='contact_invalid_email',
                    message='メールアドレスの形式が正しくありません 🪶',
                    fields={'email': 'メールアドレスの形式が正しくありません'},
                    status=status.HTTP_400_BAD_REQUEST,
                )

        errors = {}
        if category not in self.CATEGORY_LABELS:
            errors['category'] = 'カテゴリを選択してください'
        # title は省略可能: 空の場合はカテゴリラベルで補完
        if not title:
            title = self.CATEGORY_LABELS.get(category, 'お問い合わせ')
        elif len(title) > 100:
            errors['title'] = '100文字以内で入力してください'
        if not body:
            errors['body'] = '内容を入力してください'
        elif len(body) > 2000:
            errors['body'] = '2000文字以内で入力してください'

        # 【FEAT-366】添付画像バリデーション (枚数 / サイズ / MIME)。
        # multipart/form-data の field name は 'attachments' (Flutter 側 social_service と同期)。
        # `getlist` は field 不在時に空 list を返す = 旧 JSON-only クライアントとの後方互換。
        attachments = request.FILES.getlist('attachments') if request.FILES else []
        if len(attachments) > CONTACT_ATTACHMENT_MAX_COUNT:
            errors['attachments'] = (
                f'画像は {CONTACT_ATTACHMENT_MAX_COUNT} 枚までです'
                f' (今 {len(attachments)} 枚)'
            )
        for idx, f in enumerate(attachments):
            # サイズチェック (Flutter 側でも上限抑制するが、Backend で二重防御)
            if f.size > CONTACT_ATTACHMENT_MAX_BYTES:
                errors[f'attachment_{idx}'] = (
                    f'画像 {idx + 1} のサイズが大きすぎます '
                    f'(上限 {CONTACT_ATTACHMENT_MAX_BYTES // (1024 * 1024)}MB)'
                )
                break
            # MIME チェック (content_type は client から送られる、念のため拡張子も確認推奨だが
            # Q2 案 Z で Flutter image_picker が JPEG/PNG しか出力しない前提のため簡素)
            if f.content_type not in CONTACT_ATTACHMENT_ALLOWED_MIME:
                errors[f'attachment_{idx}'] = (
                    f'画像 {idx + 1} は対応していない形式です '
                    f'(JPEG / PNG / WebP のみ)'
                )
                break

        # 【SEC-15 M-02 (2026-05-30)】合計サイズ上限の二重防御。
        # per-file 2MB だけだと 5 × 2MB = 10MB ピッタリの payload が通る経路があるため、
        # 合計サイズもサーバー側で強制する。Flutter 側で先に絞られている前提だが、
        # 直接 POST 経路 (curl 等) からの DoS リクエスト遮断に有効。
        # per-file エラーが既に発生している場合はそちらを優先する (else ガードで二重表示防止)。
        if not errors and attachments:
            total_bytes = sum(f.size for f in attachments)
            if total_bytes > CONTACT_ATTACHMENT_MAX_TOTAL_BYTES:
                errors['attachments_total'] = (
                    f'添付ファイルの合計サイズが大きすぎます '
                    f'(上限 {CONTACT_ATTACHMENT_MAX_TOTAL_BYTES // (1024 * 1024)}MB)'
                )

        if errors:
            # 【FEAT-475 Phase 3c (2026-07-04)】旧 {'errors': {...}} を新形式に。
            # 複数のフィールドエラーは fields dict でそのまま渡す。
            return error_response(
                code='contact_validation_failed',
                message='入力内容をご確認ください 🪶',
                fields=errors,
                status=status.HTTP_400_BAD_REQUEST,
            )

        category_label = self.CATEGORY_LABELS[category]
        category_emoji = self.CATEGORY_EMOJIS[category]
        _now        = _datetime.now()
        received_at = f"{_now.year}年{_now.month}月{_now.day}日 {_now.strftime('%H:%M')}"

        # 【FEAT-366】添付ファイル件数を support_body に表示 (受信者向け、何枚あったか即視認)
        attachment_summary = (
            f"\n添付画像: {len(attachments)} 枚\n" if attachments else ""
        )
        support_body = (
            f"カテゴリ: {category_emoji} {category_label}\n"
            f"タイトル: {title}\n"
            f"返信先: {email if email else '（未入力）'}\n"
            f"受付日時: {received_at}"
            f"{attachment_summary}\n"
            f"{'─' * 40}\n"
            f"{body}\n"
            f"{'─' * 40}\n\n"
            f"※ Sabiowl アプリのお問い合わせフォームから送信されました。"
        )
        # 【FEAT-395 (2026-05-31)】Resend HTTP API SDK で送信。SMTP timeout 解消。
        # RESEND_API_KEY 未設定時の早期失敗 (deploy 時の env var 設定漏れを 500 で検出)。
        if not django_settings.RESEND_API_KEY:
            _logger.error('[ContactView] RESEND_API_KEY 未設定 (Render env var 確認必要)')
            return error_response(
                code='contact_email_not_configured',
                message='メール送信設定が未完了です。少し時間をおいてお試しください 🪶',
                status=status.HTTP_500_INTERNAL_SERVER_ERROR,
            )
        resend.api_key = django_settings.RESEND_API_KEY

        # 【FEAT-395 hotfix (2026-05-31)】Resend Python SDK の attachments format に整合。
        # 公式 example (https://github.com/resend/resend-python/blob/main/examples/with_attachments.py)
        # 通り、`content` は list(bytes) (int の list)、`content_type` を明示指定。
        # 旧 base64 string 形式は API docs 上は許容されるが Python SDK では list(bytes)
        # が正式 example、Resend Dashboard で添付が受信メーラー側で開けない症状を解消。
        # ファイル名は basename でサニタイズ (path traversal 対策、旧実装踏襲)。
        attachments_payload = []
        for f in attachments:
            safe_name = _os.path.basename(f.name) or 'attachment'
            content_bytes = f.read()
            attachments_payload.append({
                'filename':     safe_name,
                'content':      list(content_bytes),
                'content_type': f.content_type,
            })

        params = {
            'from':    django_settings.DEFAULT_FROM_EMAIL,
            # 【FEAT-395 (2026-05-31)】宛先を環境変数化。
            # Resend ドメイン未認証時は運営 Gmail 等 (テストモード制約) に向けられ、
            # 認証完了後は support@sabiowl.com に戻せる (Render dashboard だけで切替可能)。
            'to':      [django_settings.CONTACT_TO_EMAIL],
            'subject': f'[Sabiowl お問い合わせ] {title}',
            'text':    support_body,
        }
        if email:
            params['reply_to'] = [email]
        if attachments_payload:
            params['attachments'] = attachments_payload

        try:
            resend.Emails.send(params)
        except Exception as exc:
            _logger.error('[ContactView] Resend HTTP API 送信失敗: %s', exc)
            return error_response(
                code='contact_email_send_failed',
                message='メールの送信に失敗しました。少し時間をおいてお試しください 🪶',
                status=status.HTTP_500_INTERNAL_SERVER_ERROR,
            )

        return Response({'status': 'sent'}, status=status.HTTP_200_OK)
