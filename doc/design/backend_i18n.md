# Backend i18n — 設計文書 (FEAT-489 Phase 4)

> 作成日: 2026-07-29
> **ステータス**: 🟡 起稿中 (Develop 委譲前の PM draft、実装確定は Aug 2026 中に PM 判断)
> **関連**: [FEAT-489 v1.1 英語圏 launch](../instructions/FEAT-489_v1_1_english_localization.md) Phase 4 / [i18n_persona_en.md](i18n_persona_en.md) Phase 3
> **想定読者**: (1) 本 FEAT の Develop 委譲時の実装担当 (2) 契約テスト設計者 (3) Aug 2026 の PM 判断者 (arb 一括 review + Backend migration 承認)
> **見積**: ~20-30h (Backend model + migration + serializer mixin + middleware + admin form + contract test)

---

## 1. Purpose

Sabiowl の Backend が返す **運営管理コンテンツ (master / seed data)** を英語で配信可能にするための設計。対象は 5 model × 8 field:

| Model | 対象 field | 内容 | 現行値の例 |
|---|---|---|---|
| SabiMessage | `content` | サビの台詞 (プール別) | 「素晴らしいですね。地層になっていきますよ。」 |
| Announcement | `title`, `body` | 運営お知らせ (2 field) | 「v1.0.5 リリースのお知らせ」 |
| TaskSuggestion | `title`, `hint` | タスク登録候補 (2 field) | 「ジョギング」/ 「朝食後 30 分」 |
| Enemy | `name` | 敵名 | 「ゴブリン」 |
| Character | `name`, `role`, `tagline`, `description` | キャラマスタ (4 field) | 「アリア」/「魔法剣士」/「静かな航路を...」 |

**合計**: 5 model × 平均 1.8 field = **9 fields** (実装上 `_en` field 追加は 9 個)。

### API エラー文言 (**部分的に対象**、2026-08-02 追記)

> 【重要】この行は **当初 in にも out にも書かれていなかった**。その結果、
> Backend が返す user 向けエラー 150 件超が日本語のまま英語 UI に出る状態が
> 「誰の担当でもない」まま残っていた
> ([20260802 functional review](../codebase_review/20260802_functional_review.md) §3 B-2)。
> **書いていない = 対象外、ではない**という教訓としてここに残す。

| 範囲 | v1.1 の扱い |
|---|---|
| ユーザーが日常的に踏む上位 20 code | **英語化する**。Flutter 側で `code → ARB` を解決 |
| それ以外の code | server の ja を表示 (現状維持)。未知 code は message にフォールバック |
| admin / webhook 向けエラー | 対象外 (運営 or 外部サービスのみが見る) |

実装は **FEAT-515**。前提として旧形式 `Response({'error': ...})` 78 件の
`error_response()` 移行が要る (code が無いと引くものが無いため)。

v1.2+ で「全 code を対象にする」か「Backend が locale 別 message を返す」かを再検討する。

#### 実装結果 (2026-08-04、FEAT-515 Phase 2 完了時点)

`error_response()` の総数は **148 件**。うち **20 code を Flutter 側で locale 解決**する。
対応表は `mobile/lib/core/api/api_error_messages.dart`。

対象 20 件は、指示書 §3.2 の当初案を **Phase 1 完了後に再選定**した:

- **足した 3 件**: `daily_battle_limit_reached` / `not_enough_charges` /
  `not_enough_potions` — battle 系は Phase 1 まで旧形式だったため当初案に載らなかったが、
  日常プレイでの遭遇頻度は上位
- **外した 3 件**: `timeline_create_integrity_error` / `contact_invalid_email` /
  `contact_validation_failed` — race 起因 or 問い合わせフォーム限定で頻度が低い。v1.2 送り
- **IAP は対象にしなかった**: 指示書は「IAP 購入失敗が入る可能性が高い」としていたが、
  実測すると `iap_webhook_*` は **RevenueCat webhook 受信側**のエラーで
  ユーザーの画面には出ない。当初の想定が外れていた

##### ja も ARB から引く (実装上の重要な副作用)

対応表は **locale を問わず** ARB を引く。つまり **日本語表示も ARB の値になる**。

そのため ARB の ja は Backend の現行 message と **1 文字も違えてはいけない**。
ずれると日本語ユーザーの表示が黙って変わり、例外もテスト失敗も起きない。
この同期は `backend/api/tests/test_error_code_l10n_sync.py` が縛っている
(Backend の message を AST で読み、Dart の switch と ja ARB を突き合わせる)。

