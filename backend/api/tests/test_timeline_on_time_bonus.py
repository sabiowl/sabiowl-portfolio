"""【FEAT-419 (2026-06-10)】予定時刻 ±15 分以内のリアルタイムコインボーナスの契約テスト。

`TimelineCompleteView.post` が以下の条件をすべて満たすときのみ coins +5 し、
`TimelineEvent.on_time_bonus_awarded = True` を立てることを縛る:

- `start_time` が設定されている (終日予定は対象外、Pre-mortem S3)
- `event.date == 完了時点のローカル日付` (過去日付の予定の後追い完了は対象外、Pre-mortem S2)
- `|完了時刻 - start_time| <= 15 分` (Pre-mortem S1: ローカルタイムで判定)

また `TimelineUncompleteView.post` が `on_time_bonus_awarded=True` のとき
coins -5 + フラグ False に戻す対称デクリメント (FEAT-398 同パターン) も縛る。

## 【2026-08-03】壁時計を固定している理由 — 深夜 0 時台の CI 失敗

本テストは `timezone.localtime()` を **JST の当日 12:00 に固定**してから
リクエストを投げる。固定しないと **JST 00:00〜00:10 に走ったときだけ落ちる**。

仕組み:

- テストは `date = now.date()` / `start_time = (now - 10 分).time()` で予定を作る
- now が 00:03 だと `start_time` は **前日の 23:53** だが、`.time()` で日付が
  捨てられ、`date` は当日のままになる
- 実装 ([views/timeline.py](../views/timeline.py)) は
  `combine(event.date, event.start_time)` で予定時刻を復元するので、
  当日 23:53 = **23 時間 50 分先**の予定と解釈され、±15 分の窓から外れる

2026-08-02 23:58 の push で CI がちょうど日付をまたぎ、この 10 分窓に入って
`test_completion_within_10_minutes_awards_bonus` だけが落ちた
(ローカルは 577 件 OK だったため環境差に見えたが、実体は **時刻依存**)。

固定は「1 テストを通すための小細工」ではなく、**この test class 全体から
時刻依存を取り除く**ためのもの。`test_completion_after_20_minutes_no_bonus` は
同じ窓で「窓外だから bonus なし」を **誤った理由で pass** していた
(実際の差は 20 分ではなく 23 時間 40 分だった)。

なお **実装側は仕様どおり**である。23:55 の予定を 00:03 に完了しても bonus が
付かないのは、`event.date == 今日` の同日ガード (Pre-mortem S2「過去日付の予定の
後追い完了は対象外」) が意図的に効いているため。窓が日をまたぐ扱いを変えるかは
別途の product 判断であり、本テストの対象外とする。
"""
from datetime import date as date_type, timedelta
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import override_settings
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import PlayerProfile, TimelineEvent

User = get_user_model()

# patch を当てる前の本物を掴んでおく (import 時点で確定させる)。
_REAL_LOCALTIME = timezone.localtime


