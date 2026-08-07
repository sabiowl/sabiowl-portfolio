# FEAT-489 Phase 3 — native English reviewer 発注パッケージ

> 作成日: 2026-08-02
> 起票元: PM (実装) — [i18n_persona_en.md](i18n_persona_en.md) Part 7.1「Share with 1-2 candidates」の実行資料
> **期限: 2026-08 中に発注完了** (外部 lead time があるため、9 月にずれ込むと 10 月 launch が不成立)
> 関連: [persona guide](i18n_persona_en.md) / [FEAT-489 Phase 2 handoff](../instructions/FEAT-489_phase_2_develop_handoff.md) §7

---

## §1. なぜ「発注」が critical path なのか

Phase 2A-2E で `app_en.arb` の 1,380 key はすべて埋まっている (LLM 一次翻訳)。
つまり **英語は「動く」状態にはある**。しかし Sabi は

> 「励ます存在」ではなく、ユーザーにとっての **「自分を肯定してくれる静かな聖域」**

という、英語圏の habit app の定型 (Duolingo / Habitica 的な高テンション) と
**正反対のトーン**を差別化の核にしている。ここが機械翻訳臭のまま launch すると、
「Finch の劣化版」と認知されて回復が効かない (FEAT-489 Pre-mortem の最重要項目)。

コードは内製でいくらでも直せるが、**native の語感だけは外部からしか調達できない**。
だから発注が最も外部依存の強い critical path になる。

---

## §2. レビュー対象の実測規模 (2026-08-02 時点)

`python scripts/arb_review_export.py export` の出力:

| Tier | 内容 | 行数 | 語数 | 優先度 |
|---|---|---:|---:|---|
| **tier1_persona** | Sabi 台詞 285 + Lilia 台詞 16 | **301** | **3,144** | 🔴 必須 |
| **tier1b_master** | **Backend master data (下記 §2.2)** | **293** | **~2,500** | 🔴 **必須 (check のみ)** |
| tier2_system | ボタン / ラベル / エラー等の chrome | 1,079 | 3,783 | 🟡 任意 |
| **合計** | | **1,673** | **9,427** | |

### 2.2 tier1b — Backend master data (2026-08-03 追加)

**当初この範囲は in にも out にも書かれていなかった**。ARB (Flutter 側) だけを
発注範囲とみなしていたため、**Backend DB 側の日本語が丸ごと漏れていた**。
API エラー文言と同じ形の抜けである (FEAT-515 §0 参照)。

| model | 件数 | 語数相当 | 内容 |
|---|---:|---:|---|
| **SabiMessage** | 95 | **1,513** | **ホーム画面のサビの台詞**。ARB の Sabi 台詞と同格 |
| Character | 42 | 475 | 名前 / 肩書 / 人物説明 |
| TaskSuggestion | 132 | 462 | タスク登録候補のラベル |
| Enemy | 24 | 56 | 敵名 |
| **計** | **293** | **~2,506** | |

#### 発注方法は「執筆」ではなく「チェック」(ユーザー判断 2026-08-03)

tier1b は **LLM 一次翻訳を投入済** (`doc/i18n/master_data_en.json`)。
reviewer には**ゼロから書いてもらうのではなく、既訳を読んで直してもらう**。

- 語数の割に単価を抑えられる (執筆 $0.04-0.08/word に対し、check は概ね半額)
- **$180 の確定予算を超えずに済む** (§3.1 の判断を維持できる)
- Enemy 名や TaskSuggestion のラベルは定型で、LLM 訳の精度で実用上足りる。
  人の目が要るのは **SabiMessage 95 件 (1,513 語) の語感**である

**reviewer への指示**: tier1b は「語感が Sabi らしいか」だけを見てほしい。
定型ラベル (Enemy / TaskSuggestion) は明らかな誤りだけ直せばよく、
好みで言い換える必要はない、と明記すること。

**推奨**: **tier1 + App Store 文言**を発注する (tier2 は見送り)。

- tier1 = プロダクトの人格そのもの。ここの語感が launch の成否を決める
- tier2 = "Save" / "Cancel" 級の定型。LLM 一次翻訳の精度で実用上足りる。
  α英語話者テスト (Phase 6) で違和感が出た箇所だけ後追いで直す方が費用対効果が高い

