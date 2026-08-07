# lib/l10n — ARB Key Naming Convention

> 作成日: 2026-07-31
> 関連: FEAT-489 Phase 2 (v1.1 英語圏 launch 向け i18n / ARB 化)
> 真実値: `doc/instructions/FEAT-489_phase_2_develop_handoff.md` §3.1

---

## 1. ARB ファイル構成

| ファイル | 用途 |
|---|---|
| `app_ja.arb` | 日本語 master (真実値)。全 key はここが起点。`@key` description 必須。 |
| `app_en.arb` | 英語版。Phase 2A/2B/2C では "TODO" プレースホルダー or 日本語コピー。Phase 2D で LLM 一次翻訳 + Phase 3 native reviewer review。 |
| `app_localizations*.dart` | **生成物。git 追跡しない** (下記 1.1)。 |

### 1.1 生成物を git 追跡しない理由 (2026-08-02 決定)

`l10n.yaml` が `synthetic-package: false` + `output-dir: lib/l10n` なので、
生成物 `app_localizations.dart` / `app_localizations_ja.dart` /
`app_localizations_en.dart` が **ソースツリーに出る**。これは構成上の必然で、
追跡するかどうかは trade-off だった。

**追跡しない**と決めた。理由:

- ARB を 1 key 直すと **3 ファイル数十行の diff** になり、コードレビューの
  信号対雑音比が落ちる。実測で、i18n 作業時の `mobile/lib` の diff 34,456 行
  のうち **18,493 行 (54%) が生成物**だった。
- Phase 2F で native reviewer から **1,438 key** が返ってくる。人が読むべき
  ARB の差分が、生成物 18,000 行に埋もれるのは最悪のタイミングである。

安全性は実測で確認済み:

- 3 ファイルを削除 → `flutter pub get` → **byte 一致で再生成** (`git diff` が空)
- CI (`.github/workflows/ci.yml`) は `flutter analyze` / `flutter test` の前に
  `flutter pub get` を実行しているので、追跡をやめても CI は通る

**真実値は `app_ja.arb` / `app_en.arb`**。生成物を手で編集しないこと
(次の `pub get` で消える)。

---

## 2. Key 命名規約

### 2.1 フォーマット

```
<feature>_<page_or_widget>_<element>_<state>
```

| セグメント | 内容 | 例 |
|---|---|---|
| `<feature>` | feature ディレクトリ名 (lowercase) | `habits`, `battle`, `gamification`, `guild`, `sabi` |
| `<page_or_widget>` | 画面名 or widget 名 (snake_case) | `home`, `add_page`, `guild_page`, `battle_widget` |
| `<element>` | UI 要素種類 | `title`, `label`, `hint`, `button`, `error`, `message`, `tooltip` |
| `<state>` | (optional) 状態別 | `empty`, `loading`, `success`, `error`, `locked` |

### 2.2 特殊 suffix ルール

| suffix | 意味 | 例 |
|---|---|---|
| `_sabi_message` | サビのセリフ・メッセージ | `battle_result_win_sabi_message` |
| `_lilia` | リリア（ギルド受付 NPC）のセリフ | `guild_lilia_default_1` |
| `_snackbar` | SnackBar に表示されるメッセージ | `habits_home_add_success_snackbar` |
| `_dialog_title` | ダイアログのタイトル | `habits_delete_confirm_dialog_title` |
| `_tooltip` | ツールチップ | `guild_enemy_physical_resistance_tooltip` |

### 2.3 Sabi / Lilia line の `@key.description` 記載必須事項

```json
"battle_result_win_sabi_message": "お見事です。今日の一歩、確かなものでしたよ 🪶",
"@battle_result_win_sabi_message": {
  "description": "Sabi message on battle win result screen (see doc/design/i18n_persona_en.md §1.5 Scene A)"
}
```

Sabi/Lilia line の `description` には必ず `doc/design/i18n_persona_en.md §X.X` への参照を付ける。

### 2.4 Lilia セリフ の key 設計

リリアのセリフは `_kDialogue` 定数（`receptionist_service.dart`）から ARB key に変換済み。
`guild_lilia_<state>_<variant_num>` 形式 (1-indexed)。

