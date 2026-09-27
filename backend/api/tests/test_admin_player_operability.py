"""【BUG-152 / BUG-153 / FEAT-540 (2026-09-06)】`PlayerProfileAdmin` の運用性。

どれも「admin で運営が困る」話で、触るファイルが同じなので 1 本にまとめた。

| # | 縛るもの |
|---|---|
| §1 | **superuser がプレイヤーを削除できる**（BUG-152） |
| §2 | **state 行の単独削除は依然として塞がっている**（BUG-152 §7、緩めない） |
| §2.5 | 🔴 **ブロックしうる model を発見して、列挙を検算する**（BUG-153 の本体） |
| §3 | 除外集合が **model クラス由来**である（日本語リテラルで引き算していない） |
| §4 | 削除確認画面に「実ユーザーの退会には使わない」注意が出る |
| §5 | 一覧に「最終アクティブ」が出て、値が `last_achievement_check_at` と一致する |
| §6 | 🔴 **`User.last_login` を最終アクティブとして使っていない**（走査） |
| §7 | 一覧のクエリ数が固定されている（N+1 の回帰検出） |

## 🔴 §2.5 が後から足された理由（BUG-153）

BUG-152 のガードは §3 の 3 本（改名追従 / リテラル禁止 / 自動導出禁止）だけで、
**どれも「リストの中身の質」を守るもの**だった。
「**そのリストで全部か**」を問うものが 1 つも無く、しかも当時の

    assertEqual(len(CASCADE_DELETABLE_STATE_MODELS), 5)
    assertEqual(set(CASCADE_DELETABLE_STATE_MODELS), {...同じ 5 個...})

は**リストがリスト自身と一致することを確かめていた**（トートロジー）。
結果、`ReadOnlyAdminMixin` 経由の 3 model が漏れたまま緑だった。

**§2.5 はリストを外から検算する。** 走査ロジックは**テスト側にしか置かない**
—— 発見はテストの仕事、決定は人間の仕事。

## 🔴 §6 がソース走査である理由

`User.last_login` は**このアプリでは一度も更新されない**（DRF の Token 認証は
`last_login` を触らない）。にもかかわらず**一見もっとも素直な選択肢**なので、
将来「`last_login` のほうが自然では」と書き換えられうる。
そのとき**例外も警告も出ず、ただ全員が空欄になる**。
値の比較では捕まらない（どちらも None になりうる）ので、走査で縛る。
"""

import re
from pathlib import Path

from django.contrib import admin as django_admin
from django.contrib.auth import get_user_model
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from django.utils import timezone

from django.db import models

from api.admin import (
    CASCADE_BLOCKING_INTENTIONAL, CASCADE_DELETABLE_MODELS, PlayerProfileAdmin,
)
from api.models import (
    Challenge, ChallengeParticipation, GachaReward, IAPReceipt,
    PendingDuplicateReward,
    PlayerBattleState, PlayerEconomyState, PlayerGachaStatus, PlayerProfile,
    PlayerSettings, PlayerStreakState,
)

User = get_user_model()

_BACKEND = Path(__file__).resolve().parents[2]

# 【FEAT-535 CI hotfix と同じ理由】staticfiles を素の storage に落とす。
# 本番設定は WhiteNoise の manifest storage で、admin テンプレートの
# `{% static %}` が collectstatic 済みの STATIC_ROOT を前提にする。
# CI は collectstatic を回さないので 500 になる (ローカルだけ緑になる)。
_PLAIN_STATIC = override_settings(STORAGES={
    'default': {'BACKEND': 'django.core.files.storage.FileSystemStorage'},
    'staticfiles': {
        'BACKEND': 'django.contrib.staticfiles.storage.StaticFilesStorage',
    },
})


