"""【BUG-158 (2026-09-12)】グローバル throttle の上限値と、起動プローブの除外。

## 何が起きていたか

`DEFAULT_THROTTLE_RATES` の `anon: 60/hour` / `user: 300/hour` は
**個別 scope を持つ view を除く全エンドポイント**に効く。上限に達した瞬間、
認証を要する全 API が 429 になる。

`user: 300/hour` は **5 リクエスト/分**であり、ガチャ 43 連 (Daily 30 /
Weekly 10 / Monthly 3) だけで 130 前後、起動 10 回で 100〜150 を消費する。
**濫用ではなく通常利用で当たる**。

🔴 さらに `HealthCheckView` / `MaintenanceStatusView` は認証を通らないため
`AnonRateThrottle` が適用され、**アプリを開くたびに anon バケットから
2 本消費していた**。枠が枯れると**障害の確認そのものができなくなる**。

## このファイルが縛るもの

| # | 内容 |
|:-:|---|
| 1 | 起動プローブ 2 本が throttle 対象外であること (100 回叩いても 429 にならない) |
| 2 | `anon` / `user` の直前に、設定値そのものを含む根拠コメントがあること |
| 3 | 認証済みユーザーの境界 (1200 まで通り 1201 で 429) |
| 4 | ゲスト / 未認証の境界 (300 まで通り 301 で拒否) |
| 5 | 個別 scope が変わっていないこと |

⚠️ **本ファイルは `DEFAULT_THROTTLE_CLASSES` を無効化しない。**
他のテストは軒並み `override_settings(REST_FRAMEWORK={'DEFAULT_THROTTLE_CLASSES': []})`
を当てているが、ここでは throttle そのものが主題なので実設定で走らせる。
そのぶん **`LocMemCache` の持ち越しを各テストで明示クリアする**必要がある。
"""
import re
import time
from pathlib import Path

from django.contrib.auth.models import AnonymousUser, User
from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse
from rest_framework.settings import api_settings
from rest_framework.test import APIClient, APIRequestFactory
from rest_framework.throttling import AnonRateThrottle, UserRateThrottle

_SETTINGS_PATH = Path(__file__).resolve().parents[2] / 'config' / 'settings.py'


class _ThrottleCacheMixin:
    """throttle の履歴は `LocMemCache` に残り、テスト間で持ち越される。

    ⚠️ Django の `TestCase` はトランザクションを巻き戻すが **cache は戻さない**。
    クリアしないと、あるテストで使い切った枠が次のテストに漏れて
    「なぜかここだけ 429」という再現しにくい不安定さになる。
    """

    def setUp(self):
        super().setUp()
        cache.clear()
        self.addCleanup(cache.clear)


class BootProbeIsNotThrottledTest(_ThrottleCacheMixin, TestCase):
    """🔴 §4-2: アプリを開くだけで枠を減らさない。

    health / maintenance は**障害時にこそ叩けなければならない**。
    枠が枯れると障害の確認そのものができなくなる。
    """

    #: anon の上限 (300) を確実に超える回数。上限そのものを直接書かないのは、
    #: 上限を上げ下げしてもこのテストの意味が変わらないようにするため。
    PROBE_COUNT = 400

    def test_health_survives_many_probes(self):
        client = APIClient()
        url = reverse('health')
        for i in range(self.PROBE_COUNT):
            response = client.get(url)
            self.assertNotEqual(
                response.status_code, 429,
                f'{i + 1} 回目の /health/ が 429 になった。'
                '起動プローブが anon バケットを食っている',
            )

    def test_maintenance_survives_many_probes(self):
        client = APIClient()
        url = reverse('maintenance-status')
        for i in range(self.PROBE_COUNT):
            response = client.get(url)
            self.assertNotEqual(
                response.status_code, 429,
                f'{i + 1} 回目の /maintenance/ が 429 になった。'
                '起動プローブが anon バケットを食っている',
            )

    def test_probe_views_declare_empty_throttle_classes(self):
        """空振り検出。

        上の 2 件は「たまたま 400 回では枯れなかった」でも緑になりうる。
        **除外が明示的に宣言されていること**を別途縛る。
        """
        from api.views.health import HealthCheckView
        from api.views.maintenance import MaintenanceStatusView

        for view in (HealthCheckView, MaintenanceStatusView):
            self.assertEqual(
                list(view.throttle_classes), [],
                f'{view.__name__} が throttle_classes を空にしていない',
            )


class ThrottleRateValuesTest(_ThrottleCacheMixin, TestCase):
    """§4-1: 上限値そのもの。"""

    def test_user_rate_is_1200_per_hour(self):
        throttle = UserRateThrottle()
        self.assertEqual(throttle.num_requests, 1200)
        self.assertEqual(throttle.duration, 3600)

    def test_anon_rate_is_300_per_hour(self):
        throttle = AnonRateThrottle()
        self.assertEqual(throttle.num_requests, 300)
        self.assertEqual(throttle.duration, 3600)

    def test_scoped_rates_are_unchanged(self):
        """⚠️ §5 テスト 5: 個別 scope は触っていない。

        🔵 上限を上げる判断が成立するのは、**実効的な防御が個別 scope と
        ゲームロジック側に残っている**からである。ここが一緒に緩むと
        §4-1 の判断根拠そのものが崩れる。
        """
        self.assertEqual(
            {
                scope: rate
                for scope, rate in api_settings.DEFAULT_THROTTLE_RATES.items()
                if scope not in ('anon', 'user')
            },
            {
                'contact': '3/hour',
                'habit_action': '120/hour',
                'friend_search': '30/hour',
                'social_auth': '20/hour',
                'guest_init': '5/hour',
            },
        )


