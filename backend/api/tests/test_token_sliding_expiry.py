"""【BUG-155 (2026-09-11)】トークンの有効期限が「絶対」ではなく「アイドル」であること。

## 何が起きていたか

    TOKEN_EXPIRY_DAYS = 30
    token_age = timezone.now() - token.created
    if token_age > timedelta(days=TOKEN_EXPIRY_DAYS): ...

🔴 **`token.created` を更新するコードが、コードベース全体に 1 行も無かった。**
発行はすべて `Token.objects.get_or_create(user=user)` で、
`get_or_create` は既存行の `created` を触らない。

つまり `created` は**初回ログインの日時で永久に固定**され、
**毎日使っていても 30 日後に必ず 401 になる**。
「最後に使ってから 30 日」ではなく「**初回ログインから 30 日**」だった。

## 🔴 §5 が本体

1〜4 は個別の性質を見るが、**「使い続けても切られる」という症状を
直接再現するのは §5 だけ**である。1〜4 をすべて満たしても、
`created` の更新を忘れれば §5 だけが落ちる。

## ⚠️ 時間の進め方

`freezegun` は入っていないので、**`created` を巻き戻すことで
「1 日経った」を表現する**。

    実時間を進める代わりに created を 1 日戻す
      → age が 1 日ぶん増える = 1 日経ったのと同じ

修正前は `created` が一度も更新されないので巻き戻しが**累積**し、
31 回目に age が 31 日になって落ちる。
修正後は毎回の認証で `created` が現在時刻に戻るので、age は常に 1 日で収まる。
"""

from datetime import timedelta

from django.contrib.auth import get_user_model
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.exceptions import AuthenticationFailed, PermissionDenied

from api.authentication import (
    TOKEN_EXPIRY_DAYS,
    TOKEN_REFRESH_THRESHOLD,
    ExpiringTokenAuthentication,
)

User = get_user_model()


class _TokenAuthTestBase(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            'bug155_user', email='bug155@example.com',
        )
        self.token = Token.objects.create(user=self.user)
        self.auth = ExpiringTokenAuthentication()

    def set_age(self, **delta):
        """`created` を巻き戻して「その分だけ経った」状態にする。"""
        Token.objects.filter(pk=self.token.pk).update(
            created=timezone.now() - timedelta(**delta),
        )

    def reread_created(self):
        return Token.objects.get(pk=self.token.pk).created

    def authenticate(self):
        return self.auth.authenticate_credentials(self.token.key)


# ──────────────────────────────────────────────────────────────────────────
# §1-2 期限そのものは生きている（撤廃していない）
# ──────────────────────────────────────────────────────────────────────────
class ExpiryStillAppliesTest(_TokenAuthTestBase):
    """⚠️ スライディングにしただけで、**放置されたトークンは死ぬ**。"""

    def test_old_token_is_rejected(self):
        self.set_age(days=TOKEN_EXPIRY_DAYS + 10)
        with self.assertRaises(AuthenticationFailed):
            self.authenticate()

    def test_old_token_is_deleted(self):
        self.set_age(days=TOKEN_EXPIRY_DAYS + 10)
        with self.assertRaises(AuthenticationFailed):
            self.authenticate()
        self.assertFalse(Token.objects.filter(pk=self.token.pk).exists())

    def test_exactly_at_the_boundary_still_passes(self):
        """ちょうど 30 日は通る（`>` であって `>=` ではない）。"""
        self.set_age(days=TOKEN_EXPIRY_DAYS, seconds=-60)
        user, _ = self.authenticate()
        self.assertEqual(user, self.user)


