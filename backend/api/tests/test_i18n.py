"""【FEAT-489 Phase 4】Backend i18n 契約テスト (10 件)。

テスト対象:
  - I18nMiddleware: request.locale 解決 (3 優先順位 + fallback) + Vary ヘッダー
  - I18nFieldMixin: _en フィールドの en 返却 / silent fallback / ja default
  - get_i18n_field: standalone helper (Announcement / Enemy 等のインライン dict 経路)
  - 5 モデル全カバレッジ (SabiMessage / Announcement / TaskSuggestion / Enemy / Character)
  - ユーザー生成コンテンツ (Habit.name) は翻訳対象外
  - Character 4 フィールドの独立フォールバック

テスト一覧:
  T01: ja default — Accept-Language なし + preferred_language なし → request.locale == 'ja'
  T02: en via Accept-Language — 'Accept-Language: en' → request.locale == 'en'
  T03: en via preferred_language — Accept-Language 無し + preferred_language='en' → 'en'
  T04: Accept-Language priority — preferred_language='en' + Accept-Language: ja → locale == 'ja'
  T05: silent fallback when _en empty — _en='' → ja value が返る (例外なし + ログ確認)
  T06: unsupported locale falls back to ja — 'fr' は非対応 → locale == 'ja'
  T07: Vary: Accept-Language header — 全レスポンスに Vary ヘッダー付与
  T08: 5 models all covered — _en フィールドが全モデルに存在する構造チェック
  T09: user-generated content not translated — Habit.name に _en フィールドなし
  T10: multi-field i18n — Character 4 フィールドが独立してフォールバック
  T11: i18n 対象の自動列挙 — `_en` を持つ model が 2 コマンド両方に自動で載る
"""
import json
import os
import tempfile
from io import StringIO
from unittest.mock import patch

from django.apps import apps
from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.test import RequestFactory, TestCase, override_settings

from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient, APITestCase

from api.i18n_targets import i18n_targets
from api.middleware.i18n import I18nMiddleware
from api.models import (
    Announcement, Character, Enemy, Habit, Job, PlayerProfile, SabiMessage, TaskSuggestion,
)
from api.serializers import I18nFieldMixin, get_i18n_field

User = get_user_model()


def _make_user_with_player(username='tester', email=None):
    email = email or f'{username}@example.com'
    user = User.objects.create_user(username=username, email=email, password='pw')
    player = PlayerProfile.objects.create(user=user)
    return user, player


# ─────────────────────────────────────────────────────────────────────────────
# T01: ja default
# ─────────────────────────────────────────────────────────────────────────────
class T01JaDefaultTest(TestCase):
    """Accept-Language なし + preferred_language なし → locale == 'ja'"""

    def test_ja_default(self):
        factory = RequestFactory()
        request = factory.get('/api/', HTTP_ACCEPT_LANGUAGE='')

        # 未認証ユーザー
        class _AnonymousUser:
            is_authenticated = False

        request.user = _AnonymousUser()

        responses = []

        def get_response(r):
            from django.http import HttpResponse
            resp = HttpResponse()
            responses.append(r.locale)
            return resp

        mw = I18nMiddleware(get_response)
        mw(request)

        self.assertEqual(responses[0], 'ja')


# ─────────────────────────────────────────────────────────────────────────────
# T02: en via Accept-Language
# ─────────────────────────────────────────────────────────────────────────────
class T02EnViaAcceptLanguageTest(TestCase):
    """Accept-Language: en → locale == 'en' (未認証経路)"""

    def test_en_via_accept_language(self):
        factory = RequestFactory()
        request = factory.get('/api/', HTTP_ACCEPT_LANGUAGE='en-US,en;q=0.9')

        class _AnonymousUser:
            is_authenticated = False

        request.user = _AnonymousUser()
        resolved = []

        def get_response(r):
            from django.http import HttpResponse
            resolved.append(r.locale)
            return HttpResponse()

        mw = I18nMiddleware(get_response)
        mw(request)

        self.assertEqual(resolved[0], 'en')


