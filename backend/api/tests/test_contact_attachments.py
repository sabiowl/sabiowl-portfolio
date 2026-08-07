"""
【FEAT-366 (2026-05-27)】お問い合わせ添付画像の契約テスト。

検証対象 (5 シナリオ):
    1. 添付ゼロ (旧 JSON-only クライアント互換) → 200 OK、メール添付ゼロ
    2. 添付 1 枚 (JPEG) → 200 OK、メール添付 1 枚
    3. 添付 5 枚 (PNG ミックス) → 200 OK、メール添付 5 枚
    4. 添付 6 枚 → 400 「画像は 5 枚までです」
    5. 1 枚あたり 2MB 超 → 400 「画像 N のサイズが大きすぎます」
    6. 非画像 MIME (text/plain) → 400 「対応していない形式です」

PM 確定値 (PM 長期設計セッション 2026-05-27):
- Q1: 1 枚 2MB / 5 枚合計 10MB
- Q2: JPEG / PNG / WebP のみ (HEIC は Flutter image_picker が自動変換)
- Q3: メール添付のみ、Backend 永続化なし
"""
from unittest.mock import patch

from django.core import mail
from django.core.cache import cache
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import override_settings
from rest_framework.test import APITestCase

# Django テスト時はメール送信を locmem backend にして mail.outbox で確認。
# ContactView は `throttle_classes = [ScopedRateThrottle] + throttle_scope='contact'`
# (3/hour) でクラス側に固定指定があるため、DEFAULT_THROTTLE_RATES だけでは無効化できない。
# 各テストで cache.clear() するのが堅実 (test_habit_count_view.py と同パターン)。
_TEST_OVERRIDE = {
    'EMAIL_BACKEND': 'django.core.mail.backends.locmem.EmailBackend',
    # 【2026-07-25 P3 #1-c】FEAT-395 で Resend HTTP SDK 化以降、health.py:373 で
    # RESEND_API_KEY 未設定を early 500 で検出するようになった。テスト時は
    # ダミー値を注入する (実際の送信は locmem backend が受けるため API は叩かない)。
    'RESEND_API_KEY': 'test-key-dummy',
    'REST_FRAMEWORK': {
        'DEFAULT_AUTHENTICATION_CLASSES': [],
        'DEFAULT_PERMISSION_CLASSES': [
            'rest_framework.permissions.AllowAny',
        ],
        'DEFAULT_THROTTLE_CLASSES': [],
        # contact scope を test 時のみ無限化 (3/hour → null = throttle 評価で fall-through)
        'DEFAULT_THROTTLE_RATES': {
            'contact': None,
        },
    },
}


# 最小 PNG ファイル (1x1 ピクセル黒、67 bytes)。テストで MIME 検出に渡す。
_MIN_PNG = bytes([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
])


