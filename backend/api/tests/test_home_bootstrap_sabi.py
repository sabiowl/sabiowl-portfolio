"""
【FEAT-484 (2026-07-08)】HomeBootstrapView への sabi_message 統合 契約テスト (3 件)。

検証観点:
  1. ?time_segment 未指定 → `sabi_message` キーが レスポンスに含まれない
  2. ?time_segment=morning → `sabi_message` が規定キーを含む dict として返る
  3. sabi_message の context は常に 'default'
"""
from django.test import TestCase
from django.contrib.auth.models import User
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from api.models import PlayerProfile


def _make_player(username: str):
    user = User.objects.create_user(username=username, password='pw')
    player, _ = PlayerProfile.objects.get_or_create(user=user)
    return user, player


class HomeBootstrapSabiMessageTest(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.user, self.player = _make_player('sabi_test_user')
        self.client.force_authenticate(user=self.user)

    # ─────────────────────────────────────────────────────────────────────────
    # テスト 1: time_segment 未指定 → sabi_message キーなし
    # ─────────────────────────────────────────────────────────────────────────
    def test_no_time_segment_excludes_sabi_message(self):
        """GET /api/home/ (time_segment なし) → レスポンスに sabi_message キーが存在しない。"""
        res = self.client.get('/api/home/')
        self.assertEqual(res.status_code, 200)
        self.assertNotIn('sabi_message', res.data)

    # ─────────────────────────────────────────────────────────────────────────
    # テスト 2: time_segment=morning → sabi_message が規定キーを持つ dict
    # ─────────────────────────────────────────────────────────────────────────
    def test_with_time_segment_includes_sabi_message(self):
        """GET /api/home/?time_segment=morning → sabi_message が message/is_rest_day/context/emotion を持つ。"""
        res = self.client.get('/api/home/', {'time_segment': 'morning'})
        self.assertEqual(res.status_code, 200)
        self.assertIn('sabi_message', res.data)

        sm = res.data['sabi_message']
        self.assertIn('message',     sm)
        self.assertIn('is_rest_day', sm)
        self.assertIn('context',     sm)
        self.assertIn('emotion',     sm)
        self.assertIsInstance(sm['message'], str)
        self.assertTrue(len(sm['message']) > 0)
        self.assertIsInstance(sm['is_rest_day'], bool)

    # ─────────────────────────────────────────────────────────────────────────
    # テスト 3: context は常に 'default'
    # ─────────────────────────────────────────────────────────────────────────
    def test_sabi_message_context_is_default(self):
        """sabi_message.context は bootstrap 経路では常に 'default'。"""
        res = self.client.get('/api/home/', {'time_segment': 'night'})
        self.assertEqual(res.status_code, 200)
        sm = res.data['sabi_message']
        self.assertEqual(sm['context'], 'default')
        self.assertEqual(sm['emotion'], 'normal')


class HomeBootstrapSabiLocaleTest(TestCase):
    """【FEAT-489 Phase 4 hotfix (2026-08-02)】bootstrap 経路の locale 反映。

    ## なぜ必要か

    サビセリフの取得経路は 2 本ある:

      - `GET /api/sabi/message/`  (SabiMessageView)
      - `GET /api/home/?time_segment=` (HomeBootstrapView、FEAT-484 で統合)

    ホーム画面は後者しか叩かない。FEAT-489 Phase 4 で locale 引数を足した際に
    **前者だけに足して後者が取り残され**、英語 UI でもホームのサビだけ日本語で
    返っていた (2026-08-02 実機 QA で検出)。

    経路が 2 本ある限り同じ事故が再発しうるので、「両経路が同じ文面を返す」を
    契約として固定する。

    ## 認証方法について

    `force_authenticate()` は使えない。DRF の強制認証は **APIView の
    initialize_request 内**で効くため、その手前で走る `I18nMiddleware` からは
    `request.user` が AnonymousUser に見え、`preferred_language` 経路が
    素通りしてしまう。実機と同じく Token を渡す。
    """

    def setUp(self):
        self.client = APIClient()
        self.user, self.player = _make_player('sabi_locale_user')
        token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token.key}')

    def _set_language(self, lang: str):
        state = self.player.settings
        state.preferred_language = lang
        state.save(update_fields=['preferred_language'])

    def test_en_bootstrap_uses_english_greeting(self):
        """preferred_language='en' → 時間帯挨拶が英語になる。

        セリフ本文は `SabiMessage.content_en` 次第で日本語に fallback しうるので、
        ここでは YAML 由来で決定的に英語になる**挨拶**だけを assert する
        (本文の英語化は master data 翻訳の投入で別途担保)。
        """
        self._set_language('en')
        res = self.client.get('/api/home/', {'time_segment': 'morning'})
        self.assertEqual(res.status_code, 200)
        self.assertTrue(
            res.data['sabi_message']['message'].startswith('Good morning.'),
            msg=f"英語挨拶が付いていない: {res.data['sabi_message']['message']!r}",
        )

    def test_en_via_accept_language_header(self):
        """preferred_language 未設定でも Accept-Language で英語になる。

        Mobile は言語切替時に `PATCH /player/` を best-effort で投げるだけなので
        (app_locale.dart の LocaleSideEffects)、オフライン等で失敗した端末は
        ヘッダだけが手がかりになる。
        """
        res = self.client.get(
            '/api/home/', {'time_segment': 'morning'},
            HTTP_ACCEPT_LANGUAGE='en-US,en;q=0.9',
        )
        self.assertEqual(res.status_code, 200)
        self.assertTrue(
            res.data['sabi_message']['message'].startswith('Good morning.'),
            msg=f"英語挨拶が付いていない: {res.data['sabi_message']['message']!r}",
        )

    def test_ja_bootstrap_keeps_japanese_greeting(self):
        """既定 (ja) の挙動は変わらない。"""
        self._set_language('ja')
        res = self.client.get('/api/home/', {'time_segment': 'morning'})
        self.assertEqual(res.status_code, 200)
        self.assertTrue(
            res.data['sabi_message']['message'].startswith('おはようございます。'),
        )

    def test_bootstrap_and_sabi_view_agree(self):
        """2 経路が同じ locale で同じ文面を返す (今回の事故そのもののガード)。"""
        for lang in ('ja', 'en'):
            with self.subTest(lang=lang):
                self._set_language(lang)
                boot = self.client.get('/api/home/', {'time_segment': 'night'})
                direct = self.client.get('/api/sabi/message/', {'time_segment': 'night'})
                self.assertEqual(boot.status_code, 200)
                self.assertEqual(direct.status_code, 200)
                self.assertEqual(
                    boot.data['sabi_message']['message'],
                    direct.data['message'],
                    msg=f'{lang}: bootstrap と sabi/message/ で文面が食い違っている',
                )
