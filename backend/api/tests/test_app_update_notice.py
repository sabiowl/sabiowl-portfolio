"""【FEAT-543 (2026-09-23)】バージョンアップ告知の Backend 側。

## 🔴 空振り検出が本体である

「告知が出る」だけを縛ると**常に出す実装**でも緑になり、
「出ない」だけを縛ると**常に出さない実装**でも緑になる。
**両方を対で書く。**

⚠️ **本ファイルは `DEFAULT_THROTTLE_CLASSES` を無効化しない。**
他のテストは軒並み `override_settings` で潰しているが、
ここでは「throttle が付いていないこと」が主題なので実設定で走らせる。
そのぶん `LocMemCache` の持ち越しを明示クリアする必要がある
(`get_app_update_config` の 60 秒 TTL がテスト間で漏れる)。
"""
from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse

from api.models import AppUpdateConfig
from api.services.app_update_cache import invalidate_app_update_cache
from api.views.app_update import _EN_FALLBACK


class _AppUpdateTestBase(TestCase):
    def setUp(self):
        super().setUp()
        # ⚠️ throttle の履歴も config の cache も `LocMemCache` に残る。
        #    `TestCase` はトランザクションを巻き戻すが **cache は戻さない**。
        cache.clear()
        self.addCleanup(cache.clear)
        self.url = reverse('app-update-status')

    def _configure(self, **kwargs):
        config = AppUpdateConfig.get_solo()
        for key, value in kwargs.items():
            setattr(config, key, value)
        config.save()
        invalidate_app_update_cache()
        return config


class AppUpdateStatusResponseTest(_AppUpdateTestBase):
    """§4 テスト 6: OFF なら出さない / ON なら出す。"""

    def test_disabled_config_reports_disabled(self):
        self._configure(is_enabled=False, latest_version='1.1.4')
        res = self.client.get(self.url)
        self.assertEqual(res.status_code, 200)
        self.assertFalse(res.json()['is_enabled'])
        # ⚠️ しきい値も空で返す。アプリが `is_enabled` を読み違えても
        #    比較で「更新なし」に倒れるようにしておく。
        self.assertEqual(res.json()['latest_version'], '')

    def test_no_row_at_all_reports_disabled(self):
        """🔵 一度も admin を開いていない状態。migration 直後がこれである。"""
        AppUpdateConfig.objects.all().delete()
        invalidate_app_update_cache()
        res = self.client.get(self.url)
        self.assertEqual(res.status_code, 200)
        self.assertFalse(res.json()['is_enabled'])

    def test_enabled_config_reports_thresholds_and_text(self):
        # 🔴 空振り検出の対。上の 2 件だけだと「常に false を返す」実装で緑になる。
        self._configure(
            is_enabled=True,
            latest_version='1.1.4',
            min_supported_version='1.1.2',
            title='新しい Sabiowl をご用意しました',
            body='更新していただけます 🪶',
        )
        data = self.client.get(self.url).json()
        self.assertTrue(data['is_enabled'])
        self.assertEqual(data['latest_version'], '1.1.4')
        self.assertEqual(data['min_supported_version'], '1.1.2')
        self.assertEqual(data['title'], '新しい Sabiowl をご用意しました')
        self.assertEqual(data['body'], '更新していただけます 🪶')

    def test_min_supported_version_defaults_to_empty(self):
        """🔴 必須更新は既定で無効。**入れた瞬間に締め出す**種類の値である。"""
        config = AppUpdateConfig.get_solo()
        self.assertEqual(config.min_supported_version, '')
        self.assertFalse(config.is_enabled)


class AppUpdateEnglishFallbackTest(_AppUpdateTestBase):
    """§4 テスト 7: `_en` が空のまま ON にされたとき。

    🔴 **FEAT-536 §5 で実際に起きた。** 「admin が埋め忘れる」ではなく
    「**そもそも埋める欄が無く、既定値のまま出る**」のが現実の姿だった。
    """

    def test_english_locale_falls_back_when_en_is_blank(self):
        self._configure(
            is_enabled=True, latest_version='1.1.4',
            title='日本語のタイトル', body='日本語の本文 🪶',
            title_en='', body_en='',
        )
        data = self.client.get(self.url, HTTP_ACCEPT_LANGUAGE='en').json()
        self.assertEqual(data['title'], _EN_FALLBACK['title'])
        self.assertEqual(data['body'], _EN_FALLBACK['body'])
        # 🔴 日本語が英語端末に出ていないこと。ここが本体である。
        self.assertNotIn('日本語', data['title'])
        self.assertNotIn('日本語', data['body'])

    def test_english_locale_uses_admin_text_when_filled(self):
        # 🔴 対。上だけだと「常に fallback を返す」実装で緑になり、
        #    admin が英語を埋めても反映されない。
        self._configure(
            is_enabled=True, latest_version='1.1.4',
            title='日本語のタイトル', body='日本語の本文 🪶',
            title_en='Admin supplied title', body_en='Admin supplied body',
        )
        data = self.client.get(self.url, HTTP_ACCEPT_LANGUAGE='en').json()
        self.assertEqual(data['title'], 'Admin supplied title')
        self.assertEqual(data['body'], 'Admin supplied body')

    def test_japanese_locale_is_unaffected(self):
        self._configure(
            is_enabled=True, latest_version='1.1.4',
            title='日本語のタイトル', body='日本語の本文 🪶',
            title_en='', body_en='',
        )
        data = self.client.get(self.url, HTTP_ACCEPT_LANGUAGE='ja').json()
        self.assertEqual(data['title'], '日本語のタイトル')


