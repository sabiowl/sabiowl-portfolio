# 新規ユーザー オンボーディングフロー

> 最終更新: 2026-05-07  
> 対象コード: `mobile/lib/features/auth/` `mobile/lib/core/router/app_router.dart`

---

## 全体フロー図

```
アプリ起動
    │
    ▼
[スプラッシュ画面] ─── 1.5秒 + 認証チェック
    │
    ├─ DRF トークンあり（有効） ─────────────────────────────→ [ホーム画面]
    ├─ ゲストモード中 ──────────────────────────────────────→ [ホーム画面]
    ├─ 未認証 + チュートリアル未表示 ──────────────────────→ [オンボーディング]
    ├─ 未認証 + チュートリアル済み + 登録済み ─────────────→ [ログイン画面]
    └─ 未認証 + チュートリアル済み + 未登録 ──────────────→ [新規登録画面]
```

---

## 1. スプラッシュ画面

**ファイル**: `app_router.dart` — `_SplashScreen`

アプリ起動直後に表示される画面。最低 **1.5 秒**表示しながら、並行して認証状態をチェックする。

### 画面内容

| 要素 | 内容 |
|------|------|
| アイコン | `assets/images/sabi/sabi_normal.png`（120×120） |
| テキスト | 「ReStack」「積み重ねが、力になるのじゃよ」 |
| インジケーター | 紫のサークルプログレス |

### 認証チェックロジック

```
A. トークンあり
   → サーバー検証（最終検証から 24 時間以内はキャッシュ）
   → 有効: /home
   → 無効（401）: /auth/login

B. ゲストモード中（guest_mode = 'true'）
   → /home

C. 未認証 + チュートリアル未表示（has_seen_tutorial が未設定）
   → /onboarding

D. 未認証 + チュートリアル済み + 登録済み（is_registered = 'true'）
   → /auth/login

E. 未認証 + チュートリアル済み + 未登録
   → /auth/register
```

> **補足**: Render の無料プランはスリープ（15分無アクセスで停止）するため、
> ネットワークエラーはオフライン扱いとしてホームへ楽観遷移する（タイムアウトは 60 秒）。

---

## 2. オンボーディング

**ルート**: `/onboarding`  
**ファイル**: `auth/pages/onboarding_page.dart`  
**表示条件**: `has_seen_tutorial` が未設定（初回起動のみ）

### スライド構成（全 4 ページ）

| # | 絵文字 | タイトル | サブタイトル |
|---|--------|----------|------------|
| 1 | 📅 | 今日の一歩が、明日を変える | 毎日の習慣を記録して、成長を実感しよう |
| 2 | 🪶 | 賢者サビが、そばにいるのじゃよ | フクロウの賢者サビが、君の旅を見守り続けるのじゃ |
| 3 | 🌙 | 休むことも、積み上げのうちじゃ | 休息日を設定すれば、ストリークが守られるのじゃよ |
| 4 | 🪶✨ | はじめましょう（アクションスライド） | サビと一緒に積み上げよう |

### ナビゲーション

- **「次へ」ボタン** — スライドを 1 枚進む（ページインジケーター付き）
- **「スキップ」ボタン**（1〜3 ページに表示）— アクションスライドへ直接ジャンプ

### アクションスライドの分岐

```
[アカウントを作成する]
    └─ markTutorialShown() を保存 → /auth/register

[あとで登録する]
    └─ setGuestMode(true) + markTutorialShown() を保存 → /home（ゲストモード）
```

---

## 3. 新規登録画面 / ログイン画面

**ルート**: `/auth/register`（新規）/ `/auth/login`（再ログイン）  
**ファイル**: `auth/pages/auth_page.dart`  
**注記**: 現状 UI・ロジックは同一。新規登録では Magic Link フォームにユーザー名入力欄が追加される。

### 認証方法

```
┌─────────────────────────────────┐
│  [G]  Google で続ける           │  ← 全プラットフォーム
│  [🍎] Apple で続ける            │  ← iOS のみ表示
│                                 │
│  ───── または ─────             │
│                                 │
│  メールで続ける ▼（折りたたみ）  │
└─────────────────────────────────┘
```

> `メールで続ける` はデフォルト折りたたみ。タップで展開される。

---

## 4. Google / Apple ソーシャル認証フロー

**ファイル**: `auth/services/auth_service.dart` → `backend/api/views/auth/social.py`

```
ユーザーがボタン押下
    │
    ▼
[Firebase OAuth（Google/Apple）]
    │  ← Google Sign-In / Sign in with Apple
    ▼
Firebase ID トークン取得
    │
    ▼
POST /api/auth/social/verify/
    │
    ├─ status: "ok"           → 既存ユーザー
    │   └─ DRF トークン保存 → 後処理 → /home
    │
    ├─ status: "new_user"     → 初回登録（Firebase UID で新規作成）
    │   └─ DRF トークン保存
    │       └─ [名前入力シート]（ボトムシート）
    │           └─ ユーザー名入力 → PATCH /api/player/ → 後処理 → /home
    │
    └─ status: "merge_required" → 同メールアドレスのアカウントが既に存在
        └─ [マージ確認シート]（ボトムシート）
            ├─ 「連携してログイン」→ POST /api/auth/social/merge/
            │   └─ 既存アカウントにソーシャルを連携 → DRF トークン保存 → 後処理 → /home
            └─ 「キャンセル」→ 未認証状態に戻る
```

### バックエンド側の処理（新規ユーザーの場合）

1. `User` オブジェクト作成（email / Firebase UID ベース）
2. `PlayerProfile` 作成（name='勇者'、gender='f'）
3. `CharacterStat` × 4 種作成（`create_default_stats`）
4. `SocialAccount` 作成（provider_uid = Firebase UID）
5. DRF トークン発行