### 2.1 App Store 文言を tier1 に同梱する (2026-08-02 追加)

[app_store_en.md](app_store_en.md) のストア文言 **約 350 語**を tier1 に含める。

- ストア文言は **英語ユーザーが最初に読む英語**。ここが機械翻訳臭いと
  **インストール前に離脱**する。アプリ内の語感より露出が早い
- 語数比で +11% にすぎず、$150 の発注枠に収まる
- 同じライターが見ることで **ストアとアプリ内のトーンが一致**する
  (別発注だとストアだけ煽り気味になりやすい)

**渡す際の注意**: ストア文言は**アプリ内より一段だけ外向き**でよいと明記する。
サビの直接台詞ではないので `. 🪶` は不要 (そもそも App Store のフォームは
絵文字で保存エラーになるため使えない)。ただし「煽らない」「休息を肯定する」という
**主張の中身は変えさせない**こと。

---

## §3. 費用の目安と予算判断

英語ネイティブの copy editing 相場は **$0.04-0.08/word**、または **$30-60/時**。

| 発注範囲 | 語数 | 目安 | 備考 |
|---|---:|---|---|
| tier1 のみ (推奨) | 3,144 | **$130-250** | ~¥20,000-38,000 |
| tier1 + tier2 | 6,927 | $280-550 | tier2 は定型が多く単価を下げやすい |
| screening test (§5) | ~60 | $10-20 | 候補 2 名分でも $40 以内 |

### 3.1 確定した予算 (2026-08-02、ユーザー判断)

| 費目 | 上限 |
|---|---|
| スクリーニング (5 行 × 候補 2 名) | **$30** |
| tier1 本発注 (301 行 / 3,144 語) | **$150** |
| **合計上限** | **$180** (≈ ¥27,000、¥150/$ 換算) |

> **【2026-08-03 更新】tier1b (master data 293 行 / ~2,500 語) を追加したが、
> 上限 $180 は据え置く**。tier1b は **既訳のチェック**であって執筆ではないため
> (§2.2)。発注時は「tier1 = 執筆レベルの推敲 / tier1b = 既訳の check」と
> 作業量の違いを明示し、合計 $150 の枠内で見積もりを取ること。
>
> 枠に収まらない場合の削り順: ① Enemy 24 (定型) → ② TaskSuggestion 132 (定型)
> → ③ Character 42。**SabiMessage 95 は最後まで残す** —— ここがサビの声そのもの。

**この額にした理由**:

1. 語数の割に**判断の比重が高い**作業 (3,144 語 = 英語なら実質半日〜1 日)。
   時給換算 $30-50 に収まる水準であり、$250 まで出しても品質は比例しない
2. **月 3 万円のラインを超えない**。FEAT-489 handoff §3.3 が触れる SEC-11 の
   ガードレールは文面上 LLM の recurring cost が対象で、同 § は「1 回きりの
   発生 cost」は整合すると明記しているが、上限側 ($250 ≈ ¥38,000) は
   ラインに接触する。$180 に置けばこの論点自体が消える
3. **9 月の反復 1-2 回分の余地を残せる**。微修正を頼む段階で予算が尽きているのが最悪

> ¥150/$ は換算の仮定。実レートで再計算すること。

---

## §4. 求人文面 (そのまま貼れる英語)

> **投稿先: Upwork (2026-08-02 決定)**。理由は §4.1。
> **意図的に「もっと明るくしたい」系の応募を弾く書き方**にしてあります (persona guide Part 6 P1 対策)。

### 4.1 なぜ Upwork か

| | 向き | この案件での懸念 |
|---|---|---|
| **Upwork** ◎ | 提案文と職歴で**判断力**を測れる。有償テストを契約として切りやすい | 採用まで数日かかる |
| Fiverr △ | 早い・安い・定額 | gig 出品者は**回転率**で最適化しており、「定型に寄せる」圧力が構造的に強い |
| 知人 △ | 文脈理解と信頼は最高 | **押し返してくれない**リスク。納期も強く言えない |