class _AdminHttpTestCase(TestCase):
    """admin に HTTP でログインして操作するための土台。

    admin MFA は**無効化しない**。gate ごと切ると「MFA を通った後の画面」を
    見たことにならないので、session に verified タイムスタンプを入れて通す。
    """

    def _login(self):
        from api.middleware.admin_mfa import MFA_SESSION_KEY

        # `force_login` を使うのでパスワードは要らない。実値を書くと
        # Portfolio Publish Gate の「汎用パスワード実値」に引っかかる。
        self.admin_user = User.objects.create_user(
            'bug152_super', email='bug152super@example.com',
            is_staff=True, is_superuser=True,
        )
        self.client.force_login(self.admin_user)
        session = self.client.session
        session[MFA_SESSION_KEY] = timezone.now().isoformat()
        session.save()

    def _make_player(self, suffix='1'):
        user = User.objects.create_user(
            f'bug152_p{suffix}', email=f'bug152p{suffix}@example.com',
        )
        player = PlayerProfile.objects.create(user=user, name=f'テスト{suffix}')
        # 5 つの state 行を実体化しておく (property の get_or_create 経由)
        player.economy.save()
        player.battle.save()
        player.streak.save()
        player.settings.save()
        PlayerGachaStatus.objects.get_or_create(player=player)
        self._make_dependent_rows(player, suffix)
        return player

    def _make_dependent_rows(self, player, suffix):
        """🔴 【BUG-153】従属行を**実際に作る**。

        Django の `get_deleted_objects` は `perms_needed` に
        **実際に行が存在する model だけ**を入れる
        (`format_callback` が collector の集めた**インスタンス**ごとに呼ばれる)。

        つまり行を作らずに削除テストを書くと、**新しく足した 3 model を
        1 度も踏まないまま緑になる** —— BUG-152 のテストがまさにその状態で、
        「チャレンジ未参加のユーザー」しか作っていなかったために
        `ChallengeParticipation` の漏れを検出できなかった。
        """
        challenge = Challenge.objects.create(
            title=f'テスト月間{suffix}', category='運動',
            target_count_gold=10,
            start_date=timezone.localdate(),
            end_date=timezone.localdate() + timezone.timedelta(days=30),
        )
        ChallengeParticipation.objects.create(player=player, challenge=challenge)

        IAPReceipt.objects.create(
            player=player, event_id=f'bug153-event-{suffix}',
            event_type='NON_RENEWING_PURCHASE',
            product_id='diamond_pack_120', store='sandbox',
            raw_payload={},
        )

        reward = GachaReward.objects.create(
            name=f'テスト報酬{suffix}', rarity='SSR', reward_type='diamond',
            value=100,
        )
        PendingDuplicateReward.objects.create(
            player=player, reward=reward,
            expires_at=timezone.now() + timezone.timedelta(days=30),
        )


# ──────────────────────────────────────────────────────────────────────────
# §1 superuser がプレイヤーを削除できる (BUG-152、現状 red)
# ──────────────────────────────────────────────────────────────────────────
@_PLAIN_STATIC
class PlayerDeleteThroughAdminTest(_AdminHttpTestCase):
    """🔴 現状のコードで **red** になるテスト。

    `NoDeleteAdminMixin` を付けた 5 つの state admin の
    `has_delete_permission` がハードコードで `False` なので、
    Django の `get_deleted_objects` が**カスケード対象の削除権限**を検査した
    ところで `perms_needed` に入り、**superuser でも親の削除が止まる**。
    """

    def setUp(self):
        self._login()
        self.player = self._make_player()
        self.url = reverse('admin:api_playerprofile_delete', args=[self.player.pk])

    def test_perms_needed_is_empty_for_superuser(self):
        """`perms_needed` が空になる（画面の文言ではなく実値で見る）。

        ⚠️ 確認画面の HTML 文字列で判定すると、**削除対象の一覧にも
        同じ verbose_name が出る**ので区別できないうえ、言語設定にも依存する。
        `get_deleted_objects` の戻り値そのものを見る。
        """
        request = _fake_request(self.admin_user)
        model_admin = django_admin.site._registry[PlayerProfile]
        _, _, perms_needed, _ = model_admin.get_deleted_objects(
            [self.player], request,
        )
        self.assertEqual(
            set(perms_needed), set(),
            msg='カスケード対象の削除権限で止められている: '
                f'{sorted(str(n) for n in perms_needed)}',
        )

    def test_superuser_can_delete_player(self):
        """実際に POST して消える。"""
        pk = self.player.pk
        res = self.client.post(self.url, {'post': 'yes'})
        self.assertEqual(res.status_code, 302)
        self.assertFalse(PlayerProfile.objects.filter(pk=pk).exists())

    def test_cascade_removes_every_dependent_row(self):
        """削除後、従属する行がすべて消えている (cascade が効いている)。

        ⚠️ 【BUG-153】旧名は `test_cascade_removes_all_five_state_rows` だった。
        「5 つ」も「state」も嘘になったので**名前ごと直した** ——
        実際にブロックしていたのは 8 model で、うち 3 つは state 行ではない。
        名前に数字を埋めると、増えたときに**名前だけが古いまま残る**。
        """
        pk = self.player.pk
        self.client.post(self.url, {'post': 'yes'})
        for model in CASCADE_DELETABLE_MODELS:
            self.assertFalse(
                model.objects.filter(player_id=pk).exists(),
                msg=f'{model.__name__} が残っている',
            )

    def test_protected_is_untouched(self):
        """⚠️ `protected` には手を出していない。

        `PROTECT` な FK は別の仕組みで、これは**正しく止めるべきもの**である。
        `perms_needed` だけを削っていることを、戻り値の 4 番目が
        `super()` のものと同一であることで見る。
        """
        request = _fake_request(self.admin_user)
        model_admin = django_admin.site._registry[PlayerProfile]
        objs = [self.player]
        _, _, _, protected = model_admin.get_deleted_objects(objs, request)
        _, _, _, base_protected = super(
            PlayerProfileAdmin, model_admin,
        ).get_deleted_objects(objs, request)
        self.assertEqual(list(protected), list(base_protected))