##### prose ではなく machine-readable な値を送る

`gacha_pull_not_enough_tickets` の message は `f'{name}チケットが…'` で、
`{name}` が **日本語のチケット名**だった。これは英訳しても
「デイリーチケットが not enough」のような混在文にしかならない。

Phase 2 で `fields={'ticket_type': ticket_type}` を足し、Flutter 側の ICU select で
組み立てる形に変えた。**以降このパターンを標準とする** —— 文中に値を埋める
エラーは、prose ではなく `fields` に machine-readable な値を載せる。

---

対象外 (v1.1 では触らない):
- User-generated content (`Habit.name`, `TimelineEvent.title`, `ChecklistItem.text`, `FreeMemo.content` 等) — user が **自分の preferred_language で書いた原文** をそのまま保存
- Django admin UI 内部の verbose_name / help_text — 運営 (subaru) のみが見る、翻訳不要
- Email 本文 (registration confirm 等) — 本 FEAT スコープ外、v1.2 で `django.utils.translation` + `gettext` 導入時に対応

---

## 2. Design Decisions (Option 比較 → 採択)

### 2.1 ストレージ戦略

| Option | 内容 | Pros | Cons | 採否 |
|---|---|---|---|---|
| **A. 既存 model に `_en` field 追加** | `SabiMessage.content` + `SabiMessage.content_en` | シンプル / 既存 code 変更少 / N+1 発生ゼロ | 3 言語以上に拡張時 `_zh`/`_ko`/`_es` を横に増やす必要 | ✅ **採用** (v1.1 は日英 2 言語、YAGNI) |
| B. 別 table (translation table 正規化) | `SabiMessage` + `SabiMessageI18n(sabi_message_id, locale, content)` | N 言語スケール、正規化された schema | join 増、既存 serializer 全書換 | v2.0 で中/韓/西追加時に再検討 |
| C. JSON field | `SabiMessage.content_i18n = JSONField(default=dict)` | field 増えない、柔軟 | admin UI での編集困難、type safety 弱、契約テスト複雑 | 却下 |

**決定**: **Option A**。v1.1 は日英 2 言語のみで、Option B の正規化コストは overkill。将来 v2.0 で 3+ 言語対応時に、Option A → B へ migration を書く前提 (シンプルな move + data copy)。

### 2.2 Fallback 戦略

英訳未完了の master data が存在するときの挙動:

| Option | 内容 | 採否 |
|---|---|---|
| **A. Silent fallback to ja** | `_en` が null/空文字なら `content` を返す。log は info level で「fallback occurred」記録 | ✅ **採用** |
| B. Explicit fallback marker | `_en` が空なら "[JA] {content}" のように prefix 付きで返す | 却下 (UX が壊れる) |
| C. Fail hard | `_en` が空なら 500 error | 却下 (運営が全 master 英訳完了する前に deploy 不可能) |

**決定**: Silent fallback (A)。段階的な英訳完了を許容、log で監視。

### 2.3 Middleware 選択

| Option | 内容 | 採否 |
|---|---|---|
| A. Django 標準 `LocaleMiddleware` | `settings.LANGUAGE_CODE` + `USE_I18N=True` + `gettext` を前提とする | 却下 (本 FEAT は "DB stored content" i18n で、gettext は使わない) |
| **B. カスタム `I18nMiddleware`** | `request.locale = 'ja' or 'en'` だけ確定、view / serializer で使用 | ✅ **採用** |

**決定**: Option B。既存 gettext 経路 (`LANGUAGE_CODE='ja'`) と干渉しない、責務が明確。

### 2.4 Locale 判定の優先順位

`I18nMiddleware` で `request.locale` を確定するときの優先順:

1. **`Accept-Language` header**
2. **`PlayerSettings.preferred_language`** (認証済 request で、ヘッダが無い場合)
3. **`'ja'` default** (どちらもない or 対応外 locale)

Sabiowl v1.1 の対応 locale: `'ja'` / `'en'` の 2 値のみ。それ以外は default 'ja' に fallback。

#### 【2026-08-02 改訂】1 と 2 を入れ替えた経緯

当初は `preferred_language` を最優先にしていた。前提は
**`Accept-Language` = 端末 locale** で、「端末が英語でもアプリ設定が日本語なら
日本語を返す」を守るため。この前提のもとでは正しい設計だった。