決め手は、この案件が求めるものが **校正ではなく判断**だという点。Sabi は「!」を使わず
停滞を肯定する、英語圏 habit app の定型と正反対のトーンを差別化にしている。
Fiverr の proofreading gig は「標準的で読みやすい英語にする」ことに最適化されているため、
**最も守りたい部分を善意で壊してくる** (Part 6 P1 そのもの)。

知人が候補から外れるのは「**押し返してくれない**」から。§5 では「理由付きで逆提案してくる」
ことを採用サインにしているが、友人関係では遠慮して同意しがちで、それでは native を雇う意味が薄い。

**代替候補**: JA→EN の翻訳者 (ProZ / ATA ディレクトリ)。CSV に日本語原文の列があるので、
原文と突き合わせて「日本語の含みが英語で落ちている」箇所を拾える。単価は上がるが tier1 のみなら現実的。
Upwork で良い候補が集まらなかった場合の次善策とする。

```
Title: Native English copy editor for a calm, literary mobile app voice (301 lines)

We're launching the English version of Sabiowl, a habit-tracking app with an RPG layer.
Our mascot "Sabi" is an owl in his 30s-40s: gentle, intelligent, understated. He is
NOT a cheerleader. The app's core promise is that it feels like a quiet sanctuary —
it affirms rest and plateaus rather than pushing the user to do more.

We have a complete first-pass English translation (machine-assisted) and a written
persona guide. We need a native English speaker to edit it so the voice reads as
though it was written in English from the start.

Scope: 301 in-app lines / ~3,100 words, delivered as a spreadsheet (one row per
line, with Japanese source, English draft, and an editable column), plus our
App Store listing text (~350 words) in a separate document.

What matters most:
- Sabi's lines contain no exclamation marks. His warmth comes from restraint.
- A second character, Lilia (a guild receptionist in her early 20s), is the
  deliberate contrast: bright and energetic. Both voices must stay distinct.
- We keep a small set of emoji as brand signatures. They are not decoration
  and should not be removed.
- Some placeholders like {count} and {level} must be preserved exactly.

What we are NOT looking for:
- Rewrites toward standard motivational-app copy ("You've got this!", "Crush your
  goals!"). We will reject these. The low-key register is the product.

Deliverables: the edited spreadsheet, plus brief notes on any line where you think
our guide leads us wrong. We want your judgment, not just compliance.

Before the full job we'd like to pay for a short 5-line sample (~$15) to check fit.

Budget: $15 for the paid sample, $150 fixed price for the full 301-line pass.
Timeline: sample within 3 days, full pass within 2 weeks of start.
```

### 4.2 Upwork での投稿手順

1. **Job type**: Fixed price (時給契約にしない — 語数が確定しているため見積もりが立つ)
2. **Category**: Writing → Editing & Proofreading
3. **Skills tag**: `Copy Editing` / `Creative Writing` / `Brand Voice`
   (`Translation` は付けない — JA→EN 翻訳者を狙うのは §4.1 の次善策の時だけ)
4. **Screening question** (Upwork の応募フォームに 1 問だけ設定する):

   > Our mascot never uses exclamation marks, and one of his lines tells the user
   > that doing nothing today is enough. In one or two sentences: why might that be
   > a deliberate product decision rather than a translation error?

   **この 1 問で応募の大半を選別できる**。「トーンを明るくすべき」と答えてくる候補は
   その時点で見送ってよい (Part 6 P1)。
5. 応募から **2 名**を選び、§5 の有償サンプルを各 $15 で発注

---

## §5. 候補者スクリーニング (有償サンプル 5 行)

いきなり全量を任せず、**$10-20 の有償サンプル**で適性を見る。
候補 2 名に同じ 5 行を出し、比較して選ぶのが最も確実。

出題ファイルはコマンドで生成する (**実在の key を使う**ので、良い納品はそのまま採用できる):

```powershell
python scripts/arb_review_export.py sample
# → doc/design/review_export/screening_sample.csv (5 行 / 74 語)
```

5 行はそれぞれ **別の失敗モード**を試す:

| # | key | 何を見るか |
|---|---|---|
| 1 | `sabiTodoCarryover2Sabi_message` | **停滞の肯定** (最重要)。「持ち越し」を責めず、諦めや同情にも落とさず訳せるか |
| 2 | `sabiTodoDone1Sabi_message` | 称賛に振らず、事実の承認に留められるか (CLAUDE.md の模範台詞そのもの) |
| 3 | `gamifJobMasteryMaxedBodySabi_message` | 「地層」の比喩を自然な像に置けるか + 複数行 + **`{jobName}` placeholder の保持** |
| 4 | `guildLiliaDefault1` | Lilia の明朗さを、幼稚さや formal な接客マニュアル調にせず出せるか (P5) |
| 5 | `gamifAchievementPageErrorSabi_message` | エラー文でユーザーを責めないか |

> #3 に placeholder が含まれるので、**指示を読まずに `{jobName}` を訳してしまう候補**も
> ここで検出できる (本発注で同じことをやられると全 key の確認が必要になる)。

### 合否の判定基準

**不採用にすべきサイン** (persona guide Part 6 の P1-P6 に対応):

- ❌ Sabi の行に `!` を足してくる (P1)
- ❌ "You've got this" / "Keep going" / "champion" / "journey" を入れてくる (P1、§1.4 の禁止語)
- ❌ 🪶 や 🗡️ を「不要」として削ってくる (P6)
- ❌ #1 を "Don't worry about it" 系の軽い慰めにしてしまう (休息の肯定 → 諦めへの劣化)
- ❌ Lilia を "sir/madam" の formal customer-service 調にする (P5)

**採用したいサイン**:

- ✅ #1 で、休むことが**それ自体で正当**だと読める英語になっている
- ✅ #3 の比喩を直訳せず、英語として自然な像に置き換えている
- ✅ 「ここは日本語の含みが英語だと出ないので、こう変えたい」と**理由付きで逆提案**してくる

> **重要**: 逆提案は歓迎してください。persona guide は PM が書いた仮説であって、
> native の語感の方が正しい場面は必ずあります。ただし **P1 (トーンを明るくしたい)
> だけは押し返す**。ここはプロダクトの差別化そのものなので、説得できない候補は見送りです。

---

## §6. 受け渡しワークフロー (JSON をライターに触らせない)

### ⚠️ 6.0 送付タイミング — **Phase 2F-a の完了後に再生成すること**

FEAT-489 **Phase 2F-a** (ICU plural 化 32 key + 残リテラル ~122 件の回収) が
英語ドラフトを書き換える。**2F-a 完了前に書き出した CSV を送ってはいけない**:

- ライターが**古い原稿**を編集することになる
- 取り込み時に 2F-a の成果を**上書きして巻き戻す**か、衝突する

**順序**:

1. Phase 2F-a 完了 + commit
2. `python scripts/arb_review_export.py export` で **再生成**
3. ライターへ送付

**スクリーニング用の 5 行 (§5) は例外**で、先に送ってよい。
対象 key はいずれも plural を含まない固定文なので 2F-a の影響を受けない
(`screening_sample.csv` を送る直前に `sample` を再実行すれば確実)。
**候補者選定を 2F-a の完了待ちで止める必要はない。**

ARB は 1,380 key の JSON で、非エンジニアが直接編集すると壊れます。
`scripts/arb_review_export.py` で CSV を介します。

```powershell
# 1. 発注前: レビュー用 CSV を書き出す (doc/design/review_export/ に出力)
python scripts/arb_review_export.py export

# 2. tier1_persona.csv をライターに送る (Google Sheets 共有が確実)

# 3. 納品後: まず dry-run で差分と placeholder エラーを確認
python scripts/arb_review_export.py import <納品された.csv> --dry-run

# 4. 問題なければ本適用 → コード生成
python scripts/arb_review_export.py import <納品された.csv>
cd mobile; flutter gen-l10n; flutter test
```

CSV の列は `key` / `tier` / `context` / `japanese` / `english_draft` /
**`english_final` (ここだけ編集)** / `notes` / `placeholders`。

**import 側の安全装置** (すべて意図的に壊す negative test で動作確認済):