# ──────────────────────────────────────────────────────────────────────────
# §3-4 スライディング + 間引き
# ──────────────────────────────────────────────────────────────────────────
class SlidingRefreshTest(_TokenAuthTestBase):

    def test_old_enough_token_gets_its_created_refreshed(self):
        """10 日前のトークンで認証 → 成功し、`created` が現在時刻に更新される。"""
        self.set_age(days=10)
        before = self.reread_created()
        user, _ = self.authenticate()
        self.assertEqual(user, self.user)
        after = self.reread_created()
        self.assertGreater(
            after, before,
            msg='created が更新されていない = 初回ログインから 30 日で必ず切れる',
        )
        self.assertLess(timezone.now() - after, timedelta(minutes=1))

    def test_fresh_token_is_not_rewritten(self):
        """1 時間前のトークンでは `created` を書き換えない（間引きが効いている）。

        🔴 間引かないと**全リクエストが `Token` 行に UPDATE を打つ**。
        ホーム起動時に 10 本以上が並列で飛ぶ設計なので、同じ 1 行への
        書き込みが競合し、**行ロックの待ちを認証層に持ち込む**ことになる。
        """
        self.set_age(hours=1)
        before = self.reread_created()
        self.authenticate()
        self.assertEqual(
            self.reread_created(), before,
            msg='間引きが効いていない = 認証のたびに UPDATE が走る',
        )

    def test_fresh_token_costs_no_extra_query(self):
        """⚠️ クエリ数で縛る。

        値の比較だけだと、**あとで誰かが間引きを外しても
        「同じ値で UPDATE した」ケースを見逃す**。
        """
        self.set_age(hours=1)
        with CaptureQueriesContext(connection) as fresh_ctx:
            self.authenticate()
        self.set_age(days=10)
        with CaptureQueriesContext(connection) as stale_ctx:
            self.authenticate()
        self.assertEqual(
            len(stale_ctx) - len(fresh_ctx), 1,
            msg='更新は 1 クエリ (filter().update()) であること。'
                f'fresh={len(fresh_ctx)} stale={len(stale_ctx)}',
        )

    def test_threshold_is_a_standalone_constant(self):
        """⚠️ 閾値は `TOKEN_EXPIRY_DAYS` から導出しない。

        連動させると「30 日の 1/30」のような導出規則を読む人が生まれ、
        変更時に**両方の意味を考えさせられる**。
        """
        self.assertEqual(TOKEN_REFRESH_THRESHOLD, timedelta(days=1))


# ──────────────────────────────────────────────────────────────────────────
# §5 🔴 本体: 使い続けても切られない
# ──────────────────────────────────────────────────────────────────────────
class DailyUseNeverExpiresTest(_TokenAuthTestBase):
    """🔴 **本 BUG の症状を直接再現するのはこのテストだけ。**

    §1〜§4 をすべて満たしても、`created` の更新を忘れればここだけが落ちる。
    """

    def test_31_days_of_daily_use_still_authenticates(self):
        for day in range(1, TOKEN_EXPIRY_DAYS + 2):   # 1..31
            # 「前回の利用から 1 日経った」
            created = self.reread_created()
            Token.objects.filter(pk=self.token.pk).update(
                created=created - timedelta(days=1),
            )
            try:
                user, _ = self.authenticate()
            except AuthenticationFailed as exc:
                self.fail(
                    f'{day} 日目で切られた: {exc}. '
                    '毎日使っていても初回ログインから 30 日で失効している '
                    '(token.created が更新されていない)',
                )
            self.assertEqual(user, self.user)

    def test_a_month_of_silence_does_expire(self):
        """⚠️ 逆に、**使わなければちゃんと切れる**（意図した性質は残っている）。"""
        self.set_age(days=TOKEN_EXPIRY_DAYS + 1)
        with self.assertRaises(AuthenticationFailed):
            self.authenticate()


# ──────────────────────────────────────────────────────────────────────────
# §6 既存挙動の回帰
# ──────────────────────────────────────────────────────────────────────────
class ExistingBehaviourRegressionTest(_TokenAuthTestBase):

    def test_suspended_user_is_still_refused(self):
        """【FEAT-541】停止ユーザーは期限内でも 403。"""
        self.user.is_active = False
        self.user.save(update_fields=['is_active'])
        with self.assertRaises(PermissionDenied):
            self.authenticate()

    def test_suspended_check_runs_before_the_refresh(self):
        """⚠️ 停止ユーザーのトークンを延命しないこと。"""
        self.user.is_active = False
        self.user.save(update_fields=['is_active'])
        self.set_age(days=10)
        before = self.reread_created()
        with self.assertRaises(PermissionDenied):
            self.authenticate()
        self.assertEqual(self.reread_created(), before)

    def test_unknown_token_is_refused(self):
        with self.assertRaises(AuthenticationFailed):
            self.auth.authenticate_credentials('no-such-token')