_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'api.authentication.ExpiringTokenAuthentication',
        'api.authentication.GuestTokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
}


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class TimelineOnTimeBonusTest(APITestCase):
    """予定時刻 ±15 分以内のコインボーナス契約テスト。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='tester', password='password')
        self.player = PlayerProfile.objects.create(user=self.user)
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # 当日の 12:00 JST に固定する (日付は実際の当日のまま。冒頭 docstring 参照)。
        # 12:00 なら ±20 分しても日をまたがないので、全ケースが決定的になる。
        self.now = _REAL_LOCALTIME().replace(
            hour=12, minute=0, second=0, microsecond=0,
        )

        def _fake_localtime(value=None, tz=None):
            # 引数なしの「今」だけを固定する。値を渡す変換呼び出し
            # (localdate() の内部呼び出し等) は本物に委ねる。
            if value is None:
                return self.now
            return _REAL_LOCALTIME(value, tz)

        patcher = patch(
            'django.utils.timezone.localtime', side_effect=_fake_localtime,
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def _complete_url(self, pk: int) -> str:
        return f'/api/timeline/{pk}/complete/'

    def _uncomplete_url(self, pk: int) -> str:
        return f'/api/timeline/{pk}/uncomplete/'

    def _make_event(self, **kwargs):
        defaults = {
            'player': self.player,
            'title':  'テスト予定',
            'date':   self.now.date(),
        }
        defaults.update(kwargs)
        return TimelineEvent.objects.create(**defaults)

    def test_exact_time_completion_awards_bonus(self):
        """ぴったり完了 (start_time = now) → coins +5, on_time_bonus_awarded=True。"""
        event = self._make_event(start_time=self.now.time())
        initial_coins = self.player.economy.bonus_coins

        response = self.client.post(self._complete_url(event.pk))

        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data['on_time_bonus_awarded'])
        self.assertEqual(response.data['on_time_bonus_coin'], 5)

        self.player.refresh_from_db()
        event.refresh_from_db()
        self.assertEqual(self.player.economy.bonus_coins, initial_coins + 5)
        self.assertTrue(event.on_time_bonus_awarded)

    def test_completion_within_10_minutes_awards_bonus(self):
        """+10 分超過完了 (start_time = now - 10 分) → 範囲内、coins +5。"""
        scheduled = (self.now - timedelta(minutes=10)).time()
        event = self._make_event(start_time=scheduled)
        initial_coins = self.player.economy.bonus_coins

        response = self.client.post(self._complete_url(event.pk))

        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data['on_time_bonus_awarded'])

        self.player.refresh_from_db()
        self.assertEqual(self.player.economy.bonus_coins, initial_coins + 5)

    def test_completion_after_20_minutes_no_bonus(self):
        """+20 分超過完了 (start_time = now - 20 分) → 範囲外、coins +0, awarded=False。"""
        scheduled = (self.now - timedelta(minutes=20)).time()
        event = self._make_event(start_time=scheduled)
        initial_coins = self.player.economy.bonus_coins

        response = self.client.post(self._complete_url(event.pk))

        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.data['on_time_bonus_awarded'])
        self.assertEqual(response.data['on_time_bonus_coin'], 0)

        self.player.refresh_from_db()
        event.refresh_from_db()
        self.assertEqual(self.player.economy.bonus_coins, initial_coins)
        self.assertFalse(event.on_time_bonus_awarded)

    def test_past_date_event_no_bonus(self):
        """過去日付の予定を完了 → date 不一致、coins +0。"""
        event = self._make_event(
            date=self.now.date() - timedelta(days=1),
            start_time=self.now.time(),
        )
        initial_coins = self.player.economy.bonus_coins

        response = self.client.post(self._complete_url(event.pk))

        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.data['on_time_bonus_awarded'])

        self.player.refresh_from_db()
        self.assertEqual(self.player.economy.bonus_coins, initial_coins)

    def test_all_day_event_no_bonus(self):
        """start_time=null の終日予定を完了 → null ガード、coins +0。"""
        event = self._make_event(start_time=None)
        initial_coins = self.player.economy.bonus_coins

        response = self.client.post(self._complete_url(event.pk))

        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.data['on_time_bonus_awarded'])

        self.player.refresh_from_db()
        self.assertEqual(self.player.economy.bonus_coins, initial_coins)

    def test_uncomplete_decrements_coins_symmetrically(self):
        """完了 → coins +5 → 取り消し → coins -5 + awarded=False (対称デクリメント)。"""
        event = self._make_event(start_time=self.now.time())
        initial_coins = self.player.economy.bonus_coins

        self.client.post(self._complete_url(event.pk))
        self.player.refresh_from_db()
        self.assertEqual(self.player.economy.bonus_coins, initial_coins + 5)

        response = self.client.post(self._uncomplete_url(event.pk))
        self.assertEqual(response.status_code, 200)

        self.player.refresh_from_db()
        event.refresh_from_db()
        self.assertEqual(self.player.economy.bonus_coins, initial_coins)
        self.assertFalse(event.on_time_bonus_awarded)
