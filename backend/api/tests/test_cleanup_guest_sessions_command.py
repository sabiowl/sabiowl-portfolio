"""`cleanup_guest_sessions` の削除範囲を縛る契約テスト。

## なぜこのコマンドだけテストするのか

management command 16 本のうち、**本番で自動実行されているものは 1 本も無い**
(build.sh は collectstatic / migrate / showmigrations のみ、render.yaml に cron
定義なし、`call_command` の呼び出しもゼロ)。したがって大半は「テストが無いから
本番が壊れる」経路を持たない。

一方このコマンドは違う。**人が本番に向けて手で叩く削除コマンド**なので、
CI の安全網が一切かからない。日付の境界を 1 つ間違えれば、生きている
ユーザーのデータが消える。戻す手段は Neon の PITR しかない。

## 書いてみて見つかったこと (2026-08-07)

初版のコマンドは docstring に「CASCADE で PlayerProfile + 関連データも
全削除」と書いていたが、**そうなっていなかった**。`on_delete=CASCADE` の
向きが逆で、実際に消えるのはセッションのトークン行だけだった。

本テストがそれを検出し、同日ユーザー判断でコマンド側を PlayerProfile 削除に
修正した。併せて `--dry-run` / `--confirm` を排他必須にしている —— 消える
ものがトークン 1 行からユーザーの全データに変わったため。

## 縛る内容

1. `--days` の境界 —— 閾値ちょうどの行を消さない (`__lt` であること)
2. `--dry-run` が 1 行も消さない / フラグ無しでは実行できないこと
3. 削除範囲が対象ゲストに閉じ、**他プレイヤーに波及しない**こと
4. 既定値が 30 日であること
5. 🔴 **昇格済みユーザー (`user` あり) を巻き込まないこと**

## テストを書くときの落とし穴

`GuestSession.last_active_at` は `auto_now=True`。`obj.last_active_at = ...`
してから `save()` しても **保存時に現在時刻で上書きされる**。古い行を作るには
queryset の `update()` を使う (auto_now を経由しない)。
"""
from datetime import timedelta
from io import StringIO

from django.core.management import CommandError, call_command
from django.test import TestCase
from django.utils import timezone

from api.models import GuestSession, Habit, PlayerProfile


def _make_guest(name, days_inactive):
    """`days_inactive` 日前に最終アクティブだったゲストを作る。

    `last_active_at` は auto_now なので `update()` で直接書く (docstring 参照)。
    """
    player = PlayerProfile.objects.create(name=name)
    session = GuestSession.objects.create(
        token=f'token_{name}', player_profile=player,
    )
    GuestSession.objects.filter(pk=session.pk).update(
        last_active_at=timezone.now() - timedelta(days=days_inactive),
    )
    return player, session


def _run(**kwargs):
    """コマンドを叩いて stdout を返す。

    `--dry-run` / `--confirm` は排他必須なので、dry_run を渡さない限り
    confirm を自動で付ける (各テストの意図をノイズで埋めないため)。
    """
    if not kwargs.get('dry_run'):
        kwargs.setdefault('confirm', True)
    out = StringIO()
    call_command('cleanup_guest_sessions', stdout=out, **kwargs)
    return out.getvalue()


class CleanupGuestSessionsBoundaryTest(TestCase):
    def test_default_threshold_is_30_days(self):
        """既定は 30 日。29 日は残り、31 日は消える。

        既定値を変えるときは、この 2 行がその判断の記録になる。
        """
        _make_guest('recent', days_inactive=29)
        _make_guest('stale', days_inactive=31)

        _run()

        remaining = set(GuestSession.objects.values_list('token', flat=True))
        self.assertEqual(remaining, {'token_recent'})

    def test_boundary_row_is_not_deleted(self):
        """閾値ちょうどの行は消さない (`__lt` であること)。

        `__lte` に変わると、ちょうど 30 日目のユーザーが巻き込まれる。
        1 日ぶんの差だが、消えるのは本人の全データなので影響は 1 日ぶんでは
        済まない。
        """
        player = PlayerProfile.objects.create(name='exactly_at_threshold')
        session = GuestSession.objects.create(
            token='token_boundary', player_profile=player,
        )
        # 「ちょうど 30 日前」を作る。判定時刻とのズレで揺れないよう、
        # コマンドが使う now より確実に後ろ (= 消えない側) に 1 秒寄せる。
        GuestSession.objects.filter(pk=session.pk).update(
            last_active_at=timezone.now() - timedelta(days=30) + timedelta(seconds=1),
        )

        _run(days=30)

        self.assertTrue(
            GuestSession.objects.filter(pk=session.pk).exists(),
            '閾値ちょうどのセッションが削除された。'
            'フィルタが __lt から __lte に変わっていないか確認すること。',
        )

    def test_custom_days_is_respected(self):
        """`--days` が実際に効くこと。"""
        _make_guest('d10', days_inactive=10)
        _make_guest('d20', days_inactive=20)

        _run(days=14)

        remaining = set(GuestSession.objects.values_list('token', flat=True))
        self.assertEqual(remaining, {'token_d10'})

    def test_dry_run_deletes_nothing(self):
        """`--dry-run` は 1 行も消さない。

        本番に向けて叩く前の確認手段なので、ここが壊れると
        「確認したつもりで消えていた」になる。
        """
        _make_guest('stale', days_inactive=90)

        output = _run(days=30, dry_run=True)

        self.assertEqual(GuestSession.objects.count(), 1)
        self.assertEqual(PlayerProfile.objects.count(), 1)
        self.assertIn('dry-run', output)


