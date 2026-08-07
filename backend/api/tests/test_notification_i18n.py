"""【FEAT-517】サーバー起点で送る文言 (通知 / プッシュ) の i18n 契約テスト。

## なぜこの 2 つを一緒に縛るのか

通知の英語化と `preferred_language` の同期は **片方だけでは意味がない**。

- 文面だけ英語化しても、`preferred_language` が `'ja'` のままなら
  英語ユーザーには日本語で届く
- 同期だけ入れても、文面が日本語ハードコードなら何も変わらない

そして「通知を英語化したのに英語ユーザーには日本語で届く」は、**実装した本人が
最も気付きにくい状態**である (自分の端末は ja で、正しく日本語が届く)。
だから両方を 1 つのテストファイルで縛る。

## なぜ `preferred_language` が同期されていないのか (背景)

Mobile がこの field を送るのは `LocaleSideEffects.apply()` =
**設定画面で明示的に言語を選んだとき**だけ。「英語端末で新規インストール →
設定画面を開かない」という最も普通の導線では `default='ja'` のまま残る。

リクエスト応答は `Accept-Language` が効くので無事だったが、通知は
リクエストの外で送られるためこの field しか手掛かりが無い。
"""
from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from api.i18n_messages import (
    NOTIFICATION_MESSAGES,
    gift_part_label,
    notification_text,
    resolve_player_locale,
)
from api.models import Notification, PlayerProfile
from api.services.push_service import create_localized_notification

User = get_user_model()


def _make_player(username, lang='ja'):
    user = User.objects.create_user(username=username, password='pw')
    player, _ = PlayerProfile.objects.get_or_create(user=user)
    state = player.settings
    state.preferred_language = lang
    state.save(update_fields=['preferred_language'])
    return user, player


class NotificationCatalogTest(TestCase):
    """カタログ自体の不変条件。"""

    def test_every_key_has_both_locales(self):
        """ja / en の両方が揃っている (en 追加忘れの検出)。"""
        missing = [
            f'{key}.{loc}'
            for key, entry in NOTIFICATION_MESSAGES.items()
            for loc in ('ja', 'en')
            if loc not in entry
        ]
        self.assertEqual(missing, [], f'locale が欠けている: {missing}')

    def test_english_has_no_japanese(self):
        """en 側に日本語が残っていない (コピペ漏れの検出)。"""
        leaked = []
        for key, entry in NOTIFICATION_MESSAGES.items():
            for text in entry['en']:
                if any('぀' <= c <= 'ヿ' or '一' <= c <= '鿿'
                       for c in text):
                    leaked.append(f'{key}: {text!r}')
        self.assertEqual(leaked, [], f'英語側に日本語が残っている: {leaked}')

    def test_placeholders_match_across_locales(self):
        """ja と en で `{...}` の集合が一致する。

        片方だけ placeholder を持つと `format()` が KeyError で落ちるか、
        逆に値が本文に出ないまま送られる。
        """
        import re
        ph = re.compile(r'\{(\w+)\}')
        for key, entry in NOTIFICATION_MESSAGES.items():
            ja = set(ph.findall(' '.join(entry['ja'])))
            en = set(ph.findall(' '.join(entry['en'])))
            self.assertEqual(ja, en, f'{key}: placeholder が不一致 ja={ja} en={en}')

    def test_english_sabi_lines_have_no_exclamation(self):
        """英語の本文に `!` を使わない (persona guide §1.3)。

        日本語側には「実績解除！」等が残っているが、これは FEAT-449 が
        level_up だけを揃えた名残で、本 FEAT では ja を変更しない。
        英語は最初から規則に従わせる。
        """
        offenders = [
            f'{key}: {text!r}'
            for key, entry in NOTIFICATION_MESSAGES.items()
            for text in entry['en']
            if '!' in text
        ]
        self.assertEqual(offenders, [], f'英語の通知に ! がある: {offenders}')

    def test_unknown_locale_falls_back_to_ja(self):
        title, _ = notification_text('friend_request', 'fr', player_name='X')
        self.assertIn('フレンド', title)

    def test_gift_part_labels_localized(self):
        self.assertEqual(gift_part_label('coins', 'en', amount=3), '🪙 Coins +3')
        self.assertEqual(gift_part_label('coins', 'ja', amount=3), '🪙 コイン +3')