# ─────────────────────────────────────────────────────────────────────────────
# T03: en via preferred_language (ヘッダ非送信クライアント向けの fallback)
# ─────────────────────────────────────────────────────────────────────────────
class T03EnViaPreferredLanguageTest(TestCase):
    """Accept-Language 無し + preferred_language='en' → locale == 'en'

    【2026-08-02 hotfix】旧テストは `Accept-Language: ja` を送ったうえで
    「preferred が勝つ」ことを検証していた。優先順位入れ替え (T04 参照) に伴い、
    preferred_language 本来の役割 = **ヘッダを送らないクライアントの fallback**
    を検証する形に変更した。
    """

    def setUp(self):
        self.user, self.player = _make_user_with_player('t03')
        settings = self.player.settings
        settings.preferred_language = 'en'
        settings.save()

    def test_en_via_preferred_language(self):
        factory = RequestFactory()
        request = factory.get('/api/')  # Accept-Language なし
        request.user = self.user
        resolved = []

        def get_response(r):
            from django.http import HttpResponse
            resolved.append(r.locale)
            return HttpResponse()

        mw = I18nMiddleware(get_response)
        mw(request)

        self.assertEqual(resolved[0], 'en')


# ─────────────────────────────────────────────────────────────────────────────
# T04: Accept-Language が preferred_language に優先する
# ─────────────────────────────────────────────────────────────────────────────
class T04AcceptLanguagePriorityTest(TestCase):
    """preferred_language='en' + Accept-Language: ja → locale=='ja' (ヘッダが勝つ)

    ## なぜ優先順位を入れ替えたか (2026-08-02)

    旧契約は「preferred_language が勝つ」だった。前提は
    **Accept-Language = 端末 locale** で、「端末が英語でもアプリ設定が日本語なら
    日本語」を守るため。

    ところが Phase 2E の api_client.dart は端末 locale ではなく
    **`ServiceL10n.current` = アプリが今表示している言語**を送る設計になった
    (BUG-27 対策で UI を ja 固定していた当時の名残)。ヘッダの意味が変わったのに
    優先順位が見直されず、次の 2 つが壊れていた:

      1. `preferred_language` は `default='ja'` の非 null field で「未設定」を
         表現できない。よって認証済ユーザーは常に 1 段目で 'ja' に確定し、
         **Accept-Language が構造的に到達不能**だった。
      2. 逆に preferred_language='en' が残ったまま日本語に戻したユーザーには、
         UI 日本語 + サーバー文言英語の **1 画面 2 言語混在**が起きうる。

    ヘッダは「今表示している言語」そのものなので、保存値より新しい。
    したがってヘッダを優先するのが実態に合う。

    なお旧テストは `request.user` を RequestFactory で直接差し込んでいたため、
    「middleware 時点では DRF Token 認証がまだ走っておらず request.user は
    AnonymousUser」という本番の制約を再現できておらず、①を検出できなかった。
    """

    def setUp(self):
        self.user, self.player = _make_user_with_player('t04')
        settings = self.player.settings
        settings.preferred_language = 'en'
        settings.save()

    def test_accept_language_over_preferred_language(self):
        factory = RequestFactory()
        request = factory.get('/api/', HTTP_ACCEPT_LANGUAGE='ja,ja-JP;q=0.9')
        request.user = self.user
        resolved = []

        def get_response(r):
            from django.http import HttpResponse
            resolved.append(r.locale)
            return HttpResponse()

        mw = I18nMiddleware(get_response)
        mw(request)

        self.assertEqual(resolved[0], 'ja')


# ─────────────────────────────────────────────────────────────────────────────
# T05: silent fallback when _en empty
# ─────────────────────────────────────────────────────────────────────────────
class T05SilentFallbackTest(TestCase):
    """_en フィールドが空 → ja value 返却、例外なし、i18n_fallback ログ記録"""

    def test_silent_fallback_when_en_empty(self):
        # content_en が空の SabiMessage 相当オブジェクトをモックで代用
        class FakeSabiMessage:
            content = 'こんにちは。'
            content_en = ''
            pk = 1

        result = get_i18n_field(FakeSabiMessage(), 'content', 'en')
        self.assertEqual(result, 'こんにちは。',
                         '_en 空のとき ja value にフォールバックすること')

    def test_fallback_logs_i18n_fallback(self):
        class FakeSabiMessage:
            content = 'こんにちは。'
            content_en = ''
            pk = 1

        with self.assertLogs('api.serializers', level='INFO') as cm:
            get_i18n_field(FakeSabiMessage(), 'content', 'en')

        self.assertTrue(
            any('i18n_fallback' in line for line in cm.output),
            'i18n_fallback ログが記録されること',
        )