しかし Phase 2E の `api_client.dart` は端末 locale ではなく
**`ServiceL10n.current` = アプリが今表示している言語**を送る実装になった。
ヘッダの意味が変わったのに優先順位が見直されず、次の 2 つが壊れていた:

1. `preferred_language` は `default='ja'` の非 null field で「未設定」を表現
   できない。よって認証済ユーザーは常に 1 段目で `'ja'` に確定し、
   **`Accept-Language` が構造的に到達不能**だった。
   「US で新規インストール → 英語 UI → 設定画面を開かない」という最も普通の
   導線で、Flutter は英語 / Backend は日本語という 2 言語混在になっていた。
2. 逆に `preferred_language='en'` が残ったまま日本語に戻したユーザーには、
   UI 日本語 + サーバー文言英語という逆向きの混在が起きうる。

ヘッダは「今表示している言語」そのものなので、保存値より常に新しい。
したがってヘッダを優先するのが実態に合う。

**この順序変更により、リクエストに対する応答の locale については
`preferred_language` の `default=''` 化 (migration) も起動時 PATCH も不要になった**
([20260802 functional review](../codebase_review/20260802_functional_review.md)
懸念点 2 の改善案 (a)(b) は、いずれも採らずに解消)。

`preferred_language` は引き続き以下のために保持する:

- ヘッダを送らないクライアント (Phase 2E 以前のビルド / API 直叩き)
- **リクエストが存在しないサーバー起点の配信** (FCM push 等、v1.1+)

### ⚠️ サーバー起点の配信には起動時 PATCH が必要 (2026-08-03 追記)

上の「起動時 PATCH も不要」は **リクエスト応答に限った話**である。訂正する。

Mobile が `preferred_language` を送るのは `LocaleSideEffects.apply()` だけで、
それを呼ぶのは **設定画面で明示的に言語を選んだとき**のみ
(`setLanguage` の呼出は `settings_page.dart` の 1 箇所、実測)。

したがって「US で新規インストール → 英語 UI → 設定画面を開かない」という
最も普通の導線では、Backend の `preferred_language` は **`'ja'` のまま**になる。

- リクエスト応答: Accept-Language が効くので **問題ない**
- **FCM push / リマインダー**: リクエストが無いので `preferred_language` しか
  手掛かりが無く、**英語ユーザーに日本語で届く**

通知の i18n に着手する時点で、**起動時に解決した locale を fire-and-forget で
PATCH する処理**を併せて入れること。片方だけ実装すると「通知を英語化したのに
英語ユーザーには日本語で届く」という最も分かりにくい状態になる。

なお 2 段目の読み取りは `player.settings` プロパティ (`get_or_create`) を使わず
`PlayerSettings.objects.filter(...).values_list(...)` で行う。locale 解決という
**読み取り操作のために行を INSERT しない**ため。

### 2.5 Serializer 実装パターン

| Option | 内容 | 採否 |
|---|---|---|
| A. 各 serializer に個別ロジック | `SabiMessageSerializer.get_content()` で分岐 | 却下 (5 model × 8 field で DRY 破綻) |
| **B. `I18nFieldMixin` mixin** | `class I18nFieldMixin: def get_i18n(self, obj, base_field): ...` で共通化 | ✅ **採用** |
| C. Custom `I18nCharField` serializer field | `I18nCharField(base='content')` を宣言的に | Nice-to-have、将来 refactor 候補 (v1.2+) |

**決定**: Option B。5 model 統一パターン、`context['request']` から locale 取得。

### 2.6 Migration 戦略

| Option | 内容 | 採否 |
|---|---|---|
| A. 5 model 一括 migration | 単一 migration file で 9 field 全追加 | 却下 (roll back 粒度が粗い) |
| **B. Model 別 5 migration** | `0181_sabi_message_content_en.py` / `0182_announcement_i18n.py` / ... | ✅ **採用** |

**決定**: Option B。migration 順序: SabiMessage → Announcement → TaskSuggestion → Enemy → Character。各 migration は **field 追加のみ + `blank=True, default=''`**、backfill なし (CLAUDE.md § 破壊的データマイグレーション禁止 遵守)。