# ──────────────────────────────────────────────────────────────────────────
# §2 state 行の単独削除は依然として塞がっている (BUG-152 §7)
# ──────────────────────────────────────────────────────────────────────────
class StateRowsStillUndeletableTest(TestCase):
    """🔴 `NoDeleteAdminMixin` 自体は緩めない。

    塞ぎたいのは「state 行だけ消えて、property の `get_or_create` で
    累計 0 の新しい行が生える」ケースであって、
    「プレイヤーごと消えて state も一緒に消える」ケースではない。
    """

    def test_each_state_admin_still_refuses_delete(self):
        for model in CASCADE_DELETABLE_MODELS:
            model_admin = django_admin.site._registry[model]
            self.assertFalse(
                model_admin.has_delete_permission(_fake_request(None)),
                msg=f'{model.__name__} の単独削除が通ってしまう',
            )

    def test_bulk_delete_action_is_not_offered_for_players(self):
        """🔴 一括削除は開けない。

        BUG-152 の修正は `perms_needed` を削るので、**放っておくと
        一覧の一括削除まで同時に解禁される** —— 修正前は 5 state の
        `has_delete_permission=False` が「消せない」という形で
        一括削除も塞いでおり、**この BUG が偶然の防護柵になっていた**。

        目的は「テストユーザーを 1 人ずつ掃除できること」であって、
        「checkbox の全選択ミスでプレイヤーが一斉に消せること」ではない。
        しかも一括削除の確認画面は `delete_view` を通らないので、
        §4 の警告メッセージも出ない。
        """
        from django.test import RequestFactory

        model_admin = django_admin.site._registry[PlayerProfile]
        request = RequestFactory().get('/admin/')
        request.user = User(is_staff=True, is_superuser=True)
        self.assertNotIn('delete_selected', model_admin.get_actions(request))

    def test_no_delete_mixin_is_not_relaxed(self):
        """mixin の実装そのものが `False` を返し続けている。"""
        from api.admin_mixins import NoDeleteAdminMixin

        class _Probe(NoDeleteAdminMixin):
            pass

        self.assertFalse(_Probe().has_delete_permission(None))