class CleanupGuestSessionsCascadeTest(TestCase):
    """CASCADE の**範囲**を縛る。広すぎても狭すぎても事故になる。"""

    def setUp(self):
        self.stale_player, _ = _make_guest('stale', days_inactive=90)
        self.active_player, _ = _make_guest('active', days_inactive=1)
        # ゲストではない通常プレイヤー (GuestSession を持たない)
        self.normal_player = PlayerProfile.objects.create(name='normal')

        for player, name in (
            (self.stale_player, 'stale habit'),
            (self.active_player, 'active habit'),
            (self.normal_player, 'normal habit'),
        ):
            Habit.objects.create(player=player, name=name)

    def test_cascade_removes_the_guests_own_data(self):
        """対象ゲストの PlayerProfile と配下の習慣まで消えること。

        これが本コマンドの存在理由 (SEC-08 / H-03 = 期限切れゲストデータの
        purge)。2026-08-07 まで**成立していなかった**契約なので、退行したら
        すぐ気付けるようにここで縛る。

        `on_delete=CASCADE` は `GuestSession.player_profile` 側に付いており、
        CASCADE は **PlayerProfile → GuestSession** の向きにしか流れない
        (`api/models/auth.py`)。したがって削除対象は GuestSession ではなく
        **PlayerProfile** でなければならない。逆に書き換えると、トークン行
        だけ消えて本体が孤児として残る —— それが元の不具合だった。
        """
        _run(days=30)

        self.assertFalse(
            PlayerProfile.objects.filter(pk=self.stale_player.pk).exists(),
            '対象ゲストの PlayerProfile が残っている',
        )
        self.assertFalse(
            Habit.objects.filter(name='stale habit').exists(),
            '対象ゲストの習慣が残っている (CASCADE が効いていない)',
        )

    def test_does_not_reach_other_players(self):
        """**本命**。対象外のプレイヤーに波及しないこと。

        フィルタを 1 箇所書き間違えると、ここが無言で崩れる。
        非対象ゲストと、そもそもゲストでない通常ユーザーの両方を見る。

        上の既知不具合が直っても直らなくても、この契約は変わらない。
        """
        _run(days=30)

        self.assertTrue(
            PlayerProfile.objects.filter(pk=self.active_player.pk).exists(),
            'アクティブなゲストが削除された',
        )
        self.assertTrue(
            PlayerProfile.objects.filter(pk=self.normal_player.pk).exists(),
            'ゲストでない通常プレイヤーが削除された',
        )
        self.assertTrue(
            GuestSession.objects.filter(player_profile=self.active_player).exists(),
            'アクティブなゲストのセッションが削除された',
        )
        surviving = set(Habit.objects.values_list('name', flat=True))
        self.assertLessEqual(
            {'active habit', 'normal habit'}, surviving,
            '対象外プレイヤーの習慣が巻き込まれている',
        )

    def test_target_session_row_is_removed(self):
        """対象セッションのトークン行も (CASCADE 経由で) 消えること。

        PlayerProfile を消せば CASCADE で落ちるはずだが、認証が無効化される
        ことは独立して確認する価値がある —— 消し漏れると、消えたはずの
        アカウントのトークンが生き残る。
        """
        _run(days=30)

        self.assertFalse(
            GuestSession.objects.filter(player_profile=self.stale_player).exists(),
            '対象ゲストのセッションが消えていない。認証が無効化されていない。',
        )

    def test_no_target_is_a_no_op(self):
        """対象ゼロのとき何も消さない。"""
        _run(days=365)

        self.assertEqual(PlayerProfile.objects.count(), 3)
        self.assertEqual(Habit.objects.count(), 3)
        self.assertEqual(GuestSession.objects.count(), 2)