**英訳データ投入**: 別 management command (`translate_master_data.py`) で明示手動実行。Deploy 順序:
1. Migration (field 追加) を prod に deploy
2. 運営が admin で英訳を入力 (or management command で bulk import)
3. Mobile 側 `preferred_language='en'` を有効化

---

## 3. Data Model Changes

### 3.1 追加 field 一覧 (canonical spec)

すべての `_en` field は以下の共通契約:
- `blank=True, default=''` — 英訳未完了を許容 (§2.2 silent fallback 前提)
- 元 field と同じ `max_length` (CharField) or 制約なし (TextField)
- `verbose_name` は日本語で `'{元}(英語版)'`

| Model | 追加 field | 型 | max_length | verbose_name |
|---|---|---|---|---|
| SabiMessage | `content_en` | TextField | (制約なし) | 'セリフ(英語版)' |
| Announcement | `title_en` | CharField | 60 (元と同じ) | 'タイトル(英語版)' |
| Announcement | `body_en` | TextField | (制約なし) | '本文(英語版)' |
| TaskSuggestion | `title_en` | CharField | 100 (元と同じ) | 'タイトル(英語版)' |
| TaskSuggestion | `hint_en` | CharField | 100 (元と同じ) | '補足テキスト(英語版)' |
| Enemy | `name_en` | CharField | 64 (元と同じ) | '表示名(英語版)' |
| Character | `name_en` | CharField | 50 (元と同じ) | '名前(英語版)' |
| Character | `role_en` | CharField | 50 (元と同じ) | '役職(英語版)' |
| Character | `tagline_en` | CharField | 80 (元と同じ) | 'キャッチコピー(英語版)' |
| Character | `description_en` | TextField | (制約なし) | '説明文(英語版)' |

**合計**: 10 fields (9 と書いたが、実は Character が 4 field なので合計 10)。

### 3.2 PlayerSettings への追加

```python
# backend/api/models/player_state.py の PlayerSettings に追加
class PlayerSettings(models.Model):
    # ... 既存 field ...

    LANGUAGE_CHOICES = [
        ('ja', '日本語'),
        ('en', 'English'),
    ]
    preferred_language = models.CharField(
        max_length=8,
        choices=LANGUAGE_CHOICES,
        default='ja',
        verbose_name='優先言語',
        help_text='FEAT-489 Phase 4 (v1.1)。null 相当時は Accept-Language header → ja default の順で解決。',
    )
```

Default `'ja'` にすることで既存 user への影響ゼロ。onboarding 時に user 選択 UI (Phase 5) を出して "ja" or "en" を明示化。

---

## 4. API Contract

### 4.1 `I18nMiddleware` 実装案

```python
# backend/api/middleware/i18n.py (新規)
from typing import Callable

class I18nMiddleware:
    """FEAT-489 Phase 4: request.locale を確定する。

    優先順位:
      1. request.user.player_profile.settings.preferred_language (認証済)
      2. Accept-Language header (未認証)
      3. 'ja' default
    """
    SUPPORTED_LOCALES = ('ja', 'en')

    def __init__(self, get_response: Callable):
        self.get_response = get_response

    def __call__(self, request):
        request.locale = self._resolve_locale(request)
        response = self.get_response(request)
        # CDN / Mobile cache が locale 別に効くように Vary header 追加
        response['Vary'] = 'Accept-Language'
        return response

    def _resolve_locale(self, request) -> str:
        # 1. PlayerSettings.preferred_language (認証済)
        if hasattr(request, 'user') and request.user.is_authenticated:
            try:
                lang = request.user.player_profile.settings.preferred_language
                if lang in self.SUPPORTED_LOCALES:
                    return lang
            except (AttributeError, ObjectDoesNotExist):
                pass  # ゲスト or 未設定、次の経路へ
        # 2. Accept-Language header
        accept = request.META.get('HTTP_ACCEPT_LANGUAGE', '')
        # 'en-US,en;q=0.9,ja;q=0.8' 形式を parse
        for tag in accept.split(','):
            code = tag.split(';')[0].strip().lower()[:2]
            if code in self.SUPPORTED_LOCALES:
                return code
        # 3. Default
        return 'ja'
```

**settings.py への登録** (順序注意):

```python
MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'whitenoise.middleware.WhiteNoiseMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'corsheaders.middleware.CorsMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',  # request.user はここで確定
    'api.middleware.i18n.I18nMiddleware',                        # ← ここ (AuthenticationMiddleware より後)
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]
```

### 4.2 `I18nFieldMixin` 実装案