class ThrottleBoundaryTest(_ThrottleCacheMixin, TestCase):
    """§5 テスト 3 / 4: 境界。

    ⚠️ 1201 回リクエストを投げると 1 件で数十秒かかる。代わりに
    **履歴を上限 - 1 件だけ先に詰めてから 2 回叩く**。
    DRF のスライディングウィンドウはタイムスタンプの配列なので、
    これは「既に 1199 回使った状態」と完全に等価である。
    """

    def _prefill(self, throttle, request, count):
        key = throttle.get_cache_key(request, view=None)
        self.assertIsNotNone(key, 'cache key が引けない = 前提が崩れている')
        now = time.time()
        cache.set(key, [now] * count, throttle.duration)
        return key

    def test_authenticated_user_passes_at_1200_and_is_blocked_at_1201(self):
        user = User.objects.create_user(username='throttle-boundary', password='x')
        request = APIRequestFactory().get('/api/player/')
        request.user = user

        throttle = UserRateThrottle()
        self._prefill(throttle, request, throttle.num_requests - 1)

        self.assertTrue(
            UserRateThrottle().allow_request(request, view=None),
            '1200 本目が通らない = 上限が 1200 に届いていない',
        )
        self.assertFalse(
            UserRateThrottle().allow_request(request, view=None),
            '1201 本目が通ってしまう = 上限が効いていない',
        )

    def test_anonymous_passes_at_300_and_is_blocked_at_301(self):
        request = APIRequestFactory().get('/api/health/')
        request.user = AnonymousUser()

        throttle = AnonRateThrottle()
        self._prefill(throttle, request, throttle.num_requests - 1)

        self.assertTrue(
            AnonRateThrottle().allow_request(request, view=None),
            '300 本目が通らない = 上限が 300 に届いていない',
        )
        self.assertFalse(
            AnonRateThrottle().allow_request(request, view=None),
            '301 本目が通ってしまう = 上限が効いていない',
        )


class ThrottleRationaleIsWrittenDownTest(TestCase):
    """🔴 §5 テスト 2 / Pre-mortem 5: 数字の根拠が書かれていること。

    **上限を上げるのは濫用防止を弱める判断である。** 根拠が書かれていないと、
    次に見た人が「緩すぎる」と判断して戻し、本 BUG が再発する
    (BUG-155 §2-3 が絶対期限で踏んだのと同じ形)。

    ⚠️ **コメントの有無だけを見ても意味がない。** 値を変えたのに
    コメントが古いままなら、根拠として機能していない。
    **設定値そのものがコメントに現れていること**まで縛る。
    """

    #: `'anon': '300/hour',` のような行
    _RATE_LINE = re.compile(r"^\s*'(?P<scope>anon|user)':\s*'(?P<rate>[^']+)',")

    @staticmethod
    def _comment_block_above(lines, index):
        """`index` 行目の直上に連なるコメント行を、上から順に返す。"""
        block = []
        i = index - 1
        while i >= 0 and lines[i].strip().startswith('#'):
            block.insert(0, lines[i].strip())
            i -= 1
        return block

    def _rationale_blocks(self, source):
        """scope -> (設定値, 直上のコメント行) を返す。"""
        lines = source.splitlines()
        found = {}
        for idx, line in enumerate(lines):
            m = self._RATE_LINE.match(line)
            if m:
                found[m.group('scope')] = (
                    m.group('rate'),
                    self._comment_block_above(lines, idx),
                )
        return found

    def test_anon_and_user_rates_carry_their_rationale(self):
        source = _SETTINGS_PATH.read_text(encoding='utf-8')
        blocks = self._rationale_blocks(source)

        # 空振り検出: 走査が壊れて何も見つからないと、以下の assert は
        # すべて素通りする。まず「見つかっている」ことを縛る。
        self.assertEqual(
            sorted(blocks), ['anon', 'user'],
            'settings.py から anon / user の rate 行を読み取れていない '
            f'(検出: {sorted(blocks)})。走査が壊れている',
        )

        # anon / user は隣接しているので、根拠コメントは片方の直上に
        # まとまって書かれていてよい。2 つの block を合わせて判定する。
        merged = '\n'.join(
            line for _, comment in blocks.values() for line in comment
        )
        self.assertTrue(
            merged.strip(),
            'anon / user の直前に根拠コメントが 1 行も無い',
        )
        for scope, (rate, _) in blocks.items():
            number = rate.split('/')[0]
            self.assertIn(
                number, merged,
                f"{scope} の設定値 {rate} が根拠コメントに現れていない。"
                '値だけ変えてコメントが古いままになっている',
            )

    def test_the_scan_fails_when_the_rationale_is_removed(self):
        """⚠️ 空振り検出の裏取り。

        コメントを剥がした合成ソースに同じ走査を当て、**ちゃんと落ちる**
        ことを確かめる。これが無いと「走査が何も見ていない」ことに
        気づけない。
        """
        stripped = (
            "REST_FRAMEWORK = {\n"
            "    'DEFAULT_THROTTLE_RATES': {\n"
            "        'anon': '300/hour',\n"
            "        'user': '1200/hour',\n"
            "    },\n"
            "}\n"
        )
        blocks = self._rationale_blocks(stripped)
        self.assertEqual(sorted(blocks), ['anon', 'user'])
        merged = '\n'.join(
            line for _, comment in blocks.values() for line in comment
        )
        self.assertEqual(
            merged.strip(), '',
            '根拠コメントを剥がしたソースからコメントが読み取れてしまった '
            '= 走査が別の何かを拾っている',
        )