# ──────────────────────────────────────────────────────────────────────────
# §2.5 【BUG-153】ブロックしうる model を**発見**して、列挙を検算する
# ──────────────────────────────────────────────────────────────────────────
class CascadeBlockingCoverageTest(TestCase):
    """🔴 **本 BUG の成果物の本体。**

    ## なぜ必要か

    BUG-152 は「`NoDeleteAdminMixin` を付けた 5 つを除けば通る」と書いたが、
    実際にブロックしていたのは **8 model** だった ——
    `ReadOnlyAdminMixin` 経由でも `has_delete_permission` は `False` になるのに、
    片方の mixin だけを grep して数えたためである。

    しかも BUG-152 のガードは**素通りした**。当時のテストは

        assertEqual(len(CASCADE_DELETABLE_MODELS), 5)
        assertEqual(set(CASCADE_DELETABLE_MODELS), {...同じ 5 個...})

    と、**リストがリスト自身と一致することを確かめていた**（トートロジー）。
    3 種類のガード（改名追従 / リテラル禁止 / 自動導出禁止）はどれも
    「**リストの中身の質**」を守るもので、
    「**そのリストで全部か**」を問うものが 1 つも無かった。

    ## なぜ「1 件ずつ」出てくるのか

    Django の `get_deleted_objects` は `perms_needed` に
    **実際に行が存在する model だけ**を入れる
    (`format_callback` が collector の集めた**インスタンス**ごとに呼ばれる)。
    だからチャレンジ未参加のユーザーでは 5 件しか出ず、参加者で 6 件目が出た。
    **課金したユーザーなら `IAPReceipt` が、重複報酬待ちがあれば
    `PendingDuplicateReward` が出る。**

    「1 個直しては次が出る」を止めるのがここの目的であって、
    3 個足すことではない。3 個足すだけなら 4 回目が来る。

    ## 🔴 発見はテストの仕事、決定は人間の仕事

    走査ロジックは**テスト側にしか置かない**。本番コードを自動導出にすると、
    BUG-152 が避けた「mixin を別の目的で使ったとき、消してはいけないものまで
    消える」が現実になる。ここがやるのは**列挙の検算**だけである。
    """

    def _blocking_models(self):
        """`PlayerProfile` 削除をブロックしうる model を発見する。

        1. `on_delete is CASCADE` の逆参照を BFS で辿る
        2. admin 登録済みのものだけ残す
        3. superuser 相当の request で `has_delete_permission()` を呼ぶ
        4. `False` を返したものが**ブロックしうる model の真実値**

        🔴 `skip` / `continue` を書かない。「知らないものは飛ばす」を書いた
        瞬間、このテストはトートロジーに戻る。
        """
        visited = {PlayerProfile}
        queue = [PlayerProfile]
        walked = []
        while queue:
            model = queue.pop(0)
            walked.append(model)
            for rel in model._meta.related_objects:
                field = rel.field
                # ⚠️ `is CASCADE` の**同一性比較**。SET_NULL 等はプレイヤー削除で
                #    消えないので、そもそも `perms_needed` に入らない。
                if field.remote_field.on_delete is not models.CASCADE:
                    continue
                child = rel.related_model
                if child in visited:
                    continue
                visited.add(child)
                queue.append(child)

        request = _fake_request(User(is_staff=True, is_superuser=True))
        blocking = {
            model for model in visited
            if django_admin.site.is_registered(model)
            and not django_admin.site._registry[model].has_delete_permission(request)
        }
        return walked, blocking

    def test_every_blocking_cascade_model_is_classified(self):
        """発見した全 model が「通す」「意図的に止める」のどちらかに入っている。"""
        _, blocking = self._blocking_models()
        classified = set(CASCADE_DELETABLE_MODELS) | set(CASCADE_BLOCKING_INTENTIONAL)
        unclassified = blocking - classified
        self.assertEqual(
            unclassified, set(),
            msg='\n'.join([
                'プレイヤー削除をブロックしうるのに、どちらにも分類されていない '
                f'model があります: {sorted(m.__name__ for m in unclassified)}',
                '  admin.py の CASCADE_DELETABLE_MODELS に足す '
                '→ プレイヤーごと消してよい (cascade を許す)',
                '  CASCADE_BLOCKING_INTENTIONAL に足す '
                '→ 意図的に削除を止める (理由を 1 行で書くこと)',
                '⚠️ どちらかに入れるまで admin からプレイヤーを削除できません。',
            ]),
        )

    def test_the_cascade_walk_actually_finds_things(self):
        """🔴 空振り検出。

        走査が壊れて空集合を返すと、上の「含まれる」は**真空的に真**になり
        緑のままになる。走査が生きていることを**下限**で縛る。

        ⚠️ 上限は縛らない。model が増えるのは正常な進化で、そこで落とすと
        「テストを直すために閾値を上げる」だけの作業が生まれる。
        """
        walked, blocking = self._blocking_models()
        self.assertGreaterEqual(
            len(walked), 20,
            msg=f'CASCADE の BFS が {len(walked)} model しか辿れていない。走査が壊れている',
        )
        known = {PlayerEconomyState, PlayerBattleState, PlayerStreakState,
                 PlayerSettings, PlayerGachaStatus}
        self.assertTrue(
            known.issubset(blocking),
            msg='既知の 5 兄弟をブロック集合として検出できていない。'
                '擬似 request が甘く has_delete_permission が常に True を'
                f'返している可能性がある: 未検出 {sorted(m.__name__ for m in known - blocking)}',
        )

    def test_blocking_is_not_limited_to_one_mixin(self):
        """ブロック源が `NoDeleteAdminMixin` だけではないこと。

        🔴 **BUG-153 の原因そのもの。** BUG-152 は `NoDeleteAdminMixin` を
        grep して 5 件を数え、`ReadOnlyAdminMixin` を見ていなかった。
        発見した集合に**2 種類以上の mixin 由来が混ざっている**ことを縛れば、
        次に誰かが「1 つの mixin を grep すれば済む」と考えるのを止められる。
        """
        from api.admin_mixins import NoDeleteAdminMixin, ReadOnlyAdminMixin

        _, blocking = self._blocking_models()
        sources = set()
        for model in blocking:
            admin_cls = type(django_admin.site._registry[model])
            if issubclass(admin_cls, ReadOnlyAdminMixin):
                sources.add('ReadOnlyAdminMixin')
            elif issubclass(admin_cls, NoDeleteAdminMixin):
                sources.add('NoDeleteAdminMixin')
            else:
                sources.add(admin_cls.__name__)
        self.assertGreaterEqual(
            len(sources), 2,
            msg='ブロック源が 1 種類しか無い。1 つの mixin を grep すれば'
                f'足りると誤解されうる: {sorted(sources)}',
        )
        self.assertIn('ReadOnlyAdminMixin', sources)
        self.assertIn('NoDeleteAdminMixin', sources)