```python
# backend/api/serializers/mixins.py (新規 or 既存 mixin ファイルに追加)
from rest_framework import serializers

class I18nFieldMixin:
    """FEAT-489 Phase 4: `_en` field への silent fallback を汎用化。

    使い方 (SabiMessage 例):
        class SabiMessageSerializer(I18nFieldMixin, serializers.ModelSerializer):
            content = serializers.SerializerMethodField()

            def get_content(self, obj):
                return self.get_i18n(obj, 'content')

            class Meta:
                model = SabiMessage
                fields = ['id', 'content', 'pool', 'is_active']
    """
    def get_i18n(self, obj, base_field: str) -> str:
        locale = getattr(self.context.get('request'), 'locale', 'ja')
        if locale == 'en':
            en_value = getattr(obj, f'{base_field}_en', '') or ''
            if en_value.strip():
                return en_value
            # Silent fallback + log
            import logging
            logger = logging.getLogger(__name__)
            logger.info(
                'i18n_fallback',
                extra={
                    'model': obj.__class__.__name__,
                    'obj_id': getattr(obj, 'pk', None),
                    'field': base_field,
                    'from_locale': 'en',
                    'to_locale': 'ja',
                },
            )
        # ja (or fallback from en)
        return getattr(obj, base_field, '')
```

**PostHog 連携**: `logger.info('i18n_fallback', ...)` を PostHog カスタムイベント経由で計測、英訳完了度の管理指標にする (Phase 5 で dashboard 化)。

### 4.3 Serializer 実装例 (5 model)

```python
# SabiMessageSerializer
class SabiMessageSerializer(I18nFieldMixin, serializers.ModelSerializer):
    content = serializers.SerializerMethodField()
    def get_content(self, obj): return self.get_i18n(obj, 'content')
    class Meta: model = SabiMessage; fields = ['id', 'content', 'pool', 'is_active']

# AnnouncementSerializer
class AnnouncementSerializer(I18nFieldMixin, serializers.ModelSerializer):
    title = serializers.SerializerMethodField()
    body  = serializers.SerializerMethodField()
    def get_title(self, obj): return self.get_i18n(obj, 'title')
    def get_body(self, obj):  return self.get_i18n(obj, 'body')
    # ... 以下同パターン
```

**契約**: **client は既存 field 名 (`content`, `title`, `body`) をそのまま受け取る**。`_en` field は Backend 内部実装、API contract には登場しない。

### 4.4 PlayerSettings API 拡張

`PATCH /api/player/settings/` の request body に `preferred_language` を追加:

```json
{ "preferred_language": "en" }
```

serializer 側は `LANGUAGE_CHOICES` の validation を自動、無効値は 400 error。

---

## 5. Cache Integration (FEAT-476 との整合性)

### 5.1 Backend 側

`Vary: Accept-Language` header を全 response に付与 (I18nMiddleware §4.1)。CDN (Render Static or 将来 Cloudflare) は locale 別に cache する。

### 5.2 Mobile 側 (Flutter `dio_cache_interceptor`)

**問題**: FEAT-476 で導入した `dio_cache_interceptor` は URL + method の組合わせを cache key とする。同じ URL でも locale 別にレスポンスが異なるため、key 分離が必要。

**対応案** (Phase 2 実装時に Develop 委譲):
```dart
// dio_cache_interceptor の keyBuilder を override
CacheOptions(
  // ... 既存設定 ...
  keyBuilder: (request) {
    final baseKey = CacheOptions.defaultCacheKeyBuilder(request);
    final locale = request.headers['Accept-Language'] ?? 'ja';
    return '$baseKey:$locale';
  },
)
```

**影響範囲**: FEAT-476 の 5 endpoint (`characters/24h` / `enemies/24h` / `task-suggestions/12h` / `announcements/5min` / `challenges/5min`) すべてに適用。既存 ja cache は locale 変更時に無効化されず並存、期限で自然消滅。

---

## 6. Migration Plan

### 6.1 Migration ファイル (5 個)

```
backend/api/migrations/
├── 0181_sabi_message_content_en.py       # SabiMessage.content_en 追加
├── 0182_announcement_i18n.py              # Announcement.title_en / body_en 追加
├── 0183_task_suggestion_i18n.py           # TaskSuggestion.title_en / hint_en 追加
├── 0184_enemy_name_en.py                  # Enemy.name_en 追加
└── 0185_character_i18n.py                 # Character.name_en / role_en / tagline_en / description_en 追加
```