# ─────────────────────────────────────────────────────────────────────────────
# T06: unsupported locale falls back to ja
# ─────────────────────────────────────────────────────────────────────────────
class T06UnsupportedLocaleTest(TestCase):
    """Accept-Language: fr (非対応) → locale == 'ja' (default)"""

    def test_unsupported_locale_falls_back_to_ja(self):
        factory = RequestFactory()
        request = factory.get('/api/', HTTP_ACCEPT_LANGUAGE='fr,fr-FR;q=0.9')

        class _AnonymousUser:
            is_authenticated = False

        request.user = _AnonymousUser()
        resolved = []

        def get_response(r):
            from django.http import HttpResponse
            resolved.append(r.locale)
            return HttpResponse()

        mw = I18nMiddleware(get_response)
        mw(request)

        self.assertEqual(resolved[0], 'ja')


# ─────────────────────────────────────────────────────────────────────────────
# T07: Vary: Accept-Language header
# ─────────────────────────────────────────────────────────────────────────────
class T07VaryHeaderTest(TestCase):
    """I18nMiddleware が全 response に Vary: Accept-Language を付与する"""

    def test_vary_header_present(self):
        factory = RequestFactory()
        request = factory.get('/api/')

        class _AnonymousUser:
            is_authenticated = False

        request.user = _AnonymousUser()

        from django.http import HttpResponse

        def get_response(r):
            return HttpResponse()

        mw = I18nMiddleware(get_response)
        response = mw(request)

        self.assertEqual(response.get('Vary'), 'Accept-Language')


# ─────────────────────────────────────────────────────────────────────────────
# T08: 5 models all covered
# ─────────────────────────────────────────────────────────────────────────────
class T08FiveModelsCoveredTest(TestCase):
    """5 モデル全てに所定の _en フィールドが存在する (DB schema 構造確認)"""

    def _has_field(self, model_cls, field_name):
        return any(f.name == field_name for f in model_cls._meta.get_fields())

    def test_sabi_message_content_en(self):
        self.assertTrue(self._has_field(SabiMessage, 'content_en'))

    def test_announcement_title_en_and_body_en(self):
        self.assertTrue(self._has_field(Announcement, 'title_en'))
        self.assertTrue(self._has_field(Announcement, 'body_en'))

    def test_task_suggestion_title_en_and_hint_en(self):
        self.assertTrue(self._has_field(TaskSuggestion, 'title_en'))
        self.assertTrue(self._has_field(TaskSuggestion, 'hint_en'))

    def test_enemy_name_en(self):
        self.assertTrue(self._has_field(Enemy, 'name_en'))

    def test_character_four_en_fields(self):
        for field in ('name_en', 'role_en', 'tagline_en', 'description_en'):
            self.assertTrue(self._has_field(Character, field), f'Character.{field} がない')

    def test_job_name_en(self):
        """【FEAT-489 Phase 2F-a】Phase 4 で Job だけ _en が漏れていたのを回収 (0198)。"""
        self.assertTrue(self._has_field(Job, 'job_name_en'))


# ─────────────────────────────────────────────────────────────────────────────
# T08b: Job.job_name_en (FEAT-489 Phase 2F-a)
# ─────────────────────────────────────────────────────────────────────────────
class T08bJobNameEnTest(TestCase):
    """Job.job_name_en の seed / locale 解決 / fallback を締める。

    Phase 2E の Mobile 側 verify で「Job だけ Phase 4 の _en 追加から漏れており、
    英語 locale でも API が日本語を返す」と検出されたのを受けた回帰ガード。
    """

    def test_migration_seeded_all_jobs(self):
        """migration 0198 の seed で既存 14 ジョブすべてに英名が入っている。"""
        blanks = list(
            Job.objects.filter(job_name_en='').values_list('job_id', flat=True)
        )
        self.assertEqual(blanks, [], f'job_name_en が空のジョブ: {blanks}')

    def test_en_locale_returns_english(self):
        job = Job.objects.create(
            job_id='test_job', job_name='テスト職', job_name_en='Test Job',
        )
        self.assertEqual(get_i18n_field(job, 'job_name', 'en'), 'Test Job')

    def test_ja_locale_returns_japanese(self):
        job = Job.objects.create(
            job_id='test_job_ja', job_name='テスト職', job_name_en='Test Job',
        )
        self.assertEqual(get_i18n_field(job, 'job_name', 'ja'), 'テスト職')

    def test_silent_fallback_when_en_empty(self):
        """job_name_en が空なら en locale でも ja を返す (運営が未入力の新ジョブ)。"""
        job = Job.objects.create(
            job_id='test_job_blank', job_name='未翻訳職', job_name_en='',
        )
        self.assertEqual(get_i18n_field(job, 'job_name', 'en'), '未翻訳職')

    def test_job_id_is_never_localised(self):
        """job_id は Mobile の switch key。locale で変わってはいけない。"""
        job = Job.objects.create(
            job_id='warrior_probe', job_name='戦士', job_name_en='Warrior',
        )
        self.assertEqual(job.job_id, 'warrior_probe')
        self.assertEqual(get_i18n_field(job, 'job_id', 'en'), 'warrior_probe')