# ──────────────────────────────────────────────────────────────────────────
# §3 除外集合が model クラス由来である
# ──────────────────────────────────────────────────────────────────────────
class CascadeExclusionIsModelDerivedTest(TestCase):
    """🔴 `verbose_name` の日本語リテラルで引き算していないこと。

    `perms_needed` は `opts.verbose_name`（日本語文字列）の集合である。
    文字列でハードコードすると、**`verbose_name` を変えた瞬間に静かに
    効かなくなる**（例外も警告も出ず、ただ削除できなくなる）。
    """

    def test_exclusion_follows_a_renamed_verbose_name(self):
        """`verbose_name` を変えても効き続ける。

        model クラスから `_meta.verbose_name` を引いていれば、
        改名しても除外集合が自動的に追従する。
        """
        original = PlayerStreakState._meta.verbose_name
        try:
            PlayerStreakState._meta.verbose_name = '別の名前にした'
            names = PlayerProfileAdmin.cascade_deletable_verbose_names()
            self.assertIn('別の名前にした', names)
            self.assertNotIn(original, names)
        finally:
            PlayerStreakState._meta.verbose_name = original

    def test_source_does_not_subtract_by_japanese_literal(self):
        """ソース走査: 除外集合を日本語リテラルで組み立てていない。

        ⚠️ **定義 (`CASCADE_DELETABLE_MODELS`) だけを見ても足りない。**
        引き算をしているのは `cascade_deletable_verbose_names()` と
        `get_deleted_objects()` の側なので、そちらも走査する ——
        最初に書いたときこの穴があり、集合はタプルのまま
        **メソッド側だけ日本語リテラルに差し替えた壊し方が素通りした**。
        """
        source = (_BACKEND / 'api' / 'admin.py').read_text(encoding='utf-8')
        targets = (
            'CASCADE_DELETABLE_MODELS = (',
            '    def cascade_deletable_verbose_names(cls) -> set:',
            '    def get_deleted_objects(self, objs, request):',
        )
        for header in targets:
            block = _strip_docstrings_and_comments(_extract_block(source, header))
            literals = re.findall(r"['\"]([^'\"]*[ぁ-んァ-ヶ一-龠][^'\"]*)['\"]", block)
            self.assertEqual(
                literals, [],
                msg=f'{header.strip()} に日本語リテラルがある: {literals} —— '
                    'model クラスから _meta.verbose_name を引くこと '
                    '(リテラルだと verbose_name の改名で静かに効かなくなる)',
            )

    def test_exclusion_is_not_derived_from_the_mixin(self):
        """⚠️ `NoDeleteAdminMixin` の有無で自動導出していないこと。

        将来この mixin を別の目的（監査ログ等）で使ったとき、
        自動導出だと**消してはいけないものまで消える**。
        5 model を明示列挙する形を維持する。
        """
        source = (_BACKEND / 'api' / 'admin.py').read_text(encoding='utf-8')
        block = _extract_block(source, 'CASCADE_DELETABLE_MODELS = (')
        self.assertNotIn('NoDeleteAdminMixin', block)
        self.assertNotIn('issubclass', block)