各 migration は `AddField` operations のみ、data 操作 (`RunPython`) は含めない (CLAUDE.md § 破壊的データマイグレーション禁止 遵守)。

### 6.2 PlayerSettings migration

```
backend/api/migrations/
└── 0186_player_settings_preferred_language.py    # PlayerSettings.preferred_language 追加
```

Default `'ja'` で既存 row は default value で埋まる (Django 標準挙動)。

### 6.3 英訳データ投入 (management command)

```python
# backend/api/management/commands/translate_master_data.py (新規)
class Command(BaseCommand):
    """FEAT-489 Phase 4: 運営が英訳 YAML から master data の _en field に流し込む。

    使い方:
      python manage.py translate_master_data --input doc/data/master_translations_en.yaml --model sabi_message

    冪等性: 既存 _en field は上書き。runs multiple times safely.
    """
    def handle(self, *args, **options):
        # 5 model 対応、YAML の (id, content_en) を bulk update
        ...
```

**YAML 例** (`doc/data/master_translations_en.yaml`):
```yaml
sabi_message:
  - id: 1
    content_en: "Well done. Small steps like these become steady layers over time."
  - id: 2
    content_en: "What matters most is that you faced today. That is enough."
character:
  - id: 1
    name_en: "Aria"
    role_en: "Mage Knight"
    tagline_en: "One who walks the quiet route with you."
    description_en: "..."
```

**採用理由 (Option 比較)**:
- vs admin UI 手入力: 大量投入で工数削減、native reviewer から YAML で受け取る前提
- vs `RunPython` 内蔵: 冪等性 + roll back 容易性で分離 (§6.1 migration は field 追加のみ)

---

## 7. Testing Plan

### 7.1 Contract test (~10 件)

```python
# backend/api/tests/test_i18n.py (新規)
class I18nContractTest(TestCase):
    """FEAT-489 Phase 4 契約テスト。"""

    def test_ja_default(self):
        """未認証 + Accept-Language なし → ja が返る"""

    def test_en_via_accept_language(self):
        """未認証 + Accept-Language: en-US → en が返る"""

    def test_en_via_preferred_language(self):
        """認証済 + preferred_language='en' → en が返る"""

    def test_preferred_language_priority(self):
        """preferred_language='en' + Accept-Language: ja → en (preferred_language 優先)"""

    def test_silent_fallback_when_en_null(self):
        """en request + _en が空 → ja fallback、log 記録"""

    def test_unsupported_locale_falls_back_to_ja(self):
        """Accept-Language: zh-CN → ja fallback"""

    def test_vary_header(self):
        """全 response に Vary: Accept-Language が付与される"""

    def test_5_models_all_covered(self):
        """SabiMessage / Announcement / TaskSuggestion / Enemy / Character の 5 endpoint すべてで i18n が有効"""

    def test_user_generated_content_not_translated(self):
        """Habit.name は preferred_language に関わらず原文のまま返る"""

    def test_multi_field_i18n(self):
        """Character の 4 field (name/role/tagline/description) が独立に fallback"""
```

### 7.2 Migration test

- prod-like fixture (sqlite でも Postgres でも動く) で `python manage.py migrate` を実行、5 migration 順次適用でエラーなし
- rollback `python manage.py migrate api 0180` で戻せる

### 7.3 Load test (skipped、v1.2 で判断)

英訳の分岐は per-request per-field で ~50-100 個のロジック追加。1 request 内で 100 回の getattr / str comparison = ~10μs レベル、負荷影響は無視できる想定。α英語話者テスト (Sep 2026) 時にレスポンスタイム観察で reality check。

---

## 8. Pre-mortem (想定される失敗シナリオ)

### S1: `preferred_language` field 追加時の migration 事故 (カテゴリ 1 データ整合性)

**シナリオ**: PlayerSettings migration 適用時、既存 全 user の row に対して default `'ja'` を書き込む → prod で数万 row × PostgreSQL row-lock で 30 秒間 API 応答停止。

**緩和策**:
- `default='ja'` は Django が **schema level** で解決 (row 書換なし、alter table + set default のみ)、実 row 書換は発生しない
- 念のため deploy 前に `EXPLAIN` で migration の実行計画確認、`ALTER TABLE ... ADD COLUMN ... DEFAULT 'ja'` が row-level lock を取らないことを検証 (PostgreSQL 11+ は取らない、Sabiowl は 16 系で問題なし)