| State | Key パターン |
|---|---|
| defaultGreeting | `guild_lilia_default_1` 〜 `guild_lilia_default_5` |
| firstLogin | `guild_lilia_first_login_1` |
| levelUp | `guild_lilia_level_up_1` 〜 `guild_lilia_level_up_2` (ICU placeholder: `{level}`) |
| restDay | `guild_lilia_rest_day_1` |
| consecutiveBattles | `guild_lilia_consecutive_battles_1` |
| bossUnlocked | `guild_lilia_boss_unlocked_1` |
| victoryJustNow | `guild_lilia_victory_1` 〜 `guild_lilia_victory_3` |
| defeatJustNow | `guild_lilia_defeat_1` |

---

## 3. ICU MessageFormat (動的プレースホルダー)

変数を含むリテラルは ICU MessageFormat で記述する。

```json
{
  "guildEnemyUnlockLevelLabel": "Lv.{level} で解禁されます",
  "@guildEnemyUnlockLevelLabel": {
    "description": "Guild enemy list: locked enemy unlock level hint",
    "placeholders": {
      "level": { "type": "int", "example": "15" }
    }
  }
}
```

Dart 呼び出し:
```dart
Text(l10n.guildEnemyUnlockLevelLabel(enemy.unlockLevel))
```

> **注意**: `flutter gen-l10n` は camelCase の Dart getter / メソッドを自動生成する。
> ARB key の snake_case が camelCase に変換される（例: `habits_home_add_button_label` → `habitsHomeAddButtonLabel`）。

---

## 4. よくある変換パターン

### 4.1 単純な Text

```dart
// Before
Text('追加')

// After
Text(AppLocalizations.of(context)!.habitsHomeAddButtonLabel)
// または
Text(l10n.habitsHomeAddButtonLabel)
```

### 4.2 文字列補間

```dart
// Before
Text('Lv.$level で解禁されます')

// After (ARB key に placeholder 定義必須)
Text(l10n.guildEnemyUnlockLevelLabel(level))
```

### 4.3 SnackBar / error メッセージ

```dart
// Before
ScaffoldMessenger.of(context).showSnackBar(
  SnackBar(content: Text('保存しました 🪶'))
);

// After
final l10n = AppLocalizations.of(context)!;
ScaffoldMessenger.of(context).showSnackBar(
  SnackBar(content: Text(l10n.commonSaveSuccessSnackbar))
);
```

### 4.4 AppBar title

```dart
// Before
AppBar(title: const Text('ギルド'))

// After
AppBar(title: Text(l10n.guildPageTitle))
```

### 4.5 Dialog title

```dart
// Before
showDialog(builder: (ctx) => AlertDialog(title: const Text('確認')))

// After
showDialog(builder: (ctx) => AlertDialog(title: Text(AppLocalizations.of(ctx)!.commonConfirmDialogTitle)))
```

---

## 5. context なし層でのパターン

サービス / 定数ファイルでは `AppLocalizations.of(context)` が使えない。

| 状況 | 対応方針 |
|---|---|
| リリア dialogue pool (`receptionist_service.dart`) | ARB key 文字列 (`'guild_lilia_default_1'` 等) を返す。widget 層で `AppLocalizations` を使って解決 |
| サビ todo メッセージ (`sabi_todo_messages.dart`) | 関数 `sabiTodoDoneMessages(l10n)` に変換し、`AppLocalizations` を受け取る |
| `static const String` fallback | `static String fallback(BuildContext ctx)` メソッド or build 時に `l10n.<key>` を直接使う |

---

## 6. `@key` description の書き方

```json
"habitsHomeAddButtonLabel": "追加",
"@habitsHomeAddButtonLabel": {
  "description": "Habits home FAB label (habits/pages/home_body.dart:245)"
}
```

- `description` に `file:line` を記録しておくと Phase 3 reviewer が検索しやすい
- Sabi/Lilia line は必ず `doc/design/i18n_persona_en.md §X.X` への参照を追加

---

## 7. flutter gen-l10n 実行方法

```bash
cd mobile
flutter gen-l10n
```

実行後 `lib/l10n/app_localizations.dart` + `app_localizations_ja.dart` + `app_localizations_en.dart` が自動更新される。

---

## 8. lint check

```bash
flutter analyze lib/features/{sabi,guild,battle,gamification,habits}/
```

新規 issue 追加がないことを各 feature 完了時に確認する。
