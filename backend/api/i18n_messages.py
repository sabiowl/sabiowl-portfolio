"""【FEAT-517】サーバー起点で送る文言 (通知 / プッシュ) の locale カタログ。

## なぜ ARB でも master data でもないのか

- **ARB (Flutter)**: 端末が描画する文言。通知は **Backend が文面を組み立てて
  FCM に渡す**ので、端末には完成した文字列しか届かない。ARB では扱えない。
- **master data (`_en` field)**: admin が編集する運用データ。通知文面はコードに
  埋まったロジック側の文言で、admin が触るものではない。

つまりここは **第 3 のカテゴリ**であり、FEAT-489 Phase 4 の census
(「`_en` field を持つ model」) からも ARB 化 (Phase 2) からも構造的に漏れていた。

## locale の決め方 — リクエストが無いことが本質

通知は **リクエストの外**で送られる (リマインダーの cron / 他人の操作による
フレンド通知など)。`Accept-Language` ヘッダが存在しないので、
`PlayerSettings.preferred_language` が唯一の手掛かりになる。

**この field が正しく同期されていることが前提**である。同期は
`api/services/locale_sync_service.py` が担う (詳細はそちらの docstring)。

## 語調

サビ = 「アプリの声」なので、英語も `doc/design/i18n_persona_en.md` の
Sabi 規則に従う (**感嘆符を使わない** / 二人称は you / 煽らない)。

> ⚠️ 日本語側には「実績解除！ 🏅」のように感嘆符が残っている。これは
> FEAT-449 が level_up だけをサビ口調に揃えた際、他の通知が手つかずだった
> ためである。**本 FEAT では ja を変更しない** (文面変更は別の判断)。
> 結果として ja と en で語調が揃っていない箇所がある —— native reviewer に
> 申し送ること。

## パラメータに日本語が混ざる件

`{achievement_name}` のようなパラメータは master data 由来で、
`Achievement.name_en` が **まだ存在しない** (FEAT-516 で追加予定)。
それまでは英語の文面に日本語の実績名が入る。`get_i18n_field` 経由で埋めるので、
FEAT-516 が入れば **本ファイルを触らずに**英語化される。

`{player_name}` / `{habit_names}` は user-generated なので翻訳しない (正しい)。
"""

_DEFAULT_LOCALE = 'ja'

# key -> {locale: (title, body)}
# body の `{...}` は `notification_text()` の kwargs で置換する。
NOTIFICATION_MESSAGES: dict[str, dict[str, tuple[str, str]]] = {
    # ── リマインダー (cron: send_reminders) ──────────────────────────────
    'streak_at_risk': {
        'ja': (
            'ストリークが途切れそう！ 🔥',
            '{habit_names} を今日もこなしてストリークを守ろう！',
        ),
        'en': (
            'Your streak is at risk 🔥',
            'Keeping up {habit_names} today will protect your streak.',
        ),
    },
    'daily_check': {
        'ja': (
            '今日の習慣をチェック ✅',
            '{habit_names} がまだ記録されていません',
        ),
        'en': (
            "Today's habits ✅",
            '{habit_names} has not been recorded yet.',
        ),
    },
    # ── 実績 ────────────────────────────────────────────────────────────
    'achievement_unlocked': {
        'ja': (
            '実績解除！ 🏅',
            '実績「{achievement_name}」を解除しました！ +{diamonds}💎{bonus_suffix}',
        ),
        'en': (
            'Achievement unlocked 🏅',
            'You unlocked "{achievement_name}". +{diamonds}💎{bonus_suffix}',
        ),
    },
    # ── レベルアップ (FEAT-449 でサビ口調に統一済) ──────────────────────
    'level_up': {
        'ja': (
            'Lv.{new_level} に到達しましたね 🪶',
            'Lv.{old_level} → Lv.{new_level} に上がりました。',
        ),
        'en': (
            'You have reached Lv.{new_level} 🪶',
            'Lv.{old_level} → Lv.{new_level}.',
        ),
    },
    # ── ソーシャル ──────────────────────────────────────────────────────
    'friend_accepted': {
        'ja': (
            'フレンドが成立しました 🤝',
            '{player_name} さんとフレンドになりました',
        ),
        'en': (
            'You are now friends 🤝',
            'You and {player_name} are now friends.',
        ),
    },
    'friend_request': {
        'ja': (
            'フレンド申請が届いています ⚔️',
            '{player_name} さんからフレンド申請が届きました',
        ),
        'en': (
            'A friend request has arrived ⚔️',
            '{player_name} has sent you a friend request.',
        ),
    },
    'gift_received': {
        'ja': (
            'フレンドから応援が届きました 🪶',
            '{sender_name} さんから届きましたよ ({gift_parts})',
        ),
        'en': (
            'A friend has sent you support 🪶',
            'This arrived from {sender_name} ({gift_parts}).',
        ),
    },
}

# ギフト本文に並べる項目名。`gift_parts` の組み立てに使う。
GIFT_PART_LABELS: dict[str, dict[str, str]] = {
    'xp_boost':       {'ja': '🚀 XP ブースト',        'en': '🚀 XP Boost'},
    'coins':          {'ja': '🪙 コイン +{amount}',    'en': '🪙 Coins +{amount}'},
    'battle_charges': {'ja': '⚔️ バトルチャージ +{amount}', 'en': '⚔️ Battle Charges +{amount}'},
}


def notification_text(key: str, locale: str, **params) -> tuple[str, str]:
    """`(title, body)` を locale 付きで返す。

    未知の key は `KeyError` にする (黙って空文字を送るより早く気付ける)。
    未対応 locale は ja に落とす。
    """
    entry = NOTIFICATION_MESSAGES[key]
    title, body = entry.get(locale) or entry[_DEFAULT_LOCALE]
    return title.format(**params), body.format(**params)


def gift_part_label(key: str, locale: str, **params) -> str:
    """ギフト本文の 1 項目を locale 付きで返す。"""
    entry = GIFT_PART_LABELS[key]
    return (entry.get(locale) or entry[_DEFAULT_LOCALE]).format(**params)


def resolve_player_locale(player) -> str:
    """通知の宛先プレイヤーの locale を返す。

    リクエストの外から呼ばれるので `Accept-Language` は使えない。
    `PlayerSettings.preferred_language` が唯一の手掛かり。
    取得に失敗したら ja (既存挙動と同じ側に倒す)。
    """
    try:
        lang = player.settings.preferred_language
    except Exception:
        return _DEFAULT_LOCALE
    return lang if lang in ('ja', 'en') else _DEFAULT_LOCALE