- `{count}` 等の **placeholder の増減** → 中止 (例: `{count}` を `{kaisuu}` と訳してしまう)
- **ICU 構造の消失** → 中止 (`{count, plural, =1{...} other{...}}` の `plural,` ごと消す)
- **波括弧の不均衡** → 中止 (閉じ忘れ)
- 未知の key → 中止
- 前後の空白を保持する (`" {count} coins"` のような連結用の空白を壊さない)

エラーが 1 件でもあれば **arb を一切書き換えずに exit=1** で止まる。
ICU 複数形は Phase 2F-a で 32 key に入るため、非エンジニアが編集する前提では
このガードがないと `flutter gen-l10n` がビルド時に落ちる。

---

## §7. ライターに送るもの / 送らないもの

| | 内容 |
|---|---|
| ✅ 送る | `tier1_persona.csv` |
| ✅ 送る | [i18n_persona_en.md](i18n_persona_en.md) の **Part 1 / Part 2 / Part 5** (Sabi 人格 / Lilia 人格 / チェックリスト) |
| ⚠️ 任意 | Part 6 (P1-P6)。「こう押し返します」と先に伝えると健全な候補は逆に安心する |
| ❌ 送らない | Part 4 (社内向けの日本語メモ) |
| ❌ 送らない | リポジトリ本体 / ARB の生 JSON / CLAUDE.md |

**briefing の順序が重要**: persona guide Part 1-2 を**読んでもらってから**行に触れてもらう
(Part 6 P1 の緩和策そのもの)。CSV を先に渡すと、文脈なしで定型に寄せた編集が返ってきます。

---

## §8. 10 月 launch から逆算した日程

| 時期 | やること | 遅延時の影響 |
|---|---|---|
| **8 月上旬** | 候補 2 名に打診 + 有償サンプル発注 | — |
| **8 月中旬** | サンプル比較 → 1 名決定 → Part 1/2/5 で briefing → 本発注 | ここを逃すと以降が全部ずれる |
| 8 月下旬 - 9 月上旬 | ライター作業 (2 週間) | |
| 9 月上旬 | 納品 → `--dry-run` 確認 → 反映 → Phase 2F へ統合 | |
| 9 月中旬 | 1-2 回の反復 (質問対応 / 微修正) | |
| 9 月下旬 | Phase 6 α英語話者テスト 3+ 人 | |
| 10 月 | launch | |

**バッファは 9 月中旬の反復 1 回分しかありません。** サンプル依頼を 8 月上旬に出せるかが最大の分岐です。

---

## §9. 実行チェックリスト

**決定済み (2026-08-02)**:

- [x] 予算上限: **$180** (サンプル $30 + 本発注 $150) — §3.1
- [x] 探索先: **Upwork** (次善策は ProZ の JA→EN 翻訳者) — §4.1
- [x] 求人文面の Budget 記入済 — §4
- [x] スクリーニング用シート生成: `python scripts/arb_review_export.py sample` — §5

**ユーザー作業 (8 月上旬)**:

- [ ] Upwork に §4 の求人文面を投稿 (Fixed price / Editing & Proofreading / §4.2 の選考質問 1 問付き)
- [ ] 応募から 2 名を選び、`screening_sample.csv` を各 $15 で発注
- [ ] 2 名の納品を §5 の合否基準で比較 → 1 名決定

**8 月中旬 (決定後)**:

- [ ] **Phase 2F-a の完了を確認**してから `export` を再実行 (§6.0、これを飛ばすと巻き戻る)
- [ ] persona guide の **Part 1 / 2 / 5** を送付し、**読了後に** `tier1_persona.csv` を渡す (§7)
- [ ] あわせて [app_store_en.md](app_store_en.md) §2 のストア文言も渡す (§2.1、+約 350 語)
- [ ] 本発注 ($150 fixed price、2 週間)

**9 月上旬 (納品後)**:

- [ ] `python scripts/arb_review_export.py import <納品>.csv --dry-run` で placeholder 検証
- [ ] 問題なければ本適用 → `flutter gen-l10n` → `flutter test`
- [ ] FEAT-489 **Phase 2F-b** として Develop に反映を依頼