### S2: I18nMiddleware で認証 request の DB クエリ N+1 (カテゴリ 2 競合/性能)

**シナリオ**: 各 request で `request.user.player_profile.settings.preferred_language` を評価 = 認証 + PlayerProfile SELECT + PlayerSettings SELECT の 3 クエリ追加 (~30ms × 1000 req/s = 30% overhead)。

**緩和策**:
- `PlayerSettings` を `select_related('player_profile', 'player_profile__settings')` で DRF authentication middleware 段で pre-load、middleware 到達時にはメモリ上
- middleware 側で `settings` にアクセスするときは lazy load を明示 (`hasattr` チェック → try/except で fallback)
- contract test に「認証 request で追加クエリが 1 個以下」を保証する `assertNumQueries` テスト追加

### S3: Cache key の locale 分離漏れで stale content 表示 (カテゴリ 3 副作用の連鎖 + FEAT-476)

**シナリオ**: FEAT-476 dio_cache_interceptor が locale 別 cache key に分けていない → user が preferred_language を en に変更後、Mobile が 24h ja response を cache から返し続ける → 「切替えたのに日本語のまま」bug。

**緩和策**:
- 本設計文書 §5.2 の keyBuilder override を **Phase 2 実装時に必須要件** として指示書に明記
- Mobile 側で preferred_language 変更時に `dio_cache_interceptor` の全 cache を invalidate (`CacheStore.clean()` 呼出) する UX flow を実装
- 契約テスト: preferred_language 変更後の初回 request で 200 (not 304) + fresh content が返ることを確認

### S4: 英訳未完了 master data の silent fallback で "気付かれない" (カテゴリ 6 UX + 運用)

**シナリオ**: 運営が Enemy.name_en を入れ忘れて deploy → en user のバトル画面で 「ゴブリン」等の日本語 name が突然出て混乱 → App Store 低評価 review。

**緩和策**:
- I18nMiddleware で fallback 発生時に PostHog `i18n_fallback` event を送信 (~4.2 実装済)
- 週次で PostHog dashboard 監視、fallback 発生率 > 5% で alert
- Deploy 前 checklist に「en_field が空の master data ゼロ」を追加 (management command `check_i18n_coverage.py` で自動 verify)

### S5: Character.description の英訳が場面 dependent で "context ズレ" (カテゴリ 3 副作用の連鎖 + Phase 3 persona)

**シナリオ**: Character.description = Sabi 目線での紹介文 (Phase 3 persona に沿った tone) だが、native reviewer が context を知らずに editorial style で「A brave knight who fights for justice.」等の一般的な description に書き換え → Sabi 哲学と乖離。

**緩和策**:
- YAML translation ファイル (`master_translations_en.yaml`) の各 entry に `_context` field を追記 (「これは Sabi 目線の紹介文、Phase 3 persona §1.1 参照」)
- Phase 3 persona guide (i18n_persona_en.md) を native reviewer に配布時、Character description を Sabi voice ではなく **narrative voice** で書くのか **Sabi voice** で書くのか **明確に指示**
- 決定 (PM draft): **narrative voice** (Sabi は "アプリの声" で Character の "外部紹介文" とは別軸)。Phase 3 persona §1 の 4 scene ルールは Character.description には適用しない。

### S6: PlayerSettings 通信 payload 増加 (カテゴリ 6 UX + カテゴリ 7 外部依存)

**シナリオ**: PlayerSettings に preferred_language 追加 = FEAT-478 4 分割 model の追加 field 1 個 = payload ~10 bytes 増。Home bootstrap API (FEAT-273) response が 10 bytes 増える。

**緩和策**:
- 実質的に無視できる規模 (10 bytes / 30KB total = 0.03%)
- 対応不要、記録のみ

### S7: Django admin での英訳入力の UX (カテゴリ 6 運用)

**シナリオ**: 運営 (subaru) が admin UI で SabiMessage 100 件の content_en を入れる時、1 件ずつ open/edit/save で疲弊 → 英訳完了率 stagnate。

**緩和策**:
- Django admin の list view で `content_en` を inline 編集可能に (`list_editable = ['content_en']`)
- または YAML bulk import (§6.3 の management command) で完全 bypass
- 決定: 両方提供。少量修正は inline、大量投入は YAML。

