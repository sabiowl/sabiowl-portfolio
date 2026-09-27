"""【FEAT-427 (2026-06-11)】CharacterExchangeView (POST /api/characters/<pk>/exchange/) の契約テスト。

検証対象:
1. 1 枚 + 未所持 SSR 指定 → 成功、ticket→0、OwnedCharacter 作成
2. 0 枚 → 400 no_ticket
3. 存在しない character_id → 404
4. SR キャラ (price < 3000) 指定 → 400 not_ssr
5. 既所持 SSR → 400 already_owned
6. 並列リクエスト → select_for_update により 1 回のみ成功
"""
import threading
import traceback
from unittest import skipUnless

from django.contrib.auth import get_user_model
from django.db import connection
from django.test import TestCase, TransactionTestCase, override_settings
from django.urls import reverse
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Character, OwnedCharacter, PlayerProfile
from ._error_assert import error_code, error_message  # 【FEAT-515】

User = get_user_model()


_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework.authtoken.authentication.TokenAuthentication',
        'api.authentication.GuestTokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
}


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class CharacterExchangeContractTest(APITestCase):
    """FEAT-427: キャラ交換券 1 枚消費 → 未所持 SSR キャラ獲得の契約。"""

    def setUp(self):
        self.user = User.objects.create_user('exchange_player', email='exchange@example.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='Player',
            character_exchange_tickets=1,
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # 【BUG-108 (2026-06-14)】SSR キャラ判定を is_starter=False に変更。
        # 旧 price>=3000 から is_starter=False に切替 (price 1500 統一後の新判定)。
        self.ssr_char = Character.objects.filter(is_starter=False).first()
        if self.ssr_char is None:
            self.ssr_char = Character.objects.create(
                key='exchange_ssr', name='交換用SSR', role='テスト',
                description='', image_path='character_exchange_ssr',
                price=1500, unlock_level=1, is_starter=False,
                order=99,
            )

        # 【BUG-108】starter キャラ (sol/aria) は SSR 交換対象外 (rejected tier)。
        # シナリオ 4 の「not_ssr 400」確認用。
        self.starter_char = Character.objects.filter(is_starter=True).first()
        if self.starter_char is None:
            self.starter_char = Character.objects.create(
                key='exchange_starter', name='交換用starter', role='テスト',
                description='', image_path='character_exchange_starter',
                price=0, unlock_level=1, is_starter=True,
                order=98,
            )

    def _exchange(self, character_id):
        return self.client.post(reverse('character-exchange', args=[character_id]))

    # ─────────────────────────────────────────────────────────────
    # シナリオ 1: 1 枚 + 未所持 SSR → 成功
    # ─────────────────────────────────────────────────────────────
    def test_exchange_with_ticket_and_unowned_ssr_succeeds(self):
        res = self._exchange(self.ssr_char.pk)
        self.assertEqual(res.status_code, http_status.HTTP_200_OK, res.data)

        self.player.refresh_from_db()
        self.assertEqual(self.player.character_exchange_tickets, 0)
        self.assertTrue(
            OwnedCharacter.objects.filter(
                player=self.player, character=self.ssr_char,
            ).exists()
        )
        self.assertEqual(res.data['character_exchange_tickets'], 0)
        self.assertEqual(res.data['character']['id'], self.ssr_char.pk)

    # ─────────────────────────────────────────────────────────────
    # シナリオ 2: 0 枚 → 400 no_ticket
    # ─────────────────────────────────────────────────────────────
    def test_exchange_without_ticket_returns_400(self):
        self.player.character_exchange_tickets = 0
        self.player.save(update_fields=['character_exchange_tickets'])

        res = self._exchange(self.ssr_char.pk)
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        self.assertEqual(error_code(res), 'no_ticket')
        self.assertFalse(
            OwnedCharacter.objects.filter(
                player=self.player, character=self.ssr_char,
            ).exists()
        )

    # ─────────────────────────────────────────────────────────────
    # シナリオ 3: 存在しない character_id → 404
    # ─────────────────────────────────────────────────────────────
    def test_exchange_nonexistent_character_returns_404(self):
        res = self._exchange(999999)
        self.assertEqual(res.status_code, http_status.HTTP_404_NOT_FOUND)
        # 【FEAT-475 Phase 3c (2026-07-04)】新形式 {'error': {'code', 'message'}}
        self.assertEqual(error_code(res), 'character_exchange_not_found')

        # チケットは消費されない
        self.player.refresh_from_db()
        self.assertEqual(self.player.character_exchange_tickets, 1)

    # ─────────────────────────────────────────────────────────────
    # シナリオ 4: starter (is_starter=True) 指定 → 400 not_ssr (BUG-108)
    # ─────────────────────────────────────────────────────────────
    def test_exchange_starter_character_returns_400(self):
        """starter キャラ (sol/aria) は SSR 交換対象外。BUG-108 で判定基準を
        price >= 3000 → is_starter=False に変更したため、starter は rejected。"""
        res = self._exchange(self.starter_char.pk)
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        self.assertEqual(error_code(res), 'not_ssr')

        # チケットは消費されない
        self.player.refresh_from_db()
        self.assertEqual(self.player.character_exchange_tickets, 1)

    # ─────────────────────────────────────────────────────────────
    # シナリオ 5: 既所持 SSR → 400 already_owned
    # ─────────────────────────────────────────────────────────────
    def test_exchange_already_owned_returns_400(self):
        OwnedCharacter.objects.create(player=self.player, character=self.ssr_char)

        res = self._exchange(self.ssr_char.pk)
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        self.assertEqual(error_code(res), 'already_owned')

        # チケットは消費されない
        self.player.refresh_from_db()
        self.assertEqual(self.player.character_exchange_tickets, 1)


def should_run_race_test(vendor: str) -> bool:
    """DB vendor 名から「並列 race テストを実行してよいか」を返す。

    【BUG-144】**skip 条件を純関数に切り出してある**のは、これ自体をテストで
    縛るため (`RaceTestSkipConditionTest`)。判定を誤って PostgreSQL まで skip
    すると、**誰も気付かないまま race guard が無検証になる**。skip したまま
    緑になるのが最も危険な壊れ方なので、条件そのものを固定する。
    """
    return vendor == 'postgresql'


@skipUnless(
    should_run_race_test(connection.vendor),
    'SQLite はテーブル / DB 単位でロックするため、2 本目の writer が '
    '"database table is locked" で落ちて worker thread が例外死する (BUG-144)。'
    'CI は PostgreSQL なのでそちらで検証される。',
)
@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class CharacterExchangeRaceTest(TransactionTestCase):
    """FEAT-427 シナリオ 6: 並列リクエスト → select_for_update により 1 回のみ成功。

    ## 【BUG-144 (2026-08-11)】SQLite では実行しない

    ローカル (SQLite fallback) で **12 回中 3 回 (25%) 失敗**していた。真因は
    production コードではなく **テストの worker thread**:

        sqlite3.OperationalError: database table is locked: api_playereconomystate

    SQLite はテーブル / DB 単位でロックするので 2 本目の writer が落ち、
    `results` に何も append されないまま assertion に到達していた。
    出るメッセージは `1 回だけ成功するはず: []` だけで、真因は stderr にしか
    出ないため、辿り着くのに時間がかかる。

    さらに **緑になった回も信用できない**。ロックで落ちなかったということは
    2 本のリクエストが実質直列に流れた可能性があり、その場合
    「1 回成功 / 1 回 400」は当然の結果で `select_for_update` が効いた証明に
    ならない。SQLite 上では**赤も緑も情報量が乏しい**。

    CI は PostgreSQL 15 (`.github/workflows/ci.yml`) なので、**検証は失われない**。

    ## なぜ test_iap_webhook のように「削除」しなかったか

    同型の問題は 2026-06-17 に `test_iap_webhook.py` S7 でも起きており、
    そちらは threading テストを**削除して連続 POST に書き換え**ている
    (同ファイル L12-17 に判断が記録済)。本テストで同じ判断を採らないのは、
    **守っている対象の保証機構が違う**ため:

    | | 排他の保証 | アプリ層テストの価値 |
    |---|---|---|
    | IAP webhook S7 | **DB の UNIQUE 制約** | 構造的に保証済 → 限定的 |
    | 本テスト | **アプリコードの `select_for_update`** | **DB は守ってくれない → 高い** |

    `select_for_update` は書き忘れれば静かに消える。PostgreSQL で実行できる
    以上、検証を捨てる理由が無い。
    """

    reset_sequences = True

    def setUp(self):
        self.user = User.objects.create_user('race_player', email='race@example.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='Player',
            character_exchange_tickets=1,
        )
        self.token, _ = Token.objects.get_or_create(user=self.user)

        # 【BUG-108】SSR 判定を is_starter=False に変更 (race test も同じ基準)
        self.ssr_char = Character.objects.filter(is_starter=False).first()
        if self.ssr_char is None:
            self.ssr_char = Character.objects.create(
                key='race_ssr', name='並列用SSR', role='テスト',
                description='', image_path='character_race_ssr',
                price=1500, unlock_level=1, is_starter=False,
                order=97,
            )

    def test_concurrent_exchange_only_one_succeeds(self):
        from rest_framework.test import APIClient

        results = []
        errors = []

        def _do_request():
            # 【BUG-144】thread 内の例外は unittest から見えない。捕まえて
            # traceback ごと持ち帰らないと、失敗時に `results` が空という
            # 結果だけが見えて真因が分からない (実際 stderr を捕まえるまで
            # `database table is locked` に辿り着けなかった)。
            try:
                client = APIClient()
                client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
                res = client.post(reverse('character-exchange', args=[self.ssr_char.pk]))
                results.append(res.status_code)
            except BaseException:
                errors.append(traceback.format_exc())
            finally:
                # 【BUG-144】`finally` に置く。例外で抜けたときに閉じ損ねると
                # worker thread の connection がリークし、test DB を destroy
                # できなくなる (test_iap_webhook.py L12-17 が踏んだ形)。
                connection.close()

        threads = [threading.Thread(target=_do_request) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # 件数より先に検査する。例外が出ているなら、そちらが真因。
        #
        # `assertEqual(errors, [])` にしないのは、unittest の list diff
        # (`Lists differ: [...] != []` + `First extra element 0:` …) が先に出て
        # **traceback が埋もれる**ため。真因をすぐ読めるようにするのが本修正の
        # 目的なので、`fail()` で traceback だけを出す。
        if errors:
            self.fail(
                f'worker thread で {len(errors)} 件の例外が発生した '
                '(assertion の件数ずれより、こちらが真因):\n\n'
                + '\n\n'.join(errors)
            )

        self.assertEqual(results.count(200), 1, f'1 回だけ成功するはず: {results}')
        self.assertEqual(results.count(400), 1, f'1 回は in_ticket 不足で 400 のはず: {results}')

        self.player.refresh_from_db()
        self.assertEqual(self.player.character_exchange_tickets, 0)
        self.assertEqual(
            OwnedCharacter.objects.filter(
                player=self.player, character=self.ssr_char,
            ).count(),
            1,
        )


class RaceTestSkipConditionTest(TestCase):
    """【BUG-144 Pre-mortem S1】skip 条件そのものを縛る。

    `CharacterExchangeRaceTest` は SQLite では skip する。この判定を誤って
    **PostgreSQL まで skip してしまうと、誰も気付かないまま race guard が
    無検証になる**。skip したまま緑になるのが最も危険な壊れ方なので、
    条件を純関数に切り出したうえで固定する。

    本クラス自体は skip しない (常に走る)。
    """

    def test_runs_on_postgresql(self):
        self.assertTrue(
            should_run_race_test('postgresql'),
            'PostgreSQL で race テストが skip される。CI (PostgreSQL 15) で '
            'select_for_update が無検証になる',
        )

    def test_skipped_on_sqlite(self):
        self.assertFalse(
            should_run_race_test('sqlite'),
            'SQLite で race テストを実行すると "database table is locked" で '
            '25% 失敗する (BUG-144)',
        )

    def test_decoration_follows_the_condition(self):
        """判定関数とクラスの skip 状態が一致している。

        関数だけ直してデコレータを付け替え忘れる / その逆を防ぐ。
        """
        skipped = getattr(CharacterExchangeRaceTest, '__unittest_skip__', False)
        self.assertEqual(
            skipped, not should_run_race_test(connection.vendor),
            f'vendor={connection.vendor} での skip 状態が判定関数と食い違っている',
        )
