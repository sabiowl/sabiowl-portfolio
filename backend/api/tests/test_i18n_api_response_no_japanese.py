"""【BUG-146 Phase 1 (2026-08-19)】`Accept-Language: en` のレスポンスに日本語が出ないことを縛る。

## なぜ必要か —— 「`_en` がある」と「`_en` を読んでいる」は別の話

FEAT-516 は `test_i18n_field_census.py` で「運営が書く文言 field には `_en` が
ある」を縛った。だがそれは **field の存在**しか見ていない。

    `_en` を足す              → census が緑
    英訳を投入する            → check_i18n_coverage が緑
    **API は生の日本語を返す**  → **誰も気付かない**

BUG-146 はこの隙間そのもので、`gacha.py` には `get_i18n_field` の呼び出しが
**1 件も無かった**。しかも `shop.py` の `SHOP_CATALOG` は Python の dict リテラルで
model ですらないため、model を走査する census の**視界の外**にある。

本テストは「読み取り側」を縛る。**レスポンス本文に CJK が出たら落ちる。**

## 対象を 5 endpoint に絞る理由 (Pre-mortem #2)

user-generated content (習慣名 / メモ / プレイヤー名) は英語 UI でも日本語で
**正しい**。それを含む endpoint まで対象にすると「直せない red」が量産され、
最後はテストごと無効化される —— それが最悪の結末なので、**最初から
master data しか出ない endpoint に絞る**。

## 🔴 endpoint リストだけは手選びのまま残っている (FEAT-536 Phase 2-2)

本 FEAT が塞いだ穴は **まさにこのリストの漏れ**だった。`/api/maintenance/` は
master data しか返さず AllowAny なので、**このテストの対象条件に最初から
合致していた**。それでも入っていなかったのは、**手で選んだから**である
(FEAT-536 §3)。

自動化しなかったのは、「対象にしてよい endpoint」の判定が
**user-generated content を返すかどうか**という意味論に依存し、
URL からも view からも機械的に決められないため。上の段落が書いているとおり、
判定を誤って対象を広げると「直せない red」が量産され、最後はテストごと
無効化される —— そちらのほうが失うものが大きい。

⚠️ **したがって、ここは塞げていない。** `_en` を返す新しい endpoint を作った
ときは、**手でここに足す必要がある**。塞げていないことを、塞いだ顔で
放置しないために明記しておく。

(model 側の漏れは `test_i18n_field_census.py` が、admin 側の漏れは
同ファイルの `AdminExposesEnglishFieldsTest` が走査で塞いでいる。
**手選びが残っているのは endpoint リストだけ**である。)

## `_en` は fixture 側で埋める (Pre-mortem #5)

テスト DB の `_en` は空 (英訳は `translate_master_data` で投入する運用で、
migration では seed されない)。埋めずに走らせると「実装漏れ」と「未投入」を
区別できないので、**本テストが触る master data の `_en` は自分で埋める**。
落ちたら原因は必ず**配線漏れ**、という状態を作る。
"""
import re

from django.contrib.auth import get_user_model
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.views.gacha import _ensure_gacha_rewards
from api.models import (
    Character,
    GachaHistory,
    GachaReward,
    PlayerGachaStatus,
    PlayerProfile,
    MaintenanceConfig,
    PlayerWeapon,
    WeaponMaster,
)
from api.services.maintenance_cache import invalidate_maintenance_cache

User = get_user_model()

# 日本語判定。ひらがな / カタカナ / 漢字 / 全角記号 / CJK 約物。
# 絵文字 (feather / crossed swords 等) は含めない —— 言語に依らず出てよい。
_CJK = re.compile(
    '['
    '　-〿'   # CJK 約物 (、。「」〜)
    '぀-ゟ'   # ひらがな
    '゠-ヿ'   # カタカナ
    '一-鿿'   # 漢字
    '！-｠'   # 全角英数・記号
    ']'
)

_TEST_RF_OVERRIDE = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework.authtoken.authentication.TokenAuthentication',
        'api.authentication.GuestTokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': ['rest_framework.permissions.IsAuthenticated'],
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
}

# ── allowlist ────────────────────────────────────────────────────────────
#
# key は `endpoint ラベル:JSON の葉キー` か `*:葉キー` (全 endpoint 共通)。
# **値は「なぜ英語 UI でも日本語が出てよいか」の理由。空文字にしないこと。**
# `test_i18n_field_census.py` の `_ALLOWLIST` と同じ運用 —— 理由が書けないものは
# 「判断していない」だけなので、allowlist ではなく修正対象に入れる。
_ALLOWLIST: dict[str, str] = {
    # 現時点で該当なし。
    #
    # user-generated content (習慣名 / メモ / プレイヤー名) を返す endpoint は
    # 対象に入れていないため、ここは空で始まる。対象 endpoint を増やして
    # 落ちたときは、**まず「これは運営が書いた文言か」を確認**すること。
    # 運営の文言なら allowlist ではなく `get_i18n_field` を通す側の問題。
}