# ──────────────────────────────────────────────────────────────────────────
# §4 削除確認画面の注意書き (BUG-152 §6)
# ──────────────────────────────────────────────────────────────────────────
@_PLAIN_STATIC
class DeleteWarningIsShownTest(_AdminHttpTestCase):
    """⚠️ admin の削除は PostHog identity 削除などの付随処理を飛ばす。

    アカウント削除 API が行っている処理は admin 経由では走らないので、
    「テストユーザーの掃除用、実ユーザーの退会には使わない」と読める
    注意を確認画面に出す。
    """

    def setUp(self):
        self._login()
        self.player = self._make_player()

    def test_confirmation_page_warns_against_real_user_deletion(self):
        res = self.client.get(
            reverse('admin:api_playerprofile_delete', args=[self.player.pk])
        )
        body = res.content.decode()
        self.assertIn('テストユーザー', body)
        self.assertIn('退会', body)
        self.assertIn('PostHog', body)


# ──────────────────────────────────────────────────────────────────────────
# §5 一覧の「最終アクティブ」列 (FEAT-540)
# ──────────────────────────────────────────────────────────────────────────
@_PLAIN_STATIC
class LastActiveColumnTest(_AdminHttpTestCase):

    def setUp(self):
        self._login()
        self.player = self._make_player()
        self.moment = timezone.now() - timezone.timedelta(days=3)
        streak = self.player.streak
        streak.last_achievement_check_at = self.moment
        streak.save(update_fields=['last_achievement_check_at'])

    def test_column_is_registered_with_an_active_not_login_label(self):
        """⚠️ 列名は「アクティブ」であって「ログイン」ではない。

        「最終ログイン」と読まれると、**認証したか**を見ていると誤解される。
        実際に測っているのは**タスク達成**である。
        """
        model_admin = django_admin.site._registry[PlayerProfile]
        self.assertIn('get_last_active', model_admin.list_display)
        label = model_admin.get_last_active.short_description
        self.assertIn('アクティブ', label)
        self.assertNotIn('ログイン', label)

    def test_value_matches_last_achievement_check_at(self):
        model_admin = django_admin.site._registry[PlayerProfile]
        obj = PlayerProfile.objects.select_related('streak_state').get(
            pk=self.player.pk,
        )
        self.assertEqual(model_admin.get_last_active(obj), self.moment)

    def test_value_is_none_when_never_active(self):
        """一度も動いていなければ None（嘘の日付を作らない）。"""
        other = self._make_player('2')
        model_admin = django_admin.site._registry[PlayerProfile]
        obj = PlayerProfile.objects.select_related('streak_state').get(pk=other.pk)
        self.assertIsNone(model_admin.get_last_active(obj))

    def test_ordering_targets_the_state_table(self):
        """並び替えが効く（`ordering` が state テーブルを指している）。"""
        model_admin = django_admin.site._registry[PlayerProfile]
        self.assertEqual(
            model_admin.get_last_active.admin_order_field,
            'streak_state__last_achievement_check_at',
        )
        res = self.client.get(
            reverse('admin:api_playerprofile_changelist'),
            {'o': str(model_admin.list_display.index('get_last_active') + 1)},
        )
        self.assertEqual(res.status_code, 200)

    def test_changelist_renders_the_value(self):
        res = self.client.get(reverse('admin:api_playerprofile_changelist'))
        self.assertEqual(res.status_code, 200)
        self.assertIn('最終アクティブ', res.content.decode())


