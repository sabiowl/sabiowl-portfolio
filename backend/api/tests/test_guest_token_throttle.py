"""【FEAT-392 (2026-05-30)】GuestTokenAuthentication の 5 分間隔バッチ化 契約テスト 3 件。

arch_review 20260530 §P1-2 で指摘された「すべての API リクエストで DB write」問題を
構造解消する。3 シナリオで「いつ save するか / いつ skip するか」の境界を縛る。

テスト方針:
  APIRequestFactory で GuestToken ヘッダー付きリクエストを生成し、
  GuestTokenAuthentication.authenticate() を直接呼び出す。
  HTTP ルーティング + 権限クラス依存を排除し、認証ロジック単体を検証する。

  注: GuestSession.last_active_at = DateTimeField(auto_now=True) のため
  インスタンスへの直接代入は save() 時に auto_now が上書きする。
  テスト専用の時刻設定には QuerySet.update() (auto_now をバイパス) を使用する。
"""
from datetime import timedelta
from unittest.mock import patch

from django.test import TestCase
from django.utils import timezone
from rest_framework.request import Request
from rest_framework.test import APIRequestFactory

from api.authentication import GuestTokenAuthentication
from api.models import GuestSession, PlayerProfile


class GuestTokenAuthThrottleTest(TestCase):
    """5min バッチ境界を縛る契約テスト 3 件。"""

    def setUp(self):
        # GuestSession には PlayerProfile の FK が必要なため先に作成
        self.player = PlayerProfile.objects.create(name='GuestThrottleTestPlayer')
        self.guest = GuestSession.objects.create(
            token='test_throttle_token_abc',
            player_profile=self.player,
        )

    def _run_authenticate(self):
        """GuestTokenAuthentication.authenticate() を直接呼び出すヘルパー。

        APIRequestFactory で GuestToken ヘッダー付きリクエストを生成し、
        authenticate() 内部の 5 分判定ロジックを実際に通す。
        """
        factory = APIRequestFactory()
        raw_request = factory.get(
            '/',
            HTTP_AUTHORIZATION=f'GuestToken {self.guest.token}',
        )
        drf_request = Request(raw_request)
        auth = GuestTokenAuthentication()
        return auth.authenticate(drf_request)

    def _set_last_active_at(self, dt):
        """auto_now=True をバイパスして last_active_at を直接設定するヘルパー。

        GuestSession.last_active_at は DateTimeField(auto_now=True) のため、
        インスタンスの save() では値を制御できない。
        QuerySet.update() は auto_now を適用しないため、テスト用の時刻設定に使用する。
        """
        GuestSession.objects.filter(pk=self.guest.pk).update(last_active_at=dt)
        self.guest.refresh_from_db()

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 1: 初回リクエスト相当 (長時間アクティブなし) で save される
    # ─────────────────────────────────────────────────────────────────
    def test_long_idle_triggers_save(self):
        """長時間アクティブなし (6 分超) の初回 API call で save される。

        GuestSession.last_active_at は auto_now=True のため None に設定不可。
        「長時間放置後の初回リクエスト」を 6 分前の last_active_at で等価表現する。
        この条件で authenticate() が save() を呼び last_active_at が更新されることを確認。
        """
        # 6 分前に最後のアクティビティ (放置 / 初回等価)
        old_time = timezone.now() - timedelta(minutes=6)
        self._set_last_active_at(old_time)
        self.assertAlmostEqual(
            self.guest.last_active_at.timestamp(),
            old_time.timestamp(),
            delta=2,
            msg='前提: last_active_at が 6 分前に設定済のはず',
        )

        # authenticate() を実行
        result = self._run_authenticate()
        self.assertIsNotNone(result, 'authenticate が (None, guest_session) を返すはず')

        # last_active_at が更新された
        self.guest.refresh_from_db()
        self.assertGreater(
            self.guest.last_active_at.timestamp(),
            old_time.timestamp(),
            msg='6 分超の場合は last_active_at が now に更新されるはず (save 実行)',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 2: 5 分以内の連続リクエストでは save しない
    # ─────────────────────────────────────────────────────────────────
    def test_within_5min_no_save(self):
        """直近 1 分前に save 済の状態では、authenticate() が save を呼ばない。

        DB write が skip されることで 1,000 ゲスト × 100 API call/日 の
        100,000 UPDATE → ~12,000 UPDATE への削減が実現する (88% 減)。
        """
        # 直近 1 分前に save 済の状態を QuerySet.update で作る
        now = timezone.now()
        recent_time = now - timedelta(minutes=1)
        self._set_last_active_at(recent_time)

        # authenticate() の中で GuestSession.save が呼ばれないことを mock で確認
        with patch.object(GuestSession, 'save') as mock_save:
            self._run_authenticate()

        mock_save.assert_not_called()

        # last_active_at も変わっていない (recent_time のまま)
        self.guest.refresh_from_db()
        self.assertAlmostEqual(
            self.guest.last_active_at.timestamp(),
            recent_time.timestamp(),
            delta=2,
            msg='5 分以内は last_active_at が更新されないはず',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ 3: 5 分超のリクエストでは再度 save (バッチ境界)
    # ─────────────────────────────────────────────────────────────────
    def test_after_5min_saves_again(self):
        """最終 save から 6 分後の authenticate() は再度 save する。

        5 分 (300 秒) をバッチ境界として、超過した場合のみ DB write を実行。
        この境界テストが通ることで「~12 UPDATE/日 (1 セッション)」の上限が担保される。
        """
        # 6 分前に save 済の状態を作る
        old_time = timezone.now() - timedelta(minutes=6)
        self._set_last_active_at(old_time)

        # authenticate() を実行
        self._run_authenticate()

        # last_active_at が更新された (old_time より新しい)
        self.guest.refresh_from_db()
        self.assertGreater(
            self.guest.last_active_at.timestamp(),
            old_time.timestamp(),
            msg='5 分超の場合は last_active_at が更新されるはず (save 実行)',
        )