class PromotedUserGuardTest(TestCase):
    """🔴 **最重要**。昇格済みユーザーを巻き込まないこと。

    ## なぜこの guard が要るか

    正式登録時、`views/auth/social.py` は `guest_session.delete()` を
    **savepoint の外**で呼んでおり、コード上のコメントにもこう書かれている:

    > 【BUG-67】savepoint 確定後の副作用処理。GuestSession 削除と
    > Token 発行は savepoint 外でも問題なし（失敗しても致命的ではない）。

    つまり **昇格済み (user あり) なのにセッション行が残る状態が構造的に
    起こりうる**。旧実装はトークン 1 行しか消さなかったのでこれは無害だったが、
    PlayerProfile を消す今は **本物の登録ユーザーのアカウントが丸ごと消える**。

    フィルタから `user__isnull=True` が落ちた瞬間にここが赤くなる。
    """

    def setUp(self):
        from django.contrib.auth.models import User

        # 昇格済みなのにセッションが残ってしまったユーザー
        self.promoted = PlayerProfile.objects.create(
            name='promoted',
            user=User.objects.create_user('promoted_user', email='p@example.com'),
        )
        session = GuestSession.objects.create(
            token='token_promoted', player_profile=self.promoted,
        )
        GuestSession.objects.filter(pk=session.pk).update(
            last_active_at=timezone.now() - timedelta(days=90),
        )
        Habit.objects.create(player=self.promoted, name='promoted habit')

    def test_promoted_account_is_never_deleted(self):
        _run(days=30)

        self.assertTrue(
            PlayerProfile.objects.filter(pk=self.promoted.pk).exists(),
            '🔴 昇格済みユーザーのアカウントが削除された。'
            'フィルタから user__isnull=True が落ちていないか確認すること。',
        )
        self.assertTrue(
            Habit.objects.filter(name='promoted habit').exists(),
            '🔴 昇格済みユーザーの習慣が削除された',
        )

    def test_leftover_session_of_promoted_user_is_cleaned_up(self):
        """アカウントは残しつつ、死んだセッション行だけは片付けること。

        昇格時に消し損ねた認証情報を放置すると、古いゲストトークンで
        API を叩けてしまう。本体を消さずにここだけ回収する。
        """
        output = _run(days=30)

        self.assertFalse(
            GuestSession.objects.filter(player_profile=self.promoted).exists(),
            '昇格済みユーザーに残ったセッションが片付いていない',
        )
        self.assertIn('昇格済み', output)


class CleanupGuestSessionsFlagTest(TestCase):
    """`--dry-run` / `--confirm` の排他必須と `--days` の下限。"""

    def setUp(self):
        _make_guest('stale', days_inactive=90)

    def test_requires_dry_run_or_confirm(self):
        """フラグ無しでは実行できない。

        旧実装はフラグ無しでいきなり削除していた。消えるのがトークン 1 行の
        うちは許容できたが、いまはユーザーの全データが消える。
        """
        with self.assertRaises(CommandError):
            call_command('cleanup_guest_sessions', stdout=StringIO())

        self.assertEqual(PlayerProfile.objects.count(), 1)

    def test_dry_run_and_confirm_are_mutually_exclusive(self):
        with self.assertRaises(CommandError):
            call_command(
                'cleanup_guest_sessions',
                dry_run=True, confirm=True, stdout=StringIO(),
            )

        self.assertEqual(PlayerProfile.objects.count(), 1)

    def test_days_below_one_is_rejected(self):
        """`--days 0` / 負値を弾く。

        0 は「最終アクティブが現在時刻より前の全ゲスト」= 実質全件削除。
        負値は閾値が未来になり、**アクティブなゲストまで巻き込む**。
        どちらもタイポで到達しうるので入口で止める。
        """
        for bad in (0, -1):
            with self.subTest(days=bad):
                with self.assertRaises(CommandError):
                    call_command(
                        'cleanup_guest_sessions',
                        days=bad, confirm=True, stdout=StringIO(),
                    )

        self.assertEqual(PlayerProfile.objects.count(), 1)