class LocalizedNotificationTest(TestCase):
    """宛先プレイヤーの言語で通知が作られる。"""

    def test_en_player_gets_english(self):
        _, player = _make_player('notif_en', lang='en')
        create_localized_notification(
            player, 'friend_request', 'friend_request', player_name='Alice',
        )
        n = Notification.objects.get(player=player)
        self.assertEqual(n.title, 'A friend request has arrived ⚔️')
        self.assertIn('Alice', n.body)

    def test_ja_player_gets_japanese(self):
        _, player = _make_player('notif_ja', lang='ja')
        create_localized_notification(
            player, 'friend_request', 'friend_request', player_name='アリス',
        )
        n = Notification.objects.get(player=player)
        self.assertIn('フレンド申請', n.title)

    def test_receiver_language_wins_not_sender(self):
        """ギフト通知は **受信者** の言語で作られる。

        送信者の言語で作ると、日本語ユーザーが英語ユーザーに贈ったときに
        日本語の通知が届く。宛先が誰かを取り違えやすい箇所なので縛る。
        """
        _, receiver = _make_player('gift_receiver', lang='en')
        create_localized_notification(
            receiver, 'gift', 'gift_received',
            sender_name='たろう', gift_parts=gift_part_label('xp_boost', 'en'),
        )
        n = Notification.objects.get(player=receiver)
        self.assertIn('A friend has sent you support', n.title)
        self.assertIn('XP Boost', n.body)
        # 送信者名は user-generated なので翻訳しない (そのまま出るのが正しい)
        self.assertIn('たろう', n.body)

    def test_player_without_settings_falls_back_to_ja(self):
        user = User.objects.create_user(username='no_settings', password='pw')
        player, _ = PlayerProfile.objects.get_or_create(user=user)
        self.assertEqual(resolve_player_locale(player), 'ja')


class PreferredLanguageSyncTest(TestCase):
    """ホーム bootstrap が Accept-Language を preferred_language に反映する。

    ## 認証について

    `force_authenticate` は使えない。DRF の強制認証は APIView の
    initialize_request 内で効くため、その手前の `I18nMiddleware` からは
    AnonymousUser に見える。実機と同じく Token を渡す。
    """

    def setUp(self):
        self.user, self.player = _make_player('sync_user', lang='ja')
        self.client = APIClient()
        token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token.key}')

    def _lang(self):
        self.player.settings.refresh_from_db()
        return self.player.settings.preferred_language

    def test_en_header_updates_preferred_language(self):
        """英語端末で新規インストール → ホームを開いただけで en に揃う。

        これが無いと、通知だけ日本語で届き続ける。
        """
        self.assertEqual(self._lang(), 'ja')
        res = self.client.get('/api/home/', HTTP_ACCEPT_LANGUAGE='en-US,en;q=0.9')
        self.assertEqual(res.status_code, 200)
        self.assertEqual(self._lang(), 'en')

    def test_ja_header_keeps_ja(self):
        res = self.client.get('/api/home/', HTTP_ACCEPT_LANGUAGE='ja')
        self.assertEqual(res.status_code, 200)
        self.assertEqual(self._lang(), 'ja')

    def test_switching_back_syncs_again(self):
        """en → ja に戻したら追従する (片道にしない)。"""
        self.client.get('/api/home/', HTTP_ACCEPT_LANGUAGE='en')
        self.assertEqual(self._lang(), 'en')
        self.client.get('/api/home/', HTTP_ACCEPT_LANGUAGE='ja')
        self.assertEqual(self._lang(), 'ja')

    def test_no_header_does_not_overwrite(self):
        """ヘッダを送らないクライアントは保存値を壊さない。

        ヘッダ無しの場合 `request.locale` は preferred_language から解決される。
        それを書き戻すのは無駄な UPDATE であり、かつ ja default に引きずられて
        **明示選択した en を握り潰す**危険がある。
        """
        state = self.player.settings
        state.preferred_language = 'en'
        state.save(update_fields=['preferred_language'])

        res = self.client.get('/api/home/')  # Accept-Language なし
        self.assertEqual(res.status_code, 200)
        self.assertEqual(self._lang(), 'en', 'ヘッダ無しで en が上書きされた')
