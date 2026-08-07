# Sabi & Lilia — English Persona Guide (v1.1 English Launch)

> 作成日: 2026-07-29
> **ステータス**: 🟡 起稿中 (Native speaker review 前の team draft)
> **関連**: [FEAT-489 (v1.1 英語圏 launch)](../instructions/FEAT-489_v1_1_english_localization.md) Phase 3
> **想定読者**: (1) Native English writer (fiverr 等での review 依頼、$100-300 相当、~1 週間)、(2) Flutter Phase 2 実装担当 (arb 翻訳の canonical reference)、(3) v1.1 α英語話者テスター (9 月末、3+ 人)
> **書式**: 主要部分は英語 (writer 直接 review 用)、team 向け実装ノート・翻訳戦略は日本語

---

## Purpose

This document defines the **English personas of Sabi and Lilia** for Sabiowl's v1.1 English-market launch (Oct 2026). It exists to prevent three common failure modes when translating Japanese-native characters into English:

1. **Habitica's Wise Owl trap**: generic "wise mentor" voice that any productivity app could ship → loss of brand identity
2. **Duolingo's Duo trap**: aggressive cheerleader voice that shames stagnation → violates Sabi's core philosophy
3. **Literal translation trap**: "〜ですね" mechanically becomes "isn't it?" → stilted, non-native sounding

The document is the **canonical reference** for all English strings shown to users through the Sabi/Lilia voice. When the ARB migration (Phase 2) writes `AppLocalizations.of(context)!.sabiEncourageDaily`, the English string it points to should follow the rules here.

---

## Part 1: Sabi (English)

### 1.1 Positioning

> Sabi is **not a mentor. Not a coach. Not a cheerleader.**
>
> Sabi is **a quiet sanctuary that affirms who you already are.**

The Japanese original describes Sabi as "**自分を肯定してくれる静かな聖域**" — a still place that recognizes your worth without demanding anything. In English, we frame this as a **sanctuary**, not a guide.

- ✅ A calm presence that notices what you did
- ✅ A voice that treats rest as a legitimate part of progress
- ✅ An owl-shaped constant, patient across days
- ❌ A wise elder dispensing life lessons
- ❌ A friend cheering from the sidelines
- ❌ A productivity coach optimizing your outcomes

### 1.2 Character Facts

| Attribute | Value |
|---|---|
| Species | Owl (anthropomorphic mascot, not photo-realistic) |
| Apparent age | 30s–40s in human equivalence |
| Register | Settled, thoughtful, professional but warm |
| Gender presentation | Neutral. Use no gendered pronouns for Sabi. When Sabi is referenced in third person, use "Sabi" or "they" |
| Cultural affiliation | Universal (Sabi does not signal any specific country or region) |

### 1.3 Tone Rules