# ──────────────────────────────────────────────────────────────────────────
# §6 🔴 User.last_login を最終アクティブとして使っていない (走査)
# ──────────────────────────────────────────────────────────────────────────
class LastLoginIsNotUsedAsActivityTest(TestCase):
    """🔴 `User.last_login` はこのアプリでは一度も更新されない。

    DRF の `TokenAuthentication` は `last_login` を触らず、
    `django.contrib.auth.login()` の呼び出しも 0 件である。
    それでも**一見もっとも素直な選択肢**なので、将来
    「`last_login` のほうが自然では」と書き換えられうる ——
    そのとき例外も警告も出ず、**ただ全員が空欄になる**。

    値の比較では捕まらない（正しい実装でも None はありうる）ので走査する。
    """

    def test_no_write_to_last_login_anywhere_in_api(self):
        offenders = []
        for path in (_BACKEND / 'api').rglob('*.py'):
            if 'migrations' in path.parts or 'tests' in path.parts:
                continue
            text = path.read_text(encoding='utf-8')
            if re.search(r'^\s*[\w.]*\.last_login\s*=', text, re.MULTILINE):
                offenders.append(str(path.relative_to(_BACKEND)))
            if re.search(r'\bupdate_last_login\b', text):
                offenders.append(str(path.relative_to(_BACKEND)))
        self.assertEqual(
            offenders, [],
            msg='last_login への書き込みが増えている。'
                '増やすなら FEAT-540 §5 の「別 FEAT」を先に通すこと: '
                f'{offenders}',
        )

    def test_last_active_column_does_not_read_last_login(self):
        """最終アクティブ列が `last_login` を**読んでいない**。

        ⚠️ 文字列走査ではなく AST で見る。docstring とコメントで
        「`last_login` ではない」と**説明している**ので、
        素朴な `assertNotIn` は自分の説明文で落ちる（最初にこれを踏んだ）。
        見たいのは属性アクセスであって、文章ではない。
        """
        import ast

        source = (_BACKEND / 'api' / 'admin.py').read_text(encoding='utf-8')
        func = next(
            node for node in ast.walk(ast.parse(source))
            if isinstance(node, ast.FunctionDef) and node.name == 'get_last_active'
        )
        reads = [
            node.attr for node in ast.walk(func)
            if isinstance(node, ast.Attribute) and node.attr == 'last_login'
        ]
        names = [
            node.value for node in ast.walk(func)
            if isinstance(node, ast.Constant) and node.value == 'last_login'
        ]
        self.assertEqual(
            reads + names, [],
            msg='最終アクティブ列が User.last_login を読んでいる。'
                'DRF の Token 認証は last_login を更新しないので、'
                '**例外も警告も出ないまま全員が空欄になる**（FEAT-540 §1）',
        )

    def test_user_admin_marks_last_login_as_not_updated(self):
        """Django 既定の User admin が「なし」という嘘を見せ続けないこと。

        外すのではなく**理由を書く**（外すと「なぜ無いのか」が分からなくなり、
        同じ疑問がまた出る。今回まさにそれが起きた）。
        """
        user_admin = django_admin.site._registry[User]
        self.assertIn('last_login', user_admin.readonly_fields)
        blob = str(user_admin.fieldsets)
        self.assertIn('更新されません', blob)