class AppUpdateEndpointIsOpenTest(_AppUpdateTestBase):
    """§4 テスト 8: 認証なしで叩けて、throttle が付いていない。"""

    #: anon の上限 (300) を確実に超える回数。上限そのものは書かない。
    PROBE_COUNT = 400

    def test_reachable_without_authentication(self):
        self.assertEqual(self.client.get(self.url).status_code, 200)

    def test_declares_no_authentication_and_no_throttle(self):
        """空振り検出。下の 400 回は「たまたま枯れなかった」でも緑になりうる。"""
        from api.views.app_update import AppUpdateStatusView
        self.assertEqual(list(AppUpdateStatusView.authentication_classes), [])
        self.assertEqual(
            list(AppUpdateStatusView.throttle_classes), [],
            '🔴 throttle が付くと、アプリを開くたびに anon の枠を消費する。'
            '枯れると告知が届かず、代わりに「通信できませんでした」が出る',
        )

    def test_many_launches_do_not_exhaust_the_anon_bucket(self):
        for i in range(self.PROBE_COUNT):
            res = self.client.get(self.url)
            self.assertNotEqual(
                res.status_code, 429,
                f'{i + 1} 回目の /app-update/ が 429 になった',
            )


class AppUpdateCacheTest(_AppUpdateTestBase):
    """cache が効いていること、admin の保存で落ちること。"""

    def test_config_is_served_from_cache(self):
        self._configure(is_enabled=True, latest_version='1.1.4')
        self.assertTrue(self.client.get(self.url).json()['is_enabled'])

        # cache を落とさずに DB だけ書き換える → 旧値が返る (= cache が効いている)
        AppUpdateConfig.objects.filter(pk=1).update(is_enabled=False)
        self.assertTrue(
            self.client.get(self.url).json()['is_enabled'],
            'cache を経由していない。起動のたびに SELECT を撃つことになる',
        )

        # 明示的に落とせば即座に反映される (admin の save がこれを呼ぶ)
        invalidate_app_update_cache()
        self.assertFalse(
            self.client.get(self.url).json()['is_enabled'],
            '🔵 事故ったら is_enabled を OFF にすれば消える、'
            'という逃げ道がここに依存している',
        )


class AppUpdateAdminWiringTest(TestCase):
    """admin から触れること。**入力経路が無い field を作らない。**

    🔴 FEAT-536 は `fieldsets` を明示したまま `title_en` / `body_en` を
    足したため、**model に field があるのに admin に出てこない**状態を作った。
    しかもそれが**障害中の唯一の画面**に出る経路だった。
    """

    def test_all_editable_fields_are_exposed_in_fieldsets(self):
        from api.admin import AppUpdateConfigAdmin

        exposed = {
            name
            for _, opts in AppUpdateConfigAdmin.fieldsets
            for name in opts['fields']
        }
        editable = {
            f.name
            for f in AppUpdateConfig._meta.get_fields()
            if getattr(f, 'editable', False)
            and f.name not in ('id', 'created_by', 'updated_at')
        }
        self.assertEqual(
            exposed, editable,
            'admin の fieldsets と model の field がずれている。'
            'field を足しても admin に出てこない状態になる',
        )

    def test_save_invalidates_the_cache(self):
        """admin の保存が cache を落とすこと。落とさないと最大 60 秒古い値が残る。"""
        import inspect
        from api.admin import AppUpdateConfigAdmin

        source = inspect.getsource(AppUpdateConfigAdmin.save_model)
        self.assertIn('invalidate_app_update_cache', source)