@override_settings(**_TEST_OVERRIDE)
class ContactAttachmentTestCase(APITestCase):
    """FEAT-366 添付画像受信 + メール attach の契約テスト 6 シナリオ。"""

    def setUp(self):
        cache.clear()    # throttle カウンタクリア (3/hour 上限突破防止)
        mail.outbox = [] # テスト毎にクリア
        # 【2026-07-25 P3 #1-c】FEAT-395 で Resend HTTP SDK 化以降、EMAIL_BACKEND=locmem
        # をバイパスして resend.Emails.send() が呼ばれるため、直接 mock する必要がある。
        # mock は locmem backend に手動で追加して mail.outbox の従来 assertion を維持する。
        self._resend_patcher = patch('resend.Emails.send')
        mock_send = self._resend_patcher.start()

        def _fake_send(params: dict) -> dict:
            attachments = params.get('attachments') or []
            msg = mail.EmailMessage(
                subject=params.get('subject', ''),
                body=params.get('text', ''),
                from_email=params.get('from', ''),
                to=params.get('to', []),
            )
            for a in attachments:
                content = a.get('content', b'')
                if isinstance(content, list):
                    content = bytes(content)
                msg.attach(a.get('filename', 'attachment'), content, a.get('content_type', ''))
            msg.send()
            return {'id': 'mock-email-id'}
        mock_send.side_effect = _fake_send

    def tearDown(self):
        self._resend_patcher.stop()

    def _make_upload(self, name='shot.png', size=None, content_type='image/png'):
        """テスト用 SimpleUploadedFile を生成。size 指定で任意 byte 数の dummy も可。"""
        content = _MIN_PNG if size is None else b'\x00' * size
        return SimpleUploadedFile(name, content, content_type=content_type)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: 添付ゼロ (旧クライアント互換)
    # ─────────────────────────────────────────────────────────────────

    def test_no_attachment_still_works(self):
        """添付ゼロでも従来通り 200 OK、メール送信成功、添付件数ゼロ。"""
        resp = self.client.post('/api/contact/', data={
            'category': 'bug',
            'title':    'テスト',
            'body':     'バグ報告本文',
            'email':    'user@example.com',
        }, format='multipart')
        self.assertEqual(resp.status_code, 200, resp.content)
        self.assertEqual(resp.json(), {'status': 'sent'})
        self.assertEqual(len(mail.outbox), 1)
        self.assertEqual(len(mail.outbox[0].attachments), 0)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: 添付 1 枚 (JPEG)
    # ─────────────────────────────────────────────────────────────────

    def test_single_attachment_jpeg_ok(self):
        """添付 1 枚 (image/jpeg) で 200 OK、メールに 1 枚添付される。"""
        resp = self.client.post('/api/contact/', data={
            'category':    'bug',
            'title':       'スクショ 1 枚',
            'body':        '画像つき',
            'attachments': self._make_upload(name='bug.jpg', content_type='image/jpeg'),
        }, format='multipart')
        self.assertEqual(resp.status_code, 200, resp.content)
        self.assertEqual(len(mail.outbox), 1)
        self.assertEqual(len(mail.outbox[0].attachments), 1)
        attached_name, _, mimetype = mail.outbox[0].attachments[0]
        self.assertEqual(attached_name, 'bug.jpg')
        self.assertEqual(mimetype, 'image/jpeg')

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: 添付 5 枚 (PNG/WebP ミックス)
    # ─────────────────────────────────────────────────────────────────

    def test_five_attachments_mixed_mime_ok(self):
        """5 枚 (PNG × 4 + WebP × 1) で 200 OK、メールに 5 枚添付される。"""
        resp = self.client.post('/api/contact/', data={
            'category':    'feature',
            'title':       'スクショ 5 枚',
            'body':        '複数添付',
            'attachments': [
                self._make_upload(name='a.png', content_type='image/png'),
                self._make_upload(name='b.png', content_type='image/png'),
                self._make_upload(name='c.png', content_type='image/png'),
                self._make_upload(name='d.png', content_type='image/png'),
                self._make_upload(name='e.webp', content_type='image/webp'),
            ],
        }, format='multipart')
        self.assertEqual(resp.status_code, 200, resp.content)
        self.assertEqual(len(mail.outbox), 1)
        self.assertEqual(len(mail.outbox[0].attachments), 5)
        self.assertIn('添付画像: 5 枚', mail.outbox[0].body)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 4: 添付 6 枚 → 400
    # ─────────────────────────────────────────────────────────────────

    def test_six_attachments_rejected(self):
        """6 枚目で 400、サビ口調エラーメッセージ。"""
        resp = self.client.post('/api/contact/', data={
            'category':    'bug',
            'body':        '本文',
            'attachments': [
                self._make_upload(name=f'{i}.png') for i in range(6)
            ],
        }, format='multipart')
        self.assertEqual(resp.status_code, 400)
        # 【FEAT-475 Phase 3c (2026-07-04)】新形式 {'error': {'code', 'message', 'fields'}}
        body = resp.json()
        self.assertEqual(body['error']['code'], 'contact_validation_failed')
        self.assertIn('attachments', body['error']['fields'])
        self.assertIn('5 枚まで', body['error']['fields']['attachments'])
        self.assertEqual(len(mail.outbox), 0, '400 時にメール送信されないこと')

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 5: 1 枚 2MB 超 → 400
    # ─────────────────────────────────────────────────────────────────

    def test_oversized_attachment_rejected(self):
        """2MB を超える画像は 400、エラーメッセージにサイズ上限明示。"""
        # 2MB + 1 byte の dummy ファイル
        oversized = self._make_upload(
            name='huge.png',
            size=(2 * 1024 * 1024) + 1,
            content_type='image/png',
        )
        resp = self.client.post('/api/contact/', data={
            'category':    'bug',
            'body':        '本文',
            'attachments': oversized,
        }, format='multipart')
        self.assertEqual(resp.status_code, 400)
        # 【FEAT-475 Phase 3c (2026-07-04)】新形式
        body = resp.json()
        self.assertEqual(body['error']['code'], 'contact_validation_failed')
        self.assertIn('attachment_0', body['error']['fields'])
        self.assertIn('2MB', body['error']['fields']['attachment_0'])
        self.assertEqual(len(mail.outbox), 0)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 6: 非画像 MIME → 400
    # ─────────────────────────────────────────────────────────────────

    def test_non_image_mime_rejected(self):
        """text/plain 等の非画像 MIME は 400。"""
        text_file = SimpleUploadedFile(
            'notes.txt', b'just a text file', content_type='text/plain',
        )
        resp = self.client.post('/api/contact/', data={
            'category':    'bug',
            'body':        '本文',
            'attachments': text_file,
        }, format='multipart')
        self.assertEqual(resp.status_code, 400)
        # 【FEAT-475 Phase 3c (2026-07-04)】新形式
        body = resp.json()
        self.assertEqual(body['error']['code'], 'contact_validation_failed')
        self.assertIn('attachment_0', body['error']['fields'])
        self.assertIn('対応していない形式', body['error']['fields']['attachment_0'])
        self.assertEqual(len(mail.outbox), 0)
