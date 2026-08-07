# ホーム画面 popup / オーバーレイ優先度マトリクス

> 作成日: 2026-06-22
> 起点: `doc/ux_review/20260622_ux_review.md` §3 P1-1 (ホーム画面のポップアップ/プロンプト集積頻度が実機未検証)
> 真実値: 本ファイル (現状コードのスナップショット) + [home_page.dart](../../mobile/lib/features/habits/pages/home_page.dart)
> 更新タイミング: 新規 popup 系統を追加 / 既存系統を変更したら本ファイルも追従更新する

---

## 0. 目的

ホーム画面 (`HomePage`) には現時点で **11 系統の popup / オーバーレイ** が定義されている。個々の listener は `listener-only widget pattern` または `ref.listen` で実装されており品質は高いが、**「複数条件が同時に成立した日にどう振る舞うか」** がコードから読み取りにくい状態にある。

本ドキュメントは:

1. 11 系統すべての発火条件・抑制条件・遷移先を 1 つの表で可視化する
2. 同時発火時の表示順序ルールを明文化する
3. 実機検証用のシナリオチェックリストを提供する

を目的とする。実装変更ではなく **記録 + 検証** のためのドキュメント (P1-1 は code-change なし、検証タスクとして整理)。

---

## 1. 全 popup / オーバーレイ系統一覧 (11 件)

`HomePage.build()` と `initState` 内で発火する listener / dialog / sheet / SnackBar / overlay を網羅。

| # | 系統名 | 種別 | トリガー | 発火条件 (抑制ロジック含む) | 即時 / 遅延 | 自動消滅 | 関連 FEAT/BUG |
|:---:|---|---|---|---|---|---|---|
| **1** | **LoginBonusCalendarDialog** | `showDialog` (barrierDismissible=true) | `pendingLoginBonusProvider` listen | Backend response `today_login_bonus` が non-null (= 当日初回タスク達成検知)、`last_login_diamond_at != today` (Backend 側で当日 1 度のみ) | 遅延 (postFrame) | User dismiss | BUG-122/126/130/137 |
| **2** | **LevelUpDialog** | `showDialog` (await) | `levelUpNotifierProvider` listen | Backend response `new_level` 検知時。`null` クリア with `addPostFrameCallback` | 遅延 (postFrame) | User dismiss (戻り値 wantStats: bool) | FEAT-453, BUG-65 |
| **3** | **Stats Page push** | `context.push(/stats)` | LevelUpDialog の戻り値 wantStats==true | LevelUpDialog で「ステータスについて」タップ | LevelUpDialog 閉鎖 + 300ms 後 | (画面遷移) | BUG-65 (transitionDuration race) |
| **4** | **BackupPromptSheet** | `showModalBottomSheet` | LevelUpDialog 閉鎖後 | `newLevel ∈ {5, 10, 20, 30}` + ゲストモード + `shouldShowBackupPromptSheet(newLevel)` (= 同 Lv 未表示) | LevelUpDialog 閉鎖 + 300ms 後 | User dismiss | FEAT-399 |
| **5** | **Reward Toast + 光ビーム** | `OverlayEntry` (`_showRewardToast` + `_triggerLightBeamEffect`) | `rewardToastProvider` listen | 習慣達成 / ToDo 完了でリワード発生時 | 遅延 (postFrame) | 自動 (Toast 内タイマー) | FEAT-204, FEAT-453 |
| **6** | **Comeback SnackBar** | `ScaffoldMessenger.showSnackBar` | `comebackNotifierProvider` listen | 休息日に習慣達成 (rest_day=true + 習慣達成) | 遅延 (postFrame) | 自動 (4 秒) | FEAT-265 |
| **7** | **NotificationSoftPromptSheet** | `showModalBottomSheet` | initState postFrame + Reward Toast 内 (初回 ToDo 完了経路) | `firstTodoDone == true` + `!_notifPromptChecked` + システム通知未確定/拒否 | initState: 直接 / Reward Toast 経由: 200ms 後 | User dismiss | FEAT-284 |
| **8** | **LiliaFloatingPanel** | `Overlay.of(rootOverlay: true)` | `battleSessionProvider` listen (`lastVictoryAt`) | バトル勝利後 5 秒以内 + `_lastShownVictoryAt != victoryAt` (二重発火ガード) | 遅延 (postFrame) | 自動 (3 秒スライド + フェード) | FEAT-315, FEAT-323 |
| **9** | **AnnouncementPopupListener (popup)** | `showDialog` (barrierDismissible=false) | `unreadAnnouncementProvider` watch | Backend `/announcements/unread/` が non-null + `_showing == false` | 即時 (provider 解決時) | User dismiss (「確認した」or「閉じる」) | FEAT-458, FEAT-460 |
| **10** | **FriendGiftPopupListener (popup)** | `showDialog` | `friendGiftCandidateProvider` listen | Backend response `friend_gift_candidate` non-null (当日 3 タスク達成 + 7 日以内ログインフレンドあり + daily 未消費 + 同日重複なし) | 遅延 (listener: postFrame なし、即時) | User dismiss (「贈る」「やめる」) | FEAT-451, FEAT-452 |
| **11** | **FEAT-426 Migration Notice** | `showDialog` | initState postFrame | Google カレンダー連携あり + 既存ユーザー判定 + 未表示 | initState postFrame | User dismiss | FEAT-426 |