---

## 9. Timeline (Phase 4 内訳)

| Sub-phase | 内容 | 期間 | 担当 |
|---|---|---|---|
| **4.1** Migration 実装 (5 file + PlayerSettings) | AddField only、backfill なし | ~2h | Develop |
| **4.2** I18nMiddleware 実装 + settings.py 登録 | ~4.1 の設計を実装、`select_related` 最適化 | ~2h | Develop |
| **4.3** I18nFieldMixin 実装 + 5 serializer 適用 | ~4.2 の設計を実装 | ~3h | Develop |
| **4.4** PlayerSettings API 拡張 (`preferred_language`) | serializer + view の validation | ~1h | Develop |
| **4.5** Django admin UI 整備 (list_editable 化) | 5 model の admin.py 更新 | ~2h | Develop |
| **4.6** management command 実装 (`translate_master_data.py` + `check_i18n_coverage.py`) | YAML → DB bulk update + coverage 監視 | ~3h | Develop |
| **4.7** Contract test (10 件) | §7.1 の pattern | ~4h | Develop |
| **4.8** PostHog event 統合 (`i18n_fallback`) | logger → PostHog 送信 pipeline | ~2h | Develop |
| **4.9** Local + Render dev 動作確認 + code review | 契約テスト + Postman で 5 endpoint 手動確認 | ~3h | Develop + PM |
| **合計** | | **~22h** | (~3 営業日) |

**Prod deploy 順序** (FEAT-489 Phase 4 完了時):
1. Migration 5+1 個を release ブランチに merge → prod auto-deploy
2. YAML 英訳データを prod DB に投入 (management command)
3. Mobile 側 `PlayerSettings.preferred_language` UI + dio_cache keyBuilder を release ブランチに merge (Phase 5 と bundle)
4. α英語話者テスト (Phase 6) 開始

---

## 10. Trade-offs Explicitly Accepted

本設計で **意図的に妥協** した点、Aug 2026 の PM 判断者向け明示:

1. **3 言語以上に拡張性なし**: Option A 採用のため、中/韓/西追加時は Option B へ migration が必要 (v2.0 での再設計コスト ~1 週間、AoY 判定)
2. **英訳未完了の silent fallback**: 運営が全 master 英訳完了する前でも deploy 可能な代わりに、fallback 検知は PostHog monitoring 依存 (§S4)
3. **User-generated content は翻訳しない**: Habit.name / TimelineEvent.title 等の user 書字は原文のまま、preferred_language 変更しても内容は変わらない (§1)
4. **Email 本文は本 FEAT 対象外**: v1.2 で `gettext` 導入時に対応、v1.1 では registration 等のメールは日英ハードコード分岐で対応
5. **`I18nCharField` custom field 化は v1.2+ refactor 候補**: 現状 mixin (`I18nFieldMixin`) で十分、宣言的 API への進化は将来課題

---

## 11. References

- [FEAT-489 v1.1 英語圏 launch](../instructions/FEAT-489_v1_1_english_localization.md) — 本設計文書は Phase 4 の deliverable
- [i18n_persona_en.md](i18n_persona_en.md) — Phase 3 サビ英語人格、Character.description 翻訳時に参照
- [FEAT-476 (2026-07-03) HTTP キャッシュ層](../instructions/FEAT-476_http_cache_layer.md) — 本 FEAT §5.2 で keyBuilder override が必要
- [FEAT-478 (2026-07-06) PlayerProfile 4 State 分割](../instructions/FEAT-478_player_state_split.md) — PlayerSettings がここに位置する
- [FEAT-200 PostHog integration](../instructions/FEAT-200_posthog_analytics_integration.md) — §S4 fallback 監視で使用
- [CLAUDE.md § マイグレーション規則](../../CLAUDE.md#マイグレーション規則) — 破壊的データマイグレーション禁止、backfill 分離
- [CLAUDE.md § API 設計規則](../../CLAUDE.md#api-設計規則) — 契約テスト設計原則

---

## 12. Change Log

- **2026-07-29**: 初版起稿 (FEAT-489 Phase 4 draft、PM 直接、Phase 3 と同じ「Pre-mortem #1 予防 = cognitive load 高い作業を先送りしない」精神で Phase 1 完了直後に着手)。Aug 2026 の PM 判断で最終確定 → Develop 委譲、~22h 見積、~3 営業日想定。