---

## 5. Magic Link（メール認証）フロー

**ファイル**: `auth/services/auth_service.dart` → `backend/api/views/auth/magic_link.py`

```
ユーザーがメールアドレス（と名前）を入力 → 送信ボタン
    │
    ▼
POST /api/auth/magic-link/request/
    │  ← MagicLinkToken 生成（有効期限 1 時間）
    │  ← Resend 経由でメール送信
    ▼
[メール送信完了画面]
（「魔法のリンクを送ったよ🪶」）
    │
    ├─ ユーザーがメールのリンクをタップ → ディープリンクでアプリが開く
    │       → URL の ?magic=TOKEN をアプリが自動抽出 → トークン検証へ
    │
    └─ または: URL の ?magic= 以降を手動でフォームに入力
    │
    ▼
POST /api/auth/magic-link/verify/
    │  ← トークン検証・消費（同時リクエスト対策で select_for_update）
    │
    ├─ 新規ユーザーの場合
    │   └─ User + PlayerProfile + CharacterStat × 4 を自動生成
    │
    └─ DRF トークン返却 → 保存 → 後処理 → /home
```

> **メールリンク形式**: `{MAGIC_LINK_BASE_URL}/?magic={token}`  
> リンク未設定のローカル環境では認証コードをプレーンテキストで記載。

---

## 6. 認証後の共通後処理

ソーシャル・Magic Link いずれの方法でも、認証成功後に以下を順番に実行する。

```dart
await _apiClient.saveToken(authToken);      // DRF トークンを SecureStorage に保存
await _apiClient.markAsRegistered();        // is_registered = 'true' を保存
await _migrateGuestData();                  // ゲストデータ移行（下記参照）
await _apiClient.setGuestMode(false);       // ゲストフラグを削除
// → /home へ遷移
```

---

## 7. ゲストモード

**「あとで登録する」** を選択したユーザーが利用する。

### 特徴

| 項目 | 動作 |
|------|------|
| サーバー通信 | なし（DRF トークン未取得） |
| 習慣の作成 | SharedPreferences にローカル保存 |
| 習慣の達成・EXP | サーバーに記録されない |
| タイムライン | 利用不可（API 必要） |
| ゲストバナー | ホーム画面に登録促進バナー表示 |

### 正式登録時のデータ移行（`_migrateGuestData`）

```
POST /api/auth/guest-migrate/
  body: { habits: [ ... ] }   ← SharedPreferences から取得したローカル習慣リスト

→ バックエンドでアカウントに習慣を移行（最大 20 件）
→ ローカルデータを削除
```

---

## 8. ホーム画面（初回到達後）

**ファイル**: `habits/pages/home_page.dart`

認証完了後、初めてホーム画面に到達したユーザーが経験する動作。

| タイミング | 内容 |
|-----------|------|
| 画面表示直後 | 通知許可のソフトプロンプト（セッション中 1 回のみ） |
| タイムライン初期化 | 当日のデフォルトテンプレートを自動作成（その日の初回のみ） |
| 習慣リスト | 空の状態（「＋ 習慣を追加する」ボタンが表示される） |
| サビのメッセージ | 時間帯に応じたあいさつが表示される |

---

## 9. ローカルストレージ キー一覧

| キー | ストレージ | 内容 |
|------|-----------|------|
| `hg_token` | FlutterSecureStorage | DRF 認証トークン |
| `is_registered` | FlutterSecureStorage | 登録済みフラグ（`'true'`） |
| `has_seen_tutorial` | FlutterSecureStorage | チュートリアル表示済みフラグ（`'true'`） |
| `guest_mode` | FlutterSecureStorage | ゲストモードフラグ（`'true'`） |
| `token_saved_at` | FlutterSecureStorage | トークン保存日時（ISO 8601） |
| `token_validated_at` | FlutterSecureStorage | 最終サーバー検証日時（24h キャッシュ用） |
| `guest_habits` | SharedPreferences | ゲストモードの習慣リスト（JSON 配列） |

> `is_registered` / `has_seen_tutorial` / `guest_mode` はログアウト時に削除されない（再起動後の遷移先判定に使用）。

---

## 10. 開発者向け補足

### デバッグビルドの自動ログイン

`auth_page.dart` の定数:
```dart
const bool _kDevAuthSkipEnabled = true;  // true のとき認証画面で自動ログイン実行
```

`kDebugMode && _kDevAuthSkipEnabled` が true の場合、`/auth/register` 表示と同時に
`POST /api/auth/dev-login/` が自動実行され、固定の開発アカウント（`dev@restack.local`）
でログインする。認証画面はローディングインジケーターのみ表示される。

**三重ガード**: `DEBUG=True` かつ `DEV_LOGIN_ENABLED=True` かつ SQLite 接続のみ動作。
PostgreSQL（本番 DB）では絶対に動作しない。

### チュートリアルオーバーレイ

```dart
const bool _kTutorialEnabled = false;  // 現在無効
```

`true` にすると新規登録後にチュートリアルオーバーレイ（`TutorialOverlay`）が表示される。
現在は無効化されており、登録後は即 `/home` へ遷移する。

---

## 状態遷移まとめ

```
[未インストール]
    ↓ インストール・初回起動
[スプラッシュ] → [オンボーディング]
    ↓ 「あとで登録する」              ↓ 「アカウントを作成する」
[ホーム（ゲスト）]             [新規登録画面]
    ↓ 登録ボタン押下                   ↓ 認証成功
[新規登録画面]             ←→ [名前入力シート（Google/Apple）]
    ↓                                  ↓ or マージ確認シート
[後処理（トークン保存・ゲストデータ移行）]
    ↓
[ホーム画面（正規ユーザー）]
```
