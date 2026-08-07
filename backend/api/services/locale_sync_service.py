"""【FEAT-517】`PlayerSettings.preferred_language` を Accept-Language から同期する。

## なぜ必要か

通知 (FCM push / リマインダー) は **リクエストの外**で送られる。
`Accept-Language` ヘッダが存在しないので、宛先の言語を知る手掛かりは
`PlayerSettings.preferred_language` しかない。

ところが Mobile がこの field を送るのは
`LocaleSideEffects.apply()` = **設定画面で明示的に言語を選んだとき**だけである
(`setLanguage` の呼出は `settings_page.dart` の 1 箇所、実測)。

したがって「US で新規インストール → 英語 UI → 設定画面を開かない」という
**最も普通の導線**では、Backend 側は `default='ja'` のまま残る。
通知を英語化しても、その英語ユーザーには日本語で届く。

## なぜ Mobile ではなく Backend で同期するのか

Mobile 側で起動時に PATCH する案もあった (20260802 review の改善案 (a)) が、
Backend 側で拾う方が優れている:

- **既存ユーザーも自動的に直る**。Mobile 実装だとアプリ更新が要る
- **アプリ起動直後は未認証**のことがある (guest-init 前)。PATCH の置き場所に
  困り、リトライやフラグ管理が要る
- Mobile が毎リクエストで送る `Accept-Language` は
  `ServiceL10n.current` = **アプリが今表示している言語**そのもの
  (`api_client.dart`)。保存値より常に新しいので、これを正とするのが自然

## どこから呼ぶか

**ホーム bootstrap から 1 回だけ**呼ぶ。全リクエストで呼ぶと
`PlayerSettings` の SELECT が毎回 1 本増える (100 call/日/user 規模)。
「アプリを開いた」ことを表す最も自然な 1 点が bootstrap である。

## 上書きしてよいのか

よい。ヘッダはユーザーが今アプリで見ている言語なので、
設定画面で明示的に選んだ場合もヘッダはその言語になる。
両者が食い違うのは「保存値が古い」ときだけであり、そのとき新しい方に
揃えるのが正しい。
"""
import logging

_logger = logging.getLogger(__name__)


def sync_preferred_language(request, player) -> bool:
    """`Accept-Language` があれば `preferred_language` に反映する。

    Returns:
        更新したら True。ヘッダが無い / 既に一致 / 失敗時は False。

    **例外は投げない**。locale の同期に失敗してもホーム表示は継続すべきで、
    ここで 500 にする価値はない (Sabi 哲学「押し付けない」)。
    """
    # ヘッダが無いリクエストでは何もしない。
    # (request.locale は「ヘッダ無し → preferred_language」の順で解決するので、
    #  それを書き戻すと自分自身を書くだけの無駄な UPDATE になる)
    raw = request.META.get('HTTP_ACCEPT_LANGUAGE', '')
    if not raw:
        return False

    locale = str(getattr(request, 'locale', 'ja'))
    if locale not in ('ja', 'en'):
        return False

    try:
        settings_state = player.settings
        if settings_state.preferred_language == locale:
            return False
        settings_state.preferred_language = locale
        settings_state.save(update_fields=['preferred_language'])
        _logger.info(
            'preferred_language synced from Accept-Language',
            extra={'player_id': player.pk, 'locale': locale},
        )
        return True
    except Exception as exc:  # noqa: BLE001 — best-effort
        _logger.warning('preferred_language sync failed: %s', exc)
        return False