# ─────────────────────────────────────────────────────────────────────────────
# T09: user-generated content not translated
# ─────────────────────────────────────────────────────────────────────────────
class T09UserGeneratedNotTranslatedTest(TestCase):
    """Habit.name は翻訳対象外 (_en フィールドが存在しないことを確認)"""

    def test_habit_has_no_name_en_field(self):
        field_names = [f.name for f in Habit._meta.get_fields()]
        self.assertNotIn('name_en', field_names,
                         'Habit.name_en が存在してはいけない (UGC は翻訳しない)')


# ─────────────────────────────────────────────────────────────────────────────
# T10: multi-field i18n — Character 4 フィールド独立フォールバック
# ─────────────────────────────────────────────────────────────────────────────
class T10MultiFieldI18nTest(TestCase):
    """Character の 4 _en フィールドが独立してフォールバックする"""

    def test_each_field_falls_back_independently(self):
        """name_en はあるが role_en が空の場合、role は ja にフォールバックする"""

        class FakeCharacter:
            name = '雷鳴の勇者'
            name_en = 'Thunder Hero'
            role = '戦士'
            role_en = ''          # 空 → ja フォールバック
            tagline = '風をまとう者'
            tagline_en = 'One with the wind'
            description = '古き血を持つ戦士。'
            description_en = ''   # 空 → ja フォールバック
            pk = 99

        obj = FakeCharacter()
        self.assertEqual(get_i18n_field(obj, 'name', 'en'), 'Thunder Hero')
        self.assertEqual(get_i18n_field(obj, 'role', 'en'), '戦士')
        self.assertEqual(get_i18n_field(obj, 'tagline', 'en'), 'One with the wind')
        self.assertEqual(get_i18n_field(obj, 'description', 'en'), '古き血を持つ戦士。')

    def test_ja_locale_always_returns_ja_field(self):
        class FakeCharacter:
            name = '雷鳴の勇者'
            name_en = 'Thunder Hero'
            pk = 99

        obj = FakeCharacter()
        result = get_i18n_field(obj, 'name', 'ja')
        self.assertEqual(result, '雷鳴の勇者', 'locale=ja では常に ja フィールドを返す')