| Element | Rule | Rationale |
|---|---|---|
| Punctuation | **Periods only.** No exclamation marks. Question marks allowed only for genuine offers (never rhetorical). | Confidence rendered through steadiness, not intensity |
| Sentence length | Prefer 8–14 word sentences. Break long thoughts into two calm sentences. | Reads as measured, not clipped |
| Contractions | Use them (you've, it's, that's). | Avoids stilted formality |
| Second person | "you", "your". Universal, respectful, no honorifics. | Modern English carries respect through phrasing, not markers |
| First person | Minimize. Prefer verbless or you-focused constructions. When needed, use "I". | Sabi's voice frames the reader, not itself |
| Emphasis | Never bold, never all-caps, never repeated punctuation. | Loud emphasis breaks the sanctuary tone |
| Marker | End Sabi's direct lines with `. 🪶` (period, space, feather). | Preserves the Japanese-version signature |

### 1.4 Vocabulary Palette

**Preferred verbs**: notice, add, place, rest, return, carry, hold, settle, keep, tend
**Preferred adjectives**: steady, quiet, small, patient, slow, ordinary, honest, gentle
**Preferred metaphors** (mapped from Japanese originals):

| 日本語 (原文) | English rendering | Notes |
|---|---|---|
| 地層 (chisou, strata) | "layers" | Use sparingly; "layers" is accessible, "sediment" too geological |
| 一石 (isseki, single stone) | "a single stone" | Works verbatim, evokes patience |
| 羽 (hane, feather) | "feather" | Aligns with 🪶 marker + owl identity |
| 航路 (kouro, course) | "current" | Softer than "route" |
| 白紙の地図 (hakushi-no-chizu, blank map) | "an open page" | More universal than "unwritten map" |

**Banned vocabulary** (all trigger the Wise-Owl or Duo trap):
- `awesome`, `amazing`, `great`, `crush it`, `nailed it`, `keep grinding`
- `champion`, `warrior`, `hero`, `superstar`, `rockstar`
- `journey` (overused in wellness apps to the point of parody)
- `unleash`, `unlock your potential`, `reach for the stars`
- `friend`, `buddy`, `pal`, `dear` (twee or condescending)
- Any imperative starting with "Push" or "Get" (drill-sergeant register)

### 1.5 Four Scenes with Sample Lines

Sabi speaks in four situations. Each situation has 8 lines below. Together these 32 lines are the **canonical corpus** the native reviewer should evaluate first.

#### Scene A — Quiet praise for continuation (静かな肯定)

Japanese original from CLAUDE.md:
> 「素晴らしいですね。その小さな積み重ねが、確かな地層になっていきますよ。」

English canonical corpus (8 lines):
1. Well done. Small steps like these become steady layers over time.
2. What matters most is that you faced today. That is enough. 🪶
3. Another one placed. The stones you set stay set.
4. You returned. That decision counts for more than you may realize.
5. A quiet win, but a real one. 🪶
6. This is how it happens. Slowly, and then all at once.
7. The result matters, but that you showed up is what you'll carry forward.
8. Good work today. Rest well.

#### Scene B — Affirming rest and stagnation (心理的安全性)

Japanese original from CLAUDE.md:
> 「無理に高く積もうとしなくていいんです。今日はその場所を眺めるだけでも十分ですよ。」

English canonical corpus (8 lines):
1. There's no need to reach higher today. Just looking out from where you are is enough.
2. Resting the wings is part of long flight. There is no hurry.
3. Even when nothing seems to move, something is settling. Wait a while. 🪶
4. Stopping is not the same as stepping back. Give yourself the space.
5. Not every day needs a stone. Some days are for the ground beneath them.
6. You are still here. That is the important part.
7. The pace can be as slow as you need it to be.
8. Come back when you're ready. The layers will keep.

#### Scene C — Morning and beginnings (静かな鼓舞)

Japanese original from CLAUDE.md:
> 「おはようございます。さて、今日はどんな色の一石を積み上げましょうか。」

English canonical corpus (8 lines):
1. Good morning. What color stone shall we place today, I wonder.
2. Morning. Take your time. There is no rush at the start.
3. A fresh page. Nothing on it yet, and that is fine.
4. Ready when you are. 🪶
5. Today is another chance to add one small layer. Only one, if that's what fits.
6. The morning is quiet. So can the first step be.
7. Whatever pace you choose, I'll be here.
8. Let's begin, gently.

#### Scene D — Evening and closings (心地よい締めくくり)

Japanese original from CLAUDE.md:
> 「今日もお疲れ様でした。あなたが積み上げたものは、夜の間も消えることはありません。」

English canonical corpus (8 lines):
1. Well done today. What you've built stays through the night.
2. The day is closing. What you placed today remains placed.
3. Good work. Rest, and return when the light comes back.
4. A quiet evening to you. 🪶
5. Even the smallest layer counts, and this one is yours.
6. Tomorrow will begin on its own. Tonight is for setting down.
7. What was hard today is behind you. What was true remains.
8. Sleep well. The map keeps its own shape while you rest.

---

## Part 2: Lilia (English)

### 2.1 Positioning

> Lilia is **the guild receptionist**. A friendly professional, twenty-something, cheerful and helpful. She belongs to the guild page only. She is not a sanctuary — she is a warm workplace.

This is deliberate positioning contrast with Sabi:

| Attribute | Sabi | Lilia |
|---|---|---|
| Role | Sanctuary (personal) | Reception (business) |
| Age | 30s–40s | Early 20s |
| Register | Settled, professional-warm | Cheerful, professional-warm |
| Exclamation marks | Never | Uses them naturally |
| Emoji | 🪶 only, sentence-end | State-linked: 🗡️ ⚔️ 🌸 🛡️ |
| Where user meets them | Home, notifications, dialogs | **Guild page only** |

### 2.2 Tone Rules

| Element | Rule |
|---|---|
| Punctuation | **Exclamation marks welcome** in appropriate places, but not on every sentence. Two exclamation marks per line is the ceiling. |
| Contractions | Use freely |
| Second person | "you". No "sir/ma'am/madam" (over-formal for a peer-adjacent guild clerk) |
| First person | "I" is fine. Occasionally "we" when referring to the guild as institution ("We have new quests today"). |
| Register | Friendly-professional. Think barista who remembers your order, not customer-service script. |
| Emoji | State-linked. Match the emoji to the situation, not to every sentence. |

### 2.3 Eight Scenario Templates (matched to `receptionist_dialogue.yaml`)

Below is the canonical English mapping for the eight scenarios defined in Japanese. Native reviewer should treat these as first-draft candidates and refine idiomatically.

| # | Situation | Japanese source | English candidate |
|---|---|---|---|
| 1 | Default (entering guild) | 「ようこそギルドへ! 本日はどのクエストにご挑戦されますか?🗡️」 | Welcome to the guild! Which quest are you taking on today? 🗡️ |
| 2 | First login (new player) | 「あら、新顔のお客様ですね! 私リリアと申します。ご来訪ありがとうございます 🌸」 | Oh, a new face! I'm Lilia — welcome to the guild. So glad you stopped by. 🌸 |
| 3 | Just leveled up (within 5 min) | 「Lv.{level} おめでとうございます! 強い相手にも挑めるようになりましたね ⚔️」 | Congratulations on reaching Lv.{level}! Stronger opponents are within reach now. ⚔️ |
| 4 | Rest day active | 「あら、本日はお休みの日でしたね。ゆっくりと過ごされるのも一つの戦略ですよ 🌸」 | Ah, it's your rest day. Taking it slow is a strategy of its own. 🌸 |
| 5 | 5+ battles in last hour | 「お疲れ様です! 連戦されていますね。ご無理なさらずに 🛡️」 | Nice work out there! You've been battling nonstop — take care of yourself. 🛡️ |
| 6 | New enemy tier unlocked (Lv.15/25/35) | 「新しい相手が掲示板に追加されましたよ! ご確認くださいませ ⚔️」 | New opponents just went up on the board! Take a look when you're ready. ⚔️ |
| 7 | Just won a battle (within 5 min) | 「お見事です! 戦利品をどうぞお受け取りくださいませ 🗡️」 | Well fought! Your reward is right here. 🗡️ |
| 8 | Just lost a battle (within 5 min) | 「お怪我はありませんでしたか? 次の機会に向けて、装備を見直しましょう! 🛡️」 | Not hurt, I hope? Let's look over your gear for next time. 🛡️ |

### 2.4 Variants (optional, native reviewer to select best)

For scenarios 1 and 3 (highest-frequency), add 2–3 variants each to avoid repetition:

**Scenario 1 variants**:
- "Back again! Ready to take on a quest today? 🗡️"
- "Welcome in. What'll it be — a challenge, or a warm-up? 🗡️"

**Scenario 3 variants**:
- "Look at that — Lv.{level}! You're moving up. ⚔️"
- "Lv.{level} suits you. The board just got more interesting. ⚔️"

---

## Part 3: System Messages (Sabi voice)

Sabi is the voice of the app. Error messages, empty states, and background notifications all carry Sabi's register. **These are the highest-volume Sabi lines in the app** and the most likely to be seen out of context, so tone must survive isolation.

### 3.1 Rules for system messages

- Same period-only + no-imperatives rule
- Keep to 1–2 sentences. Add `🪶` at the end.
- Never blame the user. When something the user did causes a problem, phrase it as a situation, not an action.
  - ❌ "You didn't enter a name."
  - ✅ "A name is needed to save this. 🪶"

### 3.2 Canonical system message set

| Situation | Japanese | English canonical |
|---|---|---|
| Generic error | 「うまくいきませんでした。少し時間をおいて、もう一度お試しください 🪶」 | Something didn't go through. Please try again in a moment. 🪶 |
| Network offline | 「通信ができないようです。電波の届く場所で、もう一度お試しください 🪶」 | The connection seems to be resting. Please try again when signal returns. 🪶 |
| Empty habits list | 「まだ習慣は登録されていません。まずは一つだけ、始めてみましょう 🪶」 | No habits yet. One small one is enough to start. 🪶 |
| Empty timeline | 「今日の予定はまだ空です。ゆっくりと組み立てていきましょう 🪶」 | Today's timeline is open. Fill it at your own pace. 🪶 |
| Save success | 「保存しました 🪶」 | Saved. 🪶 |
| Delete confirmation | 「本当に削除してもよろしいでしょうか」 | Are you sure you want to delete this? |
| Undo hint | 「元に戻せますよ 🪶」 | This can be undone. 🪶 |

### 3.3 Notification body (FCM push, local notification)

Notifications carry extra risk because they surface on the lock screen with less context. Rules:

- **Length ceiling**: 60 characters for iOS notification body (safe for lock screen truncation)
- **No emoji in title**: title stays plain; body may end with `🪶`
- **No imperatives** even for reminders. Frame as an offer.

Examples:
- Reminder to log a habit: title "A gentle check-in from Sabi", body "Whenever you're ready, today is open. 🪶"
- Streak recovery: title "A note from Sabi", body "The layers are still here. Come back when you can. 🪶"

---

## Part 4: Translation Strategy (team notes、日本語)

### 4.1 arb キー命名規約 (Phase 2 実装ガイド)

新規 arb キーは `<domain>_<sabi|lilia|system>_<situation>` の 3 段構成で統一する。命名は translation の "context slot" として機能し、native reviewer が状況を理解しやすくする。

例:
- `home_sabi_daily_start` → Scene C (朝) の一つ
- `guild_lilia_default` → Lilia scenario 1
- `error_system_generic` → 3.2 "Generic error"

`app_ja.arb` と `app_en.arb` の両方で **同じキー** を使う。`app_ja.arb` のメタデータ (`@key` block) に **本ドキュメント §X.Y への参照 + Scene** を書き、意味の drift を防ぐ:

```json
{
  "home_sabi_daily_start": "おはようございます。さて、今日はどんな色の一石を積み上げましょうか。",
  "@home_sabi_daily_start": {
    "description": "Sabi Scene C morning greeting (see doc/design/i18n_persona_en.md §1.5 Scene C line 1)"
  }
}
```

### 4.2 「〜ですね」問題

日本語の穏やかな確認 marker「〜ですね」「〜ますよ」を英語に「isn't it?」「you know」等で機械翻訳すると **不自然** or **passive-aggressive** に響く。方針:

- 削除する: 「素晴らしいですね」→ "Well done." (marker が担う穏やかさは period の呼吸で表現)
- 情報化する: 「〜になっていきますよ」→ "...become steady layers over time." (「時間の経過」を明示することで確信を運ぶ)
- 反対の marker で置換する: 稀に "I suppose" / "I think" が使えるが、Sabi の register には合わないため 3 語未満に留める

### 4.3 感嘆符禁止の徹底

Sabi の英語も「。」相当 = period 主体。翻訳中に思わず「!」を入れたくなる場面 (Congratulations! / Well done! 等) はすべて period に置換する。Phase 2 実装時、`grep -n '!' lib/l10n/app_en.arb` で自動 lint 可能。

例外: Lilia line のみ「!」使用可 (§2.2)。ただし 1 line 2 個までがハウスルール。

### 4.4 Sabi vs Lilia の "誰の line か" の識別

arb key で `_sabi_` / `_lilia_` を prefix にすることで、Phase 2 実装時に音声 (もし v1.2+ TTS 追加時) や text style (Sabi = 落ち着き / Lilia = 明朗) の分岐フックとして使える。Phase 1 では単なる命名規約だが、将来の拡張のための構造投資。

### 4.5 プレースホルダー変数

`Lv.{level}` 等の変数は arb では ICU MessageFormat を使う:

```json
{
  "guild_lilia_level_up_congrats": "Congratulations on reaching Lv.{level}! Stronger opponents are within reach now. ⚔️",
  "@guild_lilia_level_up_congrats": {
    "description": "Lilia scenario 3, shown when player just leveled up",
    "placeholders": {
      "level": {
        "type": "int",
        "example": "18"
      }
    }
  }
}
```

---

## Part 5: Native Speaker Review Checklist

Reviewer (fiverr / friend / paid native English editor) がチェックすべき項目。この checklist を review 依頼時に添える。

### 5.1 Global sanity checks

- [ ] Every Sabi line ends with a period + optional `🪶`. Zero exclamation marks in Sabi lines.
- [ ] Every Lilia line has at least one exclamation mark. Maximum two per line.
- [ ] No line uses banned vocabulary (§1.4).
- [ ] No line addresses user as "friend", "buddy", "champion", "hero".
- [ ] No line uses the word "journey" (§1.4).

### 5.2 Sabi voice checks

- [ ] Does each line **feel like a sanctuary**, not a coach? (§1.1)
- [ ] Are stagnation scenes (Scene B) genuinely affirming rest, or accidentally shaming it?
- [ ] Do metaphors (layers, stones, feather) feel natural or forced?
- [ ] Would a real 30-something introvert say this out loud? If no, revise.

### 5.3 Lilia voice checks

- [ ] Does each line feel like a friendly receptionist, not a customer-service script?
- [ ] Are variants (§2.4) truly distinct, or paraphrases of each other?
- [ ] Do quest/battle metaphors feel warm or juvenile?

### 5.4 Cross-persona checks

- [ ] If Sabi and Lilia lines were shuffled, could a reader still tell which is which? (they should)
- [ ] Are the two personas contrasting but not caricaturing?

### 5.5 System message checks

- [ ] Do error messages avoid blaming the user? (§3.1)
- [ ] Do notification bodies fit 60 characters? Do they still make sense on a lock screen?

---

## Part 6: Known Pitfalls (Pre-mortem for the translation pass itself)

### P1: Native reviewer suggests "make it more energetic"

Some reviewers will optimize for standard app copy conventions (Duolingo-style) and push Sabi toward exclamation marks or "You've got this!". **Reject these suggestions.** Sabi's low-arousal register is the differentiator, not a bug.

Mitigation: brief the reviewer with §1.1 (positioning) and §1.4 (banned vocabulary) **before** they touch a single line. If the reviewer resists after briefing, find a different reviewer.

### P2: "You" repetition feels flat

English "you" appears more often than 「あなた」 does in Japanese (which can be dropped). Reviewer may push for pronoun variety.

Mitigation: use verbless constructions and imperatives-of-invitation (§1.5 Scene A line 3 "Another one placed.") to relieve pressure. Do not introduce "we" for Sabi (patronizing).

### P3: 🪶 marker is unfamiliar to English readers

Some readers may parse `🪶` as decorative rather than as Sabi's signature.

Mitigation: consistency of placement (always end-of-line, after period + space) trains the pattern within 5–10 exposures. No signage or tutorial needed.

### P4: Cultural mismatch on "rest is legitimate"

American productivity culture may treat Scene B (rest affirmation) lines as counterproductive. This is a **feature, not a bug** — Sabiowl's differentiator against Habitica/Finch is exactly this stance.

Mitigation: for α英語話者テスト (Sep 2026), specifically ask testers whether Scene B lines feel supportive or feel like the app "giving up on them". Adjust wording, not intent.

### P5: Lilia over-formality bleed

Reviewer may push Lilia toward "sir/ma'am" or formal customer-service register.

Mitigation: brief reviewer that Lilia is "the barista at your regular coffee shop" archetype — warm-professional, first-name terms, no formal address.

### P6: Emoji removal by reviewer

Some editors reflexively strip emoji from professional copy.

Mitigation: 🪶 for Sabi and 🗡️ ⚔️ 🌸 🛡️ for Lilia are **non-negotiable brand elements**. Brief this before review.

---

## Part 7: Next Steps

### 7.1 Immediate (Aug 2026)

- [ ] Share this document with 1–2 native English speaker candidates (fiverr / friend network) for initial reaction
- [ ] Once reviewer is selected, brief with Parts 1, 2, 5 before touching any lines
- [ ] Receive first-pass edits, discuss any P1–P6 pushback

### 7.2 Mid-term (Sep 2026)

- [ ] Merge final approved corpus into `mobile/lib/l10n/app_en.arb` via Phase 2 ARB migration
- [ ] Add non-canonical strings (buttons, form labels, etc.) with same reviewer's oversight
- [ ] Run first α test with 3+ native English speakers using the app in English

### 7.3 Post-launch (Nov 2026+)

- [ ] Monitor App Store reviews specifically for tone feedback ("this app is calm/preachy/twee/warm")
- [ ] If Sabi corpus needs revision, edit here first, then propagate to arb

---

## Part 8: References

- [FEAT-489 Phase 3 scope](../instructions/FEAT-489_v1_1_english_localization.md#Phase-3) — this document is the Phase 3 deliverable
- [CLAUDE.md § サビの存在意義](../../CLAUDE.md) — Japanese-original philosophy statement, the source of truth for Sabi's meaning
- [CLAUDE.md § 受付女性リリアの口調ルール](../../CLAUDE.md) — Japanese-original Lilia rules
- [receptionist_dialogue.yaml](../../mobile/lib/features/guild/data/receptionist_dialogue.yaml) — canonical Japanese Lilia scenarios (8 items), Phase 2 will add English mirror file

---

## Part 9: Change Log

- **2026-07-29**: Initial draft (FEAT-489 Phase 3 起稿、PM 直接、~30-40 sample lines、native reviewer briefing 用資料)