# ──────────────────────────────────────────────────────────────────────────
# §7 一覧のクエリ数 (N+1 の回帰検出)
# ──────────────────────────────────────────────────────────────────────────
@_PLAIN_STATIC
class ChangelistQueryCountTest(_AdminHttpTestCase):
    """⚠️ 最終アクティブ列を足してクエリが増えていないこと。

    🔵 **`select_related('streak_state')` は効く。ただし読み方次第である。**

    実測（player 3 件）:

        plain            + `obj.streak`        4 本
        select_related   + `obj.streak`        4 本   ← 効かない
        select_related   + `obj.streak_state`  1 本   ← 効く
        plain            + `obj.streak_state`  4 本

    `player.streak` は `@property` の shim で、中で `get_or_create` を
    呼ぶため **`select_related` のキャッシュを一切見ない**。
    FEAT-535 が `player.battle` で「効かない」と結論したのはこの形である。
    本 FEAT は**逆参照そのもの** (`obj.streak_state`) を読むので効く。
    """

    def setUp(self):
        self._login()
        for i in range(5):
            self._make_player(str(i))

    def test_last_active_adds_no_query_per_row(self):
        url = reverse('admin:api_playerprofile_changelist')
        with CaptureQueriesContext(connection) as ctx:
            res = self.client.get(url)
        self.assertEqual(res.status_code, 200)
        # ⚠️ 「sql に playerstreakstate が含まれる」で数えてはいけない ——
        #    select_related の JOIN を含む**本体の SELECT も引っかかる**
        #    （最初にこれを踏んだ）。見たいのは
        #    `FROM api_playerstreakstate` の**単体 SELECT** だけである。
        streak_queries = [
            q['sql'] for q in ctx.captured_queries
            if 'from "api_playerstreakstate"' in q['sql'].lower()
            or 'from `api_playerstreakstate`' in q['sql'].lower()
        ]
        # select_related で JOIN されるので、streak_state 単体の SELECT は
        # 1 本も出ない（出るなら shim 経由で読んでいる = N+1）。
        self.assertEqual(
            streak_queries, [],
            msg=f'streak_state を行ごとに引いている ({len(streak_queries)} 本): '
                'obj.streak (shim) ではなく obj.streak_state を読むこと',
        )

    def test_queryset_declares_select_related(self):
        model_admin = django_admin.site._registry[PlayerProfile]
        qs = model_admin.get_queryset(_fake_request(self.admin_user))
        self.assertIn('streak_state', qs.query.select_related)


# ──────────────────────────────────────────────────────────────────────────
# helpers
# ──────────────────────────────────────────────────────────────────────────
def _fake_request(user):
    from django.test import RequestFactory

    request = RequestFactory().get('/admin/')
    request.user = user
    return request


def _strip_docstrings_and_comments(block: str) -> str:
    """走査対象からコメントと docstring を落とす。

    ⚠️ 本 FEAT のコードは docstring で「日本語リテラルで書くな」と
    **説明している**ので、素朴に走査すると自分の説明文で落ちる。
    見たいのは実行されるコードだけである。
    """
    out, in_doc = [], False
    for line in block.splitlines():
        stripped = line.strip()
        if in_doc:
            if stripped.endswith('"""'):
                in_doc = False
            continue
        if stripped.startswith('"""'):
            # 1 行で閉じていなければ複数行 docstring
            if not (stripped.endswith('"""') and len(stripped) > 3):
                in_doc = True
            continue
        if stripped.startswith('#'):
            continue
        out.append(line.split('  #')[0])
    return '\n'.join(out)


def _extract_block(source: str, header: str) -> str:
    """`header` で始まる 1 ブロックだけを切り出す（走査用）。

    ⚠️ 行数を固定して切ると**ブロックの外まで拾って誤検出する**。
    最初にこれを踏んだ —— 除外集合の走査が、直後にある別コードの
    日本語コメントを「リテラルで引き算している」と誤判定した。
    閉じ括弧、またはインデントが基準まで戻った行で止める。
    """
    idx = source.find(header)
    assert idx >= 0, f'{header!r} が admin.py に見つからない'
    lines = source[idx:].splitlines()
    base = len(lines[0]) - len(lines[0].lstrip())
    out = [lines[0]]
    for line in lines[1:]:
        stripped = line.strip()
        if not stripped:
            out.append(line)
            continue
        indent = len(line) - len(line.lstrip())
        if indent <= base:
            if stripped.startswith((')', '}', ']')):
                out.append(line)
            break
        out.append(line)
    return '\n'.join(out)