# ─────────────────────────────────────────────────────────────────────────────
# T11: i18n 対象 model の自動列挙 (手書きリストの再発防止)
# ─────────────────────────────────────────────────────────────────────────────
class T11I18nTargetAutoDiscoveryTest(TestCase):
    """`_en` を持つ model が、英訳を入れる道具と空欄を検出する道具の両方に載る。

    ## なぜこのテストが要るか

    `translate_master_data` (英訳を流し込む) と `check_i18n_coverage`
    (空欄を検出する) は、対象 model を **ハードコードした 5 件のリスト**で
    持っていた。その後 `Job.job_name_en` が追加されたが、**どちらのリストにも
    登録されなかった** (20260802 functional review §3 B-1)。

    手書きリストは「人が思い出したものしか拾わない」。model から発見する形に
    変えたので、**その発見が実際に効いていること**をここで縛る。

    次に誰かが `_en` field を足したとき、このテストは自動的にその field も
    対象に含める —— テスト自体を書き換える必要はない。
    """

    def _all_en_fields(self):
        """api app 内の `_en` concrete field を、i18n_targets とは独立に数える。

        `i18n_targets()` の実装をそのまま呼ぶと「自分で自分を検証する」ことに
        なるので、ここでは apps registry から素朴に走査する。
        """
        found = {}
        for model in apps.get_app_config('api').get_models():
            fields = sorted(
                f.name for f in model._meta.get_fields()
                if getattr(f, 'concrete', False) and f.name.endswith('_en')
            )
            if fields:
                found[model.__name__] = fields
        return found

    def test_targets_match_actual_en_fields(self):
        """i18n_targets() が実在の `_en` field と過不足なく一致する。"""
        expected = self._all_en_fields()
        actual = {name: fields for name, _cls, fields in i18n_targets()}
        self.assertEqual(actual, expected)

    def test_job_is_included(self):
        """漏れていた当の `Job` が対象に入っている (本件の回帰ガード)。"""
        names = {name for name, _cls, _fields in i18n_targets()}
        self.assertIn('Job', names,
                      'Job が i18n 対象から漏れている (手書きリストへの逆戻り)')

    def test_check_coverage_command_reports_job(self):
        """`check_i18n_coverage` の出力に Job が現れる。

        列挙関数だけでなく **コマンドが実際にそれを使っている** ことを確認する
        (関数を作っただけでコマンドが手書きのまま、という失敗を防ぐ)。
        """
        out = StringIO()
        call_command('check_i18n_coverage', stdout=out)
        self.assertIn('Job.job_name_en', out.getvalue())

    def test_translate_command_accepts_job_entries(self):
        """`translate_master_data` が Job の英訳を受け付ける (dry-run)。

        以前は `_MODEL_MAP` に Job が無く "Unknown model" で握り潰されていた。
        """
        job = Job.objects.create(
            job_id='t11_job', job_name='列挙テスト職', job_name_en='',
        )
        payload = {'Job': [{'id': job.pk, 'job_name_en': 'Enumerated Job'}]}
        with tempfile.NamedTemporaryFile(
            'w', suffix='.json', delete=False, encoding='utf-8',
        ) as fh:
            json.dump(payload, fh)
            temp_path = fh.name
        try:
            out = StringIO()
            call_command('translate_master_data', file=temp_path, stdout=out)
            self.assertNotIn('Unknown model', out.getvalue())
            job.refresh_from_db()
            self.assertEqual(job.job_name_en, 'Enumerated Job')
        finally:
            os.unlink(temp_path)


# ─────────────────────────────────────────────────────────────────────────────
# T12: ゲストの locale 解決 (2026-08-04 の 500 バグ回帰ガード)
# ─────────────────────────────────────────────────────────────────────────────
class T12GuestLocaleResolutionTest(TestCase):
    """`request.user` が **None** でも locale 解決が落ちない。

    ## なぜ落ちたか

    `GuestTokenAuthentication` は DRF の慣例と異なり `(None, guest_session)` を
    返す設計なので、ゲストのリクエストでは `request.user` が
    **AnonymousUser ではなく `None`** になる。

    `_resolve_locale` は `request.user.is_authenticated` を見ていたため、
    ここで `AttributeError: 'NoneType' object has no attribute 'is_authenticated'`
    → **500** になった。

    ## なぜ見つけにくかったか

    優先順位 1 は Accept-Language で、ヘッダがあればそこで確定して 2 に来ない。
    Mobile は毎リクエストでヘッダを送るので実機では踏まない。
    **ヘッダを送らないゲスト**だけが落ちるという条件だった。

    さらに `request.locale` は遅延評価なので、**locale を読む view だけ**が
    500 になる。FEAT-516 で `task-suggestions` が locale を読むようになった
    ことで初めて表面化した。
    """

    def _resolve(self, request):
        resolved = []

        def get_response(r):
            from django.http import HttpResponse
            resolved.append(str(r.locale))   # str() で遅延評価を強制
            return HttpResponse()

        I18nMiddleware(get_response)(request)
        return resolved[0]

    def test_user_none_does_not_crash(self):
        """ヘッダ無し + `request.user is None` → ja に落ちる (500 にしない)。"""
        request = RequestFactory().get('/api/')
        request.user = None
        self.assertEqual(self._resolve(request), 'ja')

    def test_user_none_still_honors_accept_language(self):
        """ゲストでも Accept-Language は効く。"""
        request = RequestFactory().get('/api/', HTTP_ACCEPT_LANGUAGE='en-US,en;q=0.9')
        request.user = None
        self.assertEqual(self._resolve(request), 'en')

    def test_user_attribute_missing_does_not_crash(self):
        """`request.user` 属性そのものが無くても落ちない。"""
        request = RequestFactory().get('/api/')
        self.assertEqual(self._resolve(request), 'ja')
