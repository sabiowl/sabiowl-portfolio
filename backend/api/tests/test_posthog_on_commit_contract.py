"""【FEAT-524 Phase 1 (2026-08-08)】PostHog 送信がコミット後に出ることの契約テスト。

## なぜこのテストが要るのか

`apply_count_change` の `with transaction.atomic():` は L440-L604 まで続き、その内側に
PostHog への同期 POST が 5 経路あった (`daily_exp_throttle_reached` /
`diamond_earned` ×2 / `challenge_progress_incremented` / `puzzle_piece_acquired`)。
`timeout=5` × 本数ぶん、`PlayerProfile` の行ロック
(および `increment_challenge_progress` が取る `Challenge` の**全ユーザー共有**行ロック)
を保持したまま SG → US の往復を待っていた。

既存の best-effort 宣言 (`try/except`) は「**失敗**」に対するもので、
「**失敗しないが遅い**」を止めない。FEAT-524 Phase 1 で `transaction.on_commit` に
逃がしたのはこの第 2 の軸のため。

## テストは必ず「対」で書くこと (指示書 §1.4 / Pre-mortem #1)

  ① atomic ブロックの実行中に送信関数が **呼ばれない**
  ② `captureOnCommitCallbacks(execute=True)` で包むと **呼ばれる**

**①だけだと `capture()` の中身を丸ごと消しても緑になる。**
②があって初めて「消したのではなく、コミット後に出している」ことの証明になる。
①には「コールバックが登録されていること」の assert も入れており、
①単独でも「登録すらされていない」状態は検出できる。
"""
import os
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone

from api.constants import DAILY_EXP_THROTTLE_LIMIT
from api.models import Habit, PlayerProfile
from api.services.habit_count_service import apply_count_change

User = get_user_model()

_POST_TARGET = 'api.services.posthog_capture._session.post'
_THROTTLE_EVENT = 'daily_exp_throttle_reached'


def _event_names(mock_post) -> list:
    """mock された送信呼び出しから event 名だけ抜き出す。"""
    return [
        call.kwargs.get('json', {}).get('event')
        for call in mock_post.call_args_list
    ]


