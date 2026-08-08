"""`delete_user` の三重ガードを縛る契約テスト。

## なぜテストするのか

このコマンドは `User.objects.all().delete()` を持つ。本番 DB に届いたら
全ユーザーが消える。それを防いでいるのが SEC-15 M-01 の三重ガードで、

  1. `DEBUG=True` であること
  2. SQLite 接続であること
  3. `--all` 指定時は `--confirm` も必須

**ガードは「効かなくなったこと」が事故の瞬間まで分からない種類のコード**である。
`DevLoginView` と同じ設計思想 (本番 DB に絶対に届かない) だが、そちらと違って
このコマンドにはテストが 1 件も無かった。

たとえば `and` を `or` に書き換えてしまっても、開発環境では
`DEBUG=True and SQLite` が両方成立しているので**何も起きない**。
壊れていることに気付けるのは本番で叩いたときだけになる。

## テストの作り方

`override_settings` で `DEBUG` / `DATABASES` を差し替え、ガードが弾く側 / 通す側の
両方に倒れることを確認する。実際に PostgreSQL へ繋ぐ必要はない
——— コマンドが見ているのは `DATABASES['default']['ENGINE']` の文字列だけ。

## 🔴 ENGINE は「通す側」でも必ず明示する (2026-08-08 修正)

初版は「ガードを通す側」のテストで `DEBUG=True` だけを override し、ENGINE は
実行環境まかせにしていた。ローカルのテスト DB は SQLite なのでガード 2 を素通りし、
6 件すべて pass していた。

**CI のテスト DB は PostgreSQL なので、同じ 6 件が全滅した。**
コマンドが「SQLite 以外は拒否」する以上、ENGINE を書かないテストは
「どの DB で走ったか」に結果が左右される。

さらに悪いことに、`test_no_argument_deletes_nothing` のような
「削除されないこと」を確かめるテストは、ガードに弾かれても assert が通る。
**理由が違うのに緑になる**ので、壊れていることに気付けない。

対策として `_with_engine()` を用意し、全テストが ENGINE を明示する形に統一した。
ガードが見る値をテスト側で固定すれば、実行環境の DB に依存しなくなる。
"""
from io import StringIO

from django.contrib.auth.models import User
from django.core.management import call_command
from django.test import TestCase, override_settings

_SQLITE_ENGINE   = 'django.db.backends.sqlite3'
_POSTGRES_ENGINE = 'django.db.backends.postgresql'


def _with_engine(engine: str):
    """ガードが見る `DATABASES['default']['ENGINE']` を固定する `override_settings`。

    実接続はテスト開始時に確立済みのものが使われ続けるため、ここで ENGINE を
    偽ってもクエリの発行先は変わらない (コマンドが読むのは設定値の文字列だけ)。

    ## NAME をあえて実値にしない理由

    実 `DATABASES` を deepcopy すると、**テスト DB 名 (`test_*`) ではなく
    settings 読み込み時の DB 名**が入る。デコレータの引数は import 時に
    評価されるため、`setup_databases()` が NAME を書き換える前の値を掴むからだ。

    現状の Django は `DATABASES` の override で接続を張り直さないので実害は
    出ないが、「テスト中の settings に開発 DB 名が載っている」状態は残したくない。
    そこで **存在しない DB 名** を置く。万一この前提が崩れて新規接続が試みられた
    場合、静かに開発 DB を触るのではなく接続エラーで落ちる。
    """
    return override_settings(DATABASES={
        'default': {
            'ENGINE': engine,
            # 実在しない名前。接続が張られたら落ちて気付けるようにするための番人。
            'NAME': 'nonexistent-db-for-engine-guard-test',
        }
    })


def _run(*args, **kwargs):
    """stdout / stderr を捕まえて (出力, エラー出力) を返す。"""
    out, err = StringIO(), StringIO()
    call_command('delete_user', *args, stdout=out, stderr=err, **kwargs)
    return out.getvalue(), err.getvalue()