def _iter_strings(node, path=''):
    """JSON を再帰的に歩いて (葉のキー, 文字列) を列挙する。"""
    if isinstance(node, dict):
        for k, v in node.items():
            yield from _iter_strings(v, k)
    elif isinstance(node, (list, tuple)):
        for v in node:
            yield from _iter_strings(v, path)
    elif isinstance(node, str):
        yield path, node


@override_settings(REST_FRAMEWORK=_TEST_RF_OVERRIDE)
class I18nApiResponseNoJapaneseTest(APITestCase):
    """`Accept-Language: en` で主要 5 endpoint に日本語が出ない。"""

    def setUp(self):
        self.user = User.objects.create_user('i18n_resp_user', email='ir@t.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='Tester')
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # ── master data の `_en` を埋める (Pre-mortem #5) ──────────────
        # 訳文の中身は問題にしない。**日本語でないこと**だけが要件なので、
        # 決まった形で機械的に埋める。これで red の原因は配線漏れに限定される。
        for w in WeaponMaster.objects.all():
            WeaponMaster.objects.filter(pk=w.pk).update(
                name_en='EN name ' + w.key,
                description_en='EN description ' + w.key,
            )
        for c in Character.objects.all():
            Character.objects.filter(pk=c.pk).update(
                name_en='EN name ' + c.key,
                role_en='EN role ' + c.key,
                description_en='EN description ' + c.key,
                tagline_en='EN tagline ' + c.key,
            )

        # ── ガチャ報酬 (status / pull が読む master data) ────────────────
        #
        # **自前で GachaReward を作らない。** `_ensure_gacha_rewards()` は
        # `(ticket_type, name, detail)` の三つ組で `get_or_create` するので、
        # 独自の detail を持つ行を足すと **リクエスト中に seed 側の行が新規作成**
        # され、その行の `_en` は空 = 日本語に fallback する。
        # 「配線漏れ」と「未投入」を取り違える典型 (Pre-mortem #5) なので、
        # **先に seed を確定させてから `_en` を埋める**。
        _ensure_gacha_rewards()
        for r in GachaReward.objects.all():
            GachaReward.objects.filter(pk=r.pk).update(
                name_en='EN name ' + str(r.pk),
                detail_en='EN detail ' + str(r.pk),
            )

        # 排出を 1 件に固定する。**name と detail の両方が日本語**の報酬を選ぶ
        # —— detail が 'EXP +30' のように元から CJK を含まない行だと、
        # detail の配線漏れを検出できない。
        self.reward = (
            GachaReward.objects
            .filter(ticket_type='daily', name='XPブースト')
            .first()
        )
        self.assertIsNotNone(self.reward, 'seed が期待した報酬を含んでいない')
        self.assertRegex(self.reward.detail, _CJK, 'detail が日本語でないと検出力が落ちる')
        GachaReward.objects.exclude(pk=self.reward.pk).update(is_active=False)
        GachaReward.objects.filter(pk=self.reward.pk).update(is_active=True)
        self.reward.refresh_from_db()

        # 履歴 2 件 —— 「キャラ排出」と「非キャラ」の両経路を通す。
        # 履歴の name は character の有無で作り方が分岐するため、
        # 片方だけだと分岐の一方しか踏めない。
        self.character = Character.objects.first()
        GachaHistory.objects.create(
            player=self.player, reward=self.reward, ticket_type='daily')
        if self.character is not None:
            GachaHistory.objects.create(
                player=self.player, reward=self.reward, ticket_type='daily',
                character=self.character)

        # 所持武器 (player/weapons/ が読む master data)
        self.weapon = WeaponMaster.objects.first()
        PlayerWeapon.objects.create(
            player=self.player, weapon=self.weapon, is_equipped=True)

        # ── メンテナンス設定 (FEAT-536 Phase 2-2) ────────────────────────
        #
        # **`_en` を埋めたうえで ON にする** (Pre-mortem #5)。埋めずに走らせると
        # `_EN_FALLBACK` が返って緑になり、**view の配線漏れを検出できない**
        # (fallback は「実装漏れ」も「未投入」も同じ英文で覆い隠す)。
        # 空のときの挙動は `test_maintenance.py` の L-3 が別テストとして持つ。
        #
        # ⚠️ cache は DB ロールバックと連動しないので必ず invalidate する
        # (FEAT-471 の 60 秒 TTL)。
        MaintenanceConfig.objects.create(
            pk=1, is_enabled=True,
            title='現在、システムに手当てをしております',
            title_en='EN maintenance title',
            body='少し時間をおいて、もう一度お試しください 🪶',
            body_en='EN maintenance body',
        )
        invalidate_maintenance_cache()

        status_obj, _ = PlayerGachaStatus.objects.get_or_create(player=self.player)
        status_obj.daily_tickets = 5
        status_obj.save(update_fields=['daily_tickets'])

    def tearDown(self):
        # cache は DB ロールバックの外側にいる。残すと後続のテストが
        # 「メンテ中」の状態を引き継ぐ。
        invalidate_maintenance_cache()

    # ── helper ───────────────────────────────────────────────────────

    def _assert_no_japanese(self, label, payload):
        offenders = []
        for key, value in _iter_strings(payload):
            if not _CJK.search(value):
                continue
            if _ALLOWLIST.get(label + ':' + key) or _ALLOWLIST.get('*:' + key):
                continue
            offenders.append(label + ' :: ' + key + ' = ' + repr(value))
        self.assertEqual(
            offenders, [],
            'Accept-Language: en なのに日本語が返っている (' + label + '):\n  '
            + '\n  '.join(sorted(offenders))
            + '\n\n読み取り側に get_i18n_field を通すか、'
              '_ALLOWLIST に「なぜ日本語でよいか」の理由を書いて外すこと。',
        )

    def _get_en(self, url_name):
        return self.client.get(reverse(url_name), HTTP_ACCEPT_LANGUAGE='en')

    # ── 5 endpoint ───────────────────────────────────────────────────

    def test_gacha_status_has_no_japanese(self):
        res = self._get_en('gacha-status')
        self.assertEqual(res.status_code, 200, res.content)
        self._assert_no_japanese('GET /api/gacha/status/', res.json())

    def test_gacha_pull_has_no_japanese(self):
        res = self.client.post(
            reverse('gacha-pull'), data={'ticket_type': 'daily'}, format='json',
            HTTP_ACCEPT_LANGUAGE='en',
        )
        self.assertEqual(res.status_code, 200, res.content)
        self._assert_no_japanese('POST /api/gacha/pull/', res.json())

    def test_shop_has_no_japanese(self):
        res = self._get_en('shop-items')
        self.assertEqual(res.status_code, 200, res.content)
        self._assert_no_japanese('GET /api/shop/', res.json())

    def test_player_weapons_has_no_japanese(self):
        res = self._get_en('player-weapons')
        self.assertEqual(res.status_code, 200, res.content)
        self._assert_no_japanese('GET /api/player/weapons/', res.json())

    def test_maintenance_has_no_japanese(self):
        """【FEAT-536】メンテナンス告知が英語で返る。

        🔴 **障害中に出る唯一の画面**である。ここが日本語だと、英語圏の
        ユーザーには「アプリが読めない画面で止まった」としか映らない。
        v1.1.2 の storefront 開放と正面から噛み合う。
        """
        res = self._get_en('maintenance-status')
        self.assertEqual(res.status_code, 200, res.content)
        self.assertTrue(res.json()['is_enabled'], 'fixture が ON になっていない')
        self._assert_no_japanese('GET /api/maintenance/', res.json())

    # ── 日本語側の回帰 (§6 完了条件) ─────────────────────────────────

    def test_japanese_is_unchanged_without_header(self):
        """ヘッダ無し = ja。従来どおり日本語が返る。

        英語対応が「日本語を壊して英語にした」ではないことを縛る。
        """
        res = self.client.get(reverse('shop-items'))
        self.assertEqual(res.status_code, 200, res.content)
        names = [v for k, v in _iter_strings(res.json()) if k == 'name']
        self.assertTrue(
            any(_CJK.search(n) for n in names),
            'ヘッダ無し (ja) なのにショップ名が日本語でない',
        )

    def test_japanese_is_unchanged_with_ja_header(self):
        """明示的な ja でも日本語のまま。"""
        res = self.client.get(reverse('player-weapons'), HTTP_ACCEPT_LANGUAGE='ja')
        self.assertEqual(res.status_code, 200, res.content)
        names = [v for k, v in _iter_strings(res.json()) if k == 'name']
        self.assertTrue(names and all(_CJK.search(n) for n in names),
                        'ja なのに武器名が日本語でない: ' + repr(names))

    def test_allowlist_entries_have_a_reason(self):
        """allowlist の全 entry に理由がある。

        理由の無い entry が増えると allowlist が「とりあえず足す場所」に堕ちる。
        """
        empty = [k for k, v in _ALLOWLIST.items() if not v or not v.strip()]
        self.assertEqual(empty, [], '理由が空の allowlist entry: ' + repr(empty))