class MandatoryUpdateCopyTest(_AppUpdateTestBase):
    """【FEAT-544 (2026-09-23)】必須更新の文面も admin から編集できる。

    🔴 **方針を変えた理由は「admin に無い機能は忘れられる」**（ユーザー指摘）。
    **入力欄はそれ自体が運用の説明書である。**
    """

    def test_view_returns_mandatory_copy(self):
        self._configure(
            is_enabled=True,
            latest_version='1.1.6',
            min_supported_version='1.1.4',
            mandatory_title='必須更新のタイトル',
            mandatory_body='必須更新の本文',
        )
        data = self.client.get(self.url).json()
        self.assertEqual(data['mandatory_title'], '必須更新のタイトル')
        self.assertEqual(data['mandatory_body'], '必須更新の本文')

    def test_disabled_config_returns_empty_mandatory_copy(self):
        # 🔴 空振り検出の対。これが無いと「常に文面を返す」実装で緑になる。
        self._configure(is_enabled=False, mandatory_title='出てはいけない')
        data = self.client.get(self.url).json()
        self.assertEqual(data['mandatory_title'], '')
        self.assertEqual(data['mandatory_body'], '')

    def test_english_locale_falls_back_for_mandatory_copy(self):
        self._configure(
            is_enabled=True, min_supported_version='1.1.4',
            mandatory_title='日本語のタイトル', mandatory_body='日本語の本文',
            mandatory_title_en='', mandatory_body_en='',
        )
        data = self.client.get(self.url, HTTP_ACCEPT_LANGUAGE='en').json()
        self.assertEqual(data['mandatory_title'], _EN_FALLBACK['mandatory_title'])
        self.assertEqual(data['mandatory_body'], _EN_FALLBACK['mandatory_body'])
        self.assertNotIn('日本語', data['mandatory_title'])

    def test_english_locale_uses_admin_text_when_filled(self):
        self._configure(
            is_enabled=True, min_supported_version='1.1.4',
            mandatory_title='日本語', mandatory_body='日本語',
            mandatory_title_en='Admin mandatory title',
            mandatory_body_en='Admin mandatory body',
        )
        data = self.client.get(self.url, HTTP_ACCEPT_LANGUAGE='en').json()
        self.assertEqual(data['mandatory_title'], 'Admin mandatory title')
        self.assertEqual(data['mandatory_body'], 'Admin mandatory body')


class EnglishFallbackHasOneSourceOfTruthTest(TestCase):
    """🔴 【FEAT-544 Pre-mortem 2】英語の既定文を 2 箇所に書かない。

    FEAT-536 は「2 箇所に同じ英文がある」ことを申し送り事項として残し、
    `doc/runbook/maintenance_mode.md` に「文言を変えるときは 2 箇所」と
    書く運用でしのいでいた。**ここでは構造的に解消する。**
    """

    def test_view_fallback_is_the_model_constant(self):
        from api.models import app_update as model_module
        from api.views import app_update as view_module

        self.assertIs(
            view_module._EN_FALLBACK, model_module.EN_FALLBACK,
            'view が model の定数とは別の dict を持っている。'
            '同じ英文を 2 箇所に書くと必ず食い違う',
        )

    def test_fallback_covers_every_translated_field(self):
        """空振り検出。キーが欠けていると `_text` が KeyError で 500 になる。"""
        from api.models.app_update import EN_FALLBACK
        self.assertEqual(
            set(EN_FALLBACK),
            {'title', 'body', 'mandatory_title', 'mandatory_body'},
        )
        for key, value in EN_FALLBACK.items():
            self.assertTrue(value.strip(), f'{key} の英語既定文が空')


class AppUpdateDefaultsTest(TestCase):
    """§6 テスト 3: 新規行の既定値。

    🔵 **既定値が日英そろって埋まっていれば、緊急時に書くものは無い。**
    admin がやることは**数字を入れるだけ**で変わらない。
    """

    def test_new_row_has_all_copy_filled(self):
        config = AppUpdateConfig.get_solo()
        for field in ('title', 'title_en', 'body', 'body_en',
                      'mandatory_title', 'mandatory_title_en',
                      'mandatory_body', 'mandatory_body_en'):
            self.assertTrue(
                getattr(config, field).strip(),
                f'{field} の既定値が空。緊急時に文章を書かせることになる',
            )

    def test_thresholds_still_start_empty(self):
        """🔴 **しきい値だけは空で始める。** ここが埋まると入れた瞬間に全員へ出る。"""
        config = AppUpdateConfig.get_solo()
        self.assertFalse(config.is_enabled)
        self.assertEqual(config.latest_version, '')
        self.assertEqual(config.min_supported_version, '')

    def test_copy_has_no_emoji(self):
        """🔵 更新告知はシステムの通知であってサビの声ではない（ユーザー判断）。

        ⚠️ **絵文字の見え方が環境ごとに違う**のも理由である。
        """
        from api.models.app_update import EN_FALLBACK
        config = AppUpdateConfig.get_solo()
        texts = [getattr(config, f) for f in (
            'title', 'title_en', 'body', 'body_en',
            'mandatory_title', 'mandatory_title_en',
            'mandatory_body', 'mandatory_body_en',
        )] + list(EN_FALLBACK.values())
        for text in texts:
            self.assertNotIn('\U0001FAB6', text, f'🪶 が残っている: {text}')