---

## 2. 発火経路の分類

| 起動経路 | 該当系統 | 順序 |
|---|---|---|
| **A. initState postFrame (起動シーケンス、決定論的順序)** | #7 通知ソフトプロンプト → #11 FEAT-426 移行案内 | 直列、await チェーン |
| **B. ref.listen (build 内、Riverpod state 変化駆動)** | #1 LoginBonus / #2 LevelUp / #6 Comeback / #5 Reward Toast / #8 LiliaPanel | build() 内の `ref.listen` 登録順序: pendingLoginBonus → levelUp → comeback → rewardToast → battleVictory |
| **C. ref.watch (Stack 子 widget 内)** | #9 Announcement / #10 FriendGift | 親 widget rebuild 時に自動評価、provider 解決順序に依存 |
| **D. 連鎖 (Dialog の戻り値経由)** | #3 StatsPage push / #4 BackupSheet (#2 から派生) | LevelUpDialog dismiss 後 300ms |

---

## 3. 想定される同時発火シナリオと挙動

### シナリオ S1: 「久しぶりの起動 + 初回タスク達成」

ユーザー操作: 数日ぶりに起動 → 初回タスク達成。

Backend は以下を同一 response で返す可能性:
- `today_login_bonus` (BUG-122 経路)
- `streak_protection_pending` (FEAT-420)
- `friend_gift_candidate` (FEAT-452、当日 3 タスク達成判定が同一 request で trigger)
- `level_up` (継続ボーナス積算)
- `monthly_ticket_awarded` (FEAT-433、21 日達成)