class DeleteUserGuardTest(TestCase):
    """三重ガードの各条件が単独で効くこと。"""

    def setUp(self):
        User.objects.create_user(username='alice', email='alice@example.com')
        User.objects.create_user(username='bob', email='bob@example.com')

    # ── ガード 1: DEBUG ──────────────────────────────────────────
    # ENGINE は SQLite に固定する。そうしないと CI (PostgreSQL) では
    # 「ガード 2 でも弾かれていた」状態になり、DEBUG 単独の検証にならない。
    @_with_engine(_SQLITE_ENGINE)
    @override_settings(DEBUG=False)
    def test_refuses_when_debug_is_false(self):
        """DEBUG=False では何もしない。

        本番 Render は DEBUG=False なので、ここが第一の防波堤になる。
        """
        _, err = _run('--all', '--confirm')

        self.assertEqual(User.objects.count(), 2, 'DEBUG=False でユーザーが削除された')
        self.assertIn('DEBUG=True', err)

    # ── ガード 2: SQLite ─────────────────────────────────────────
    @_with_engine(_POSTGRES_ENGINE)
    @override_settings(DEBUG=True)
    def test_refuses_on_postgresql_even_with_debug_true(self):
        """DEBUG=True でも PostgreSQL なら拒否する。

        「ローカルから本番 DB を向いてしまった」ケースを想定した
        二枚目の防波堤。2026-07-06 に実際に踏んだ事故
        (doc/postmortem/20260706_prod_db_schema_drift.md) と同じ形。
        """
        _, err = _run('--all', '--confirm')

        self.assertEqual(User.objects.count(), 2, 'PostgreSQL 接続でユーザーが削除された')
        self.assertIn('SQLite', err)

    # ── ガード 3: --confirm ──────────────────────────────────────
    @_with_engine(_SQLITE_ENGINE)
    @override_settings(DEBUG=True)
    def test_all_without_confirm_is_refused(self):
        """`--all` 単独では実行しない (タイポ事故防止)。"""
        _, err = _run('--all')

        self.assertEqual(User.objects.count(), 2, '--confirm 無しで全削除された')
        self.assertIn('--confirm', err)

    @_with_engine(_SQLITE_ENGINE)
    @override_settings(DEBUG=True)
    def test_all_with_confirm_deletes_everything(self):
        """3 条件が揃ったときだけ全削除が走る。

        ガードが「常に拒否」になっていないこと (= 過剰防御でコマンドが
        死んでいないこと) の確認も兼ねる。
        """
        out, _ = _run('--all', '--confirm')

        self.assertEqual(User.objects.count(), 0)
        self.assertIn('削除しました', out)


@_with_engine(_SQLITE_ENGINE)
@override_settings(DEBUG=True)
class DeleteUserLookupTest(TestCase):
    """単一削除の照合範囲。"""

    def setUp(self):
        User.objects.create_user(username='alice', email='alice@example.com')
        User.objects.create_user(username='bob', email='bob@example.com')

    def test_deletes_by_exact_username(self):
        _run('alice')

        self.assertEqual(
            set(User.objects.values_list('username', flat=True)), {'bob'},
        )

    def test_deletes_by_email(self):
        _run('bob@example.com')

        self.assertEqual(
            set(User.objects.values_list('username', flat=True)), {'alice'},
        )

    def test_unknown_name_deletes_nothing(self):
        _, err = _run('carol')

        self.assertEqual(User.objects.count(), 2)
        self.assertIn('見つかりません', err)

    def test_no_argument_deletes_nothing(self):
        """引数なしで叩いても何も消さない。"""
        _run()

        self.assertEqual(User.objects.count(), 2)

    def test_partial_match_deletes_multiple_users(self):
        """⚠️ **部分一致で複数消える**。現状の挙動を記録しておく。

        照合は 3 つの OR で組まれている (`delete_user.py:63-67`):

            username__iexact | email__iexact | username__icontains

        3 つ目が **部分一致**なので、`delete_user a` のような短い引数は
        `a` を含む全ユーザーを消す。docstring は「単一ユーザー削除」と
        書いているが、実際は単一とは限らない。

        削除前に対象を 1 件ずつ表示はするものの、確認プロンプトは無く
        そのまま消える。

        DEBUG + SQLite ガードがあるので**本番には届かない**。被害は
        開発者のローカルデータに限られるため、挙動を変えるかは仕様判断
        として保留し、ここでは事実を記録するに留める。
        """
        _run('li')   # alice にのみ含まれる部分文字列

        self.assertEqual(
            set(User.objects.values_list('username', flat=True)), {'bob'},
            '部分一致の挙動が変わった。docstring どおり完全一致に直したなら'
            ' 本テストを「消えないこと」の確認に書き換えること。',
        )