class PostHogOnCommitContractTest(TestCase):
    """`capture()` が atomic の外 (コミット後) に送信することを縛る。"""

    def setUp(self):
        self.user = User.objects.create_user('oncommit_user', email='oc@t.com')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='OnCommitTest',
            # 閾値ちょうど → 次の +1 で throttled_now=True になり capture が走る。
            # `daily_exp_count_date` を当日にしないと日跨ぎ扱いで 0 にリセットされる。
            daily_exp_count=DAILY_EXP_THROTTLE_LIMIT,
            daily_exp_count_date=timezone.localdate(),
        )
        self.habit = Habit.objects.create(
            player=self.player, name='on_commit 契約テスト習慣',
            category='運動', difficulty='easy', frequency='daily', habit_type='count',
        )

    # ── ① atomic ブロックの実行中は送信されない ──────────────────────────────

    @patch(_POST_TARGET)
    def test_1_no_http_while_row_locks_are_held(self, mock_post):
        """`apply_count_change` の実行中に HTTP 送信関数が 1 度も呼ばれない。

        = `PlayerProfile` / `Challenge` の行ロックを保持している間、外部 I/O を待たない。
        """
        with patch.dict(os.environ, {'POSTHOG_API_KEY': 'phc_test_key'}, clear=False):
            with self.captureOnCommitCallbacks(execute=False) as callbacks:
                apply_count_change(self.player, self.habit, 1)

                # ブロックを抜ける前 = atomic の内側では 1 本も出ていない
                self.assertFalse(
                    mock_post.called,
                    'atomic ブロック内から PostHog へ HTTP が出ている '
                    '(行ロックを保持したまま外部 I/O を待つ状態)',
                )

        # ここが「①だけでは緑になる」を防ぐ支え:
        # 送信は「消えた」のではなく「コミット後に予約された」ことを見る。
        self.assertGreaterEqual(
            len(callbacks), 1,
            'on_commit コールバックが 1 つも登録されていない '
            '(capture 自体が呼ばれていない可能性がある)',
        )
        # 実行はしていないので、この時点でもまだ送信されていない
        self.assertFalse(mock_post.called)

    # ── ② コミット後には送信される ────────────────────────────────────────

    @patch(_POST_TARGET)
    def test_2_http_is_sent_after_commit(self, mock_post):
        """`captureOnCommitCallbacks(execute=True)` で包むと送信される。

        ①と対にすることで「コミット後に出ている」ことの証明になる。
        """
        with patch.dict(os.environ, {'POSTHOG_API_KEY': 'phc_test_key'}, clear=False):
            with self.captureOnCommitCallbacks(execute=True):
                apply_count_change(self.player, self.habit, 1)

        self.assertTrue(
            mock_post.called,
            'コミット後にも送信されていない = イベントが失われている',
        )
        self.assertIn(
            _THROTTLE_EVENT, _event_names(mock_post),
            f'`{_THROTTLE_EVENT}` がコミット後に送信されるべき',
        )

    # ── 補助: 送信先とタイムアウトの契約 ──────────────────────────────────

    @patch(_POST_TARGET)
    def test_3_timeout_is_tightened_and_session_is_reused(self, mock_post):
        """送信は `(connect, read) = (2.0, 2.0)` で、Session 経由で出る。

        patch 先が `_session.post` である時点で Session 経由は担保されている
        (module 関数 `requests.post` に戻すと本テストの patch が外れて落ちる)。

        【2026-08-08 PM レビュー】connect は 1.0 → 2.0。SG → US の TLS ハンドシェイクが
        1.0s に入らず「初回イベントだけ欠ける」のを避けるため (詳細は
        `posthog_capture._CAPTURE_TIMEOUT` のコメント)。**旧 `timeout=5` より短い**
        ことが契約なので、合計が 5.0 以上になったらこのテストで止める。
        """
        with patch.dict(os.environ, {'POSTHOG_API_KEY': 'phc_test_key'}, clear=False):
            with self.captureOnCommitCallbacks(execute=True):
                apply_count_change(self.player, self.habit, 1)

        self.assertTrue(mock_post.called)
        timeouts = {call.kwargs.get('timeout') for call in mock_post.call_args_list}
        self.assertEqual(
            timeouts, {(2.0, 2.0)},
            '計測イベントの timeout は (connect 2.0, read 2.0)',
        )
        for connect, read in timeouts:
            self.assertLess(
                connect + read, 5.0,
                '合計は旧 timeout=5 より短く保つ (詰める意図そのものが契約)',
            )

    # ── API キー未設定なら on_commit すら登録しない ────────────────────────

    @patch(_POST_TARGET)
    def test_4_no_api_key_registers_no_callback(self, mock_post):
        """`POSTHOG_API_KEY` 未設定 → コールバックを溜めない (完全 no-op を維持)。"""
        with patch.dict(os.environ, {'POSTHOG_API_KEY': ''}, clear=False):
            with self.captureOnCommitCallbacks(execute=True) as callbacks:
                apply_count_change(self.player, self.habit, 1)

        self.assertFalse(mock_post.called)
        # 【2026-08-08 PM レビューで修正】旧実装は `'posthog' in repr(c)` で絞っていたが、
        # lambda の `repr` は `__qualname__` ベースの
        # `<function capture.<locals>.<lambda> at 0x...>` で **module 名を含まない**。
        # つまり常に空リストで、**コールバックが登録されていても通る空振り**だった
        # (契約は上の `assertFalse(mock_post.called)` が押さえていたので穴は無かった)。
        # 本 FEAT が指摘した「①だけだと緑になる」と同じ型なので、実測で縛り直す。
        self.assertEqual(
            len(callbacks), 0,
            f'API キー未設定時は on_commit を登録しない (現状 {len(callbacks)} 件)',
        )