加えて initState 完了タイミングで:
- `unreadAnnouncementProvider` 解決 (#9)

**現状の挙動 (コードから推定)**:
- `pendingLoginBonusProvider` の listen → addPostFrameCallback で LoginBonusDialog 起動
- 同フレームで `levelUpNotifierProvider` listen も発火 → 別 postFrame callback で LevelUpDialog 積み上げ
- Flutter の Navigator は LIFO のため、**後に push されたものが上に表示** される
- showDialog は modal なので、上層 dismiss 後に下層が表示される (キューイング動作)

**ユーザーから見える順序**:
LoginBonus 表示 → User dismiss → LevelUp 表示 → User dismiss → (wantStats なら StatsPage、else BackupSheet)
+ 並行で SnackBar (Comeback、Reward Toast) は自動消滅型なので上に被さる

**懸念**: LoginBonus と LevelUp が同時 push されると 1 フレーム内で 2 つの modal route が積まれる。中身は正しいが、**ユーザーは「タスク達成したら 5 連続でポップアップが出てくる」状態を体験する可能性**。

### シナリオ S2: 「バトル勝利 → ホーム遷移」

ユーザー操作: バトル勝利モーダル閉じる → `context.go(/home)` → ホーム遷移。

5 秒以内に発火する可能性:
- #8 LiliaFloatingPanel (バトル勝利祝福、3 秒自動消滅)
- #5 Reward Toast (バトル勝利報酬経路、Reward Toast は WorldFrameSection 経由)
- #9 AnnouncementPopupListener (provider 解決済なら同時表示)

**現状の挙動**:
- LiliaPanel は `clearSnackBars()` を呼んでから show (FEAT-323、サビ・リリア構造的分離保証)
- ただし AnnouncementPopupListener は `showDialog` modal なので、Lilia の Overlay と layer は独立 (両方表示される可能性あり)

**懸念**: 勝利直後にお知らせ popup が被さると、リリアの祝福を見逃す可能性。

### シナリオ S3: 「ゲストユーザーが Lv 5 到達」

ユーザー操作: タスク達成で Lv 4 → 5 に上昇。

連鎖:
- #2 LevelUpDialog 表示 → User dismiss
- #4 BackupPromptSheet 表示 (Lv 5 マイルストーン + ゲスト)
- (Backend response 次第で) #10 FriendGift popup も candidate あり
- (announcement 未読あり) #9 Announcement popup も発火可能

**現状の挙動**:
- BackupPromptSheet は LevelUpDialog dismiss + 300ms 後の sheet なので **連続表示**
- FriendGift と Announcement は listen / watch なので同フレーム内で複数 showDialog 起動の可能性
- 結果として **最大 4 つの modal が直列に並ぶ** (User dismiss × 4 回必要)

---

## 4. 推奨ルール案 (実機検証で確認した上で、別 FEAT で実装検討)

> 本ドキュメントは現状記録 + 検証目的のため、以下はあくまで「実機検証で問題が確認できたら起票検討」のメモ。

### 案 A. 優先度ティア分けで同フレーム抑制

| Tier | 表示優先度 | 系統 | 同時成立時の挙動 |
|:---:|---|---|---|
| **T1 (最優先)** | 「達成・勝利」演出 (即時、自動消滅) | #5 Reward Toast / #6 Comeback SnackBar / #8 LiliaPanel | 必ず表示、自動消滅型なので他と被っても OK |
| **T2 (高)** | 「報酬通知」(modal、ユーザー操作必要) | #1 LoginBonus / #2 LevelUp / #4 BackupSheet | T2 同士は表示順序を固定 (LoginBonus → LevelUp → BackupSheet) |
| **T3 (中)** | 「情報提供」(modal) | #9 Announcement / #11 FEAT-426 移行案内 | T2 が積まれている間は **延期** (T2 全 dismiss 後に表示) |
| **T4 (低)** | 「ユーザー操作誘導」(modal) | #7 NotificationSoftPrompt / #10 FriendGift | T3 と同じく T1-T3 全完了後に表示 |

### 案 B. 1 日 1 popup ルール

ホーム表示 1 セッション (アプリ起動 → BG 切替まで) で出す modal を **最大 2 つに制限**。3 つ目以降は次回起動時に持ち越し。

実装案: `last_popup_shown_at` を SharedPreferences に記録し、過去 5 分以内に表示済の系統数で抑制。

### 案 C. 動かない (現状維持)

実機検証で「気にならない」と判定された場合、コード変更しない。

---

## 5. 実機検証チェックリスト (P1-1 完了の判定基準)

### 5-1. 同時発火再現シナリオ

以下のすべてを実機 (TestFlight + Android dev build) で再現し、ユーザー体感を記録する:

- [ ] **S1 久しぶり起動 + 初回タスク達成**: 数日ぶり (連続記録切れ間際) のアカウントでログイン → 初回タスク達成 → 何個の popup が連続表示されるか数える。煩わしさを 1-5 段階で評価
- [ ] **S2 バトル勝利 → ホーム遷移**: 未読お知らせがある状態でバトル勝利 → Lilia パネルと Announcement popup が両方発火するか確認、被り具合を記録
- [ ] **S3 ゲスト Lv 5 到達**: ゲストモードで Lv 5 直前まで進めて 1 タスク達成 → LevelUp → Backup → FriendGift → Announcement の連鎖を確認、何個が並ぶか
- [ ] **S4 FEAT-426 + 初回起動**: 既存ユーザー初回起動 + 通知未確定 → FEAT-426 移行案内と通知プロンプトの順序確認
- [ ] **S5 通常タスク達成のみ**: 上記条件いずれも非該当の通常タスク達成 → Reward Toast のみ表示されることを確認 (regression check)

### 5-2. 観点別チェック

各シナリオで以下を観察:

- [ ] **被り**: 2 つ以上の modal/popup が同フレームで起動 (前のが閉じないうちに次が積まれる)
- [ ] **見逃し**: 自動消滅型 (Toast/SnackBar/Lilia) が modal の裏に隠れて視認不可能になる
- [ ] **dismiss 回数**: 1 セッションで何回 User dismiss が必要か (3 回以上で要対応)
- [ ] **順序の納得感**: 重要度の高いもの (LevelUp 等) より雑多なもの (Announcement) が先に表示されていないか
- [ ] **戻る (Android back)**: modal stack 中に Android back を押した時の挙動

### 5-3. ログ収集

- PostHog で `popup_shown` (該当系統名 + timestamp) を計測する余地
  - 実装: 各 listener / dialog 直前で `posthog.capture('popup_shown', {'system': '...'})`
  - v1.1 で導入検討 (本タスクの範疇外)

---

## 6. 既存の整合性保証 (削除しない)

以下は既にコードに埋め込まれている分離保証で、変更時に壊さないこと:

| ルール | 実装箇所 | 由来 |
|---|---|---|
| サビとリリアの構造的非共存 | `LiliaFloatingPanel.show` 直前で `clearSnackBars()` | FEAT-323 |
| 同 victoryAt の二重発火防止 | `_lastShownVictoryAt == victoryAt` ガード | FEAT-315 Pre-mortem #2 |
| dialog dispose race 防止 | `Future.delayed(300ms)` after `Navigator.pop` | BUG-65 |
| BackupPromptSheet 同 Lv 二重表示防止 | `markBackupPromptSheetShown(newLevel)` を表示前に実行 | FEAT-399 Pre-mortem #1 |
| LoginBonus 当日 1 度のみ | Backend `last_login_diamond_at` チェック | BUG-122 |
| FriendGift 当日 1 度のみ | Backend `last_friend_gift_popup_date` | FEAT-452 |
| Announcement 既読化 | PlayerAnnouncementRead unique constraint | FEAT-458 |

---

## 7. 次のアクション

1. **本ドキュメント完成 (本コミット)** — 現状把握 OK
2. **実機検証 (ユーザー側、TestFlight)** — §5 チェックリストを 1-2 セッションで実施
3. **必要なら別 FEAT 起票** — 実機で「煩わしい」と判定されたら、案 A/B/C のどれを採用するかを PM 判断 → FEAT-xxx 起票
4. **再評価サイクル** — 次回 UX レビュー (v1.0.x 後) で本ドキュメントを更新し、現状とのズレを確認

---

## 8. 関連ドキュメント

- [doc/ux_review/20260622_ux_review.md](../ux_review/20260622_ux_review.md) §3 P1-1 (本ドキュメントの起点)
- [doc/kickoff_instructions/ux_review.md](../kickoff_instructions/ux_review.md) (UX レビューセッション運用)
- [CLAUDE.md](../../CLAUDE.md) サビ・リリア口調分離、Flutter 既知の落とし穴
- [home_page.dart](../../mobile/lib/features/habits/pages/home_page.dart) (実装真実値)
