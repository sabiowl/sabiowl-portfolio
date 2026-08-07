// 【FEAT-489 Phase 2G-b §2.1】英語 Sabi / Lilia トーンの CI ガード。
//
// ## なぜ必要か
//
// `sabi_tone_test.dart` は **日本語だけ**を検査している (禁止語が「じゃよ」「ワシ」等)。
// 英語の Sabi 台詞 299 key / Lilia 台詞 16 key には **ガードが 1 つも無かった**。
//
// Phase 3 の native reviewer ($150) が語感を整えても、その後の regression を
// 止める網が無ければ成果は少しずつ崩れる。ここを先に締める。
//
// 実際、PM の 2026-08-02 実測で **既に 3 件の逸脱が混入していた** (2 件は修正済)。
// 本テスト作成時の再実測で **4 件目 (`unleash`) も見つかった** (§4 参照)。
//
// ## 判定基準
//
// `doc/design/i18n_persona_en.md` の Part 1.3 (Sabi トーン) / 1.4 (禁止語彙) /
// 2.2 (Lilia トーン) / 5.1 (Global sanity checks) が真実値。
// **判定対象は `app_en.arb` の値**。生成 dart ではなく arb が真実値。
//
// ## 誤検出を避けるための 3 つの設計 (Pre-mortem S2)
//
// 1. **単語境界 (`\b`) で判定する** — 部分一致にすると無関係な語を拾う
// 2. **Sabi / Lilia の台詞 key に限定する** — UI ラベルや既定値は対象外。
//    一律判定にすると既定名「勇者」の訳語 `Hero` (`authOnboardingDefaultName`) や
//    ジョブ名 `Warrior` (`battleJobNameWarrior`) まで落ちる (PM 実測で発生済)
// 3. **呼びかけ語は vocative パターンで判定する** — `friend` を単語一致で禁じると
//    "Friend ID copied." のような **機能名としての friend** まで落ちる。
//    guide §5.1 が禁じているのは "addresses user as friend" = 呼びかけ
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/i18n_persona_en_test.dart
// ```

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// allowlist — reviewer 判断待ちの既知逸脱
// ─────────────────────────────────────────────────────────────────────────────

/// 禁止語彙の**既知の逸脱**。`key` → 許容する語。
///
/// **ここは「まだ直していない」置き場であって「直さなくてよい」置き場ではない。**
/// Phase 2F-b (reviewer 納品の反映) で **空にすることが目標**。
///
/// | key | 語 | なぜ今は許容するか | いつ外すか |
/// |---|---|---|---|
/// | `authOnboardingSlide1SubtitleSabi_message` | journey | 日本語原文が「旅」。guide §1.4 は `journey` を英語圏 wellness アプリのクリシェとして禁止しているが、**原文の比喩を保ったまま何に置き換えるかは native の語感が要る** ("path" / "practice" / 比喩を落とす等、いずれも意味が変わる) | Phase 2F-b で reviewer の置換案を反映したら削除 |
/// | `authOnboardingNameSubtitleSabi_message` | journey | 同上 | 同上 |
/// | `authOnboardingCharacterTitle` | journey | 同上。**ただし本 key は Sabi/Lilia の台詞 key ではない**ため現状の検査範囲外。3 件を一緒に片付けられるよう、追跡目的でここに残す | 同上 |
/// | `battleUltimateReadyTooltipSabi_message` | unleash | **本テスト作成時 (2026-08-02) に新たに発見**。PM の実測 3 件には含まれていない 4 件目。"Tap to unleash your ultimate." は guide §1.4 の `unleash` に該当する。置換 ("release" / "call up" / 言い換え) は Sabi の語彙選択そのものなので reviewer 判断に回す | 同上 |
const _bannedVocabAllowlist = <String, Set<String>>{
  'authOnboardingSlide1SubtitleSabi_message': {'journey'},
  'authOnboardingNameSubtitleSabi_message': {'journey'},
  'authOnboardingCharacterTitle': {'journey'},
  'battleUltimateReadyTooltipSabi_message': {'unleash'},
};

/// Lilia なのに `!` を持たない**既知の逸脱**。
///
/// | key | なぜ今は許容するか | いつ外すか |
/// |---|---|---|
/// | `guildLiliaRestDay1` | **guide と原文が食い違っている**。guide §2.2 は「Lilia は `!` を使う」とするが、日本語原文「あら、本日はお休みの日でしたね。ゆっくりと過ごされるのも一つの戦略ですよ 🌸」には `!` が無い。休息肯定の場面なので**意図的にトーンダウンしている可能性**があり、機械では決められない | Phase 2F-b で reviewer が「Lilia は休息場面でも `!` を使うか」を判断したら、`!` を足すか本 allowlist から削除する |
const _liliaNoExclamationAllowlist = <String>{
  'guildLiliaRestDay1',
};

// ─────────────────────────────────────────────────────────────────────────────
// 禁止語彙 (persona guide §1.4 / §5.1)
// ─────────────────────────────────────────────────────────────────────────────

/// **どの persona でも使ってはいけない語**。単語境界で判定する。
///
/// guide §1.4 の禁止リストのうち、Sabi の静穏トーン固有ではなく
/// 「Duo 的な煽り」「wellness クリシェ」に該当するもの。
const _hardBannedWords = <String>[
  'awesome',
  'amazing',
  'superstar',
  'rockstar',
  'unleash',
  'journey',
];

/// **どの persona でも使ってはいけない定型句**。語ではなくフレーズ単位。
const _hardBannedPhrases = <String>[
  'crush it',
  'nailed it',
  'keep grinding',
  "you've got this",
  "let's go",
  'reach for the stars',
  'unlock your potential',
];

/// **Sabi でのみ禁止**する語。
///
/// guide §1.4 は Part 1 (= Sabi) の配下にあり、Lilia は §2.2 で
/// 「cheerful / exclamation marks welcome / barista のような register」と
/// **意図的に対照的**に定義されている。Lilia の "Great work!" は彼女らしい英語で、
/// ここに Sabi の語彙制限をかけると guide §5.4 の
/// 「2 人の台詞を混ぜても区別がつくこと」という要求と衝突する。
const _sabiOnlyBannedWords = <String>[
  'great',
  'warrior',
];

/// **ユーザーへの呼びかけとして使ってはいけない語** (guide §5.1)。
///
/// 単語一致にすると機能名としての用法まで落ちるので vocative パターンで判定する:
///   - 直前がカンマ ("Well done, friend.")
///   - 文末に単独で置かれる ("You did it, champion!")
///
/// 落としたくない例: "Friend ID copied." / "one per friend per day"
const _vocativeBannedWords = <String>[
  'friend',
  'buddy',
  'pal',
  'champion',
  'hero',
  'dear',
];

// ─────────────────────────────────────────────────────────────────────────────
// LLM 文体マーカー (2026-08-04 追加)
//
// ## なぜ「禁止語彙」と別枠なのか
//
// §1.4 の禁止語彙は「Duo 的な煽り / wellness クリシェ」を狙う。ここで狙うのは別物で、
// **Claude / ChatGPT が既定で書く英語の癖**。文法的には正しく、丁寧で、
// レビューを通しやすいが、英語話者には「AI が書いた文」として認識される。
//
// 同じ癖を LLM 同士が共有しているので、**別モデルにレビューさせても検出されにくい**。
// 機械的に判定できるものだけをここで落とし、語感の判断は native reviewer に回す。
//
// ## 実測 (2026-08-04、Sabi 台詞 322 件)
//
//   Let us …        8 件  「Let us set out again tomorrow.」= 式辞・聖書調
//   quite + just yet 3 件  「You don't have quite enough coins just yet.」= softener 3 連
//
// いずれも FEAT-515 で PM (Claude) 自身が書いたもの。全件修正済み。
// ─────────────────────────────────────────────────────────────────────────────

/// 短縮すべき形式ばった言い回し。`pattern` にマッチしたら `suggestion` を促す。
///
/// **`Let us know` は正しい英語なので除外する**。ここを単純な `Let us` 一致に
/// すると `settingsDeleteStep2FreeTextLabel`「Let us know if you'd like」が
/// 誤検出される (実際に一括置換で壊しかけた)。
const _stiltedPhrases = <({String pattern, String suggestion})>[
  (pattern: r'\bLet us (?!know\b)', suggestion: "Let's"),
  (pattern: r'\bDo not\b(?! hesitate)', suggestion: "Don't"),
  (pattern: r'\bKindly\b', suggestion: '削除するか Please に'),
];

/// **サビを「老いた存在」として描写しない** (2026-08-04 追加)。
///
/// CLAUDE.md はサビを **30〜40 代の紳士的なフクロウ**と定義し、老人口調
/// (「ワシは見ておったぞ」「〜じゃのう」) を明確に禁止している。
/// ところが英語では `wise old owl` が**固定表現**なので、LLM が強く引き寄せられる。
///
/// 実際、batch 01 のレビューで ChatGPT が
/// `I'm Sabi, a wise old owl.` を提案してきた。ブリーフに「30s–40s」と
/// 明記していたにもかかわらず、**再出力させても同じ提案が返ってきた**。
/// 文章での指示では防げないと判断し、機械で落とす。
///
/// 「賢者」の訳語としての `wise` は正しいので禁止しない。問題は `old` の方。
///
/// ## `old` を単独で禁止しない理由
///
/// `Older memos are not shown.` のような正当な用法がある (実測 2 件)。
/// 単独禁止にすると将来「your older records」等で誤検出するので、
/// **サビを指す結合パターン**だけを禁じる。
const _agedSabiPatterns = <String>[
  r'\bold owl\b',
  r'\bwise old\b',
  r'\bold man\b',
  r'\bold sage\b',
  r'\belderly\b',
  r'\bancient\b',
  r'\bvenerable\b',
  r'\bwizened\b',
  r'\bgrandfatherly\b',
];

/// **softener を重ね掛けしない**。
///
/// 日本語の「〜ようですね」は softener 1 つだが、LLM は英語で
/// `don't have` + `quite enough` + `just yet` と 3 つ重ねがちで、
/// 丁寧を通り越して**言い訳がましく**読める。
///
/// 同一文字列に 2 つ以上現れたら落とす。単独での使用
/// (`not quite ready` / `quite a few` は自然な英語) は許す。
const _hedgeWords = <String>[
  'quite',
  'just yet',
  'somewhat',
  'a bit of a',
];

void main() {
  late Map<String, String> en;
  late Map<String, String> ja;

  setUpAll(() {
    en = _readArbMessages('lib/l10n/app_en.arb');
    ja = _readArbMessages('lib/l10n/app_ja.arb');
  });

  Map<String, String> sabiLines() => {
        for (final e in en.entries)
          if (e.key.endsWith('Sabi_message')) e.key: e.value,
      };

  Map<String, String> liliaLines() => {
        for (final e in en.entries)
          if (e.key.startsWith('guildLilia')) e.key: e.value,
      };

  // ───────────────────────────────────────────────────────────────────────────
  // A: Sabi は感嘆符を使わない (guide §1.3 / §5.1)
  // ───────────────────────────────────────────────────────────────────────────
  group('A: Sabi の句読点', () {
    test('Sabi 台詞に "!" が含まれない', () {
      final offenders = <String>[];
      sabiLines().forEach((k, v) {
        if (v.contains('!')) offenders.add('$k: $v');
      });

      expect(
        offenders,
        isEmpty,
        reason: 'Sabi は「穏やかな確信」を period で表現します '
            '(persona guide §1.3: Periods only. No exclamation marks)。\n'
            '感嘆符を入れると Duo 的な煽りトーンになり、'
            '「静かな聖域」というプロダクトミッションが崩れます。\n'
            '${offenders.join('\n')}',
      );
    });

    test('Sabi 台詞が 1 件以上ある (key 命名が変わって検査が空振りしていない)', () {
      expect(sabiLines().length, greaterThan(200),
          reason: '*Sabi_message suffix の命名規約が変わると本テストが '
              '0 件検査で常時 green になります (guard の空振り検出)');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // B: Lilia は感嘆符を 1〜2 個持つ (guide §2.2)
  // ───────────────────────────────────────────────────────────────────────────
  group('B: Lilia の句読点', () {
    test('Lilia 台詞は "!" を 1 個以上持つ', () {
      final offenders = <String>[];
      liliaLines().forEach((k, v) {
        if (_liliaNoExclamationAllowlist.contains(k)) return;
        if (!v.contains('!')) offenders.add('$k: $v');
      });

      expect(
        offenders,
        isEmpty,
        reason: 'Lilia は明朗なギルド受付です '
            '(persona guide §2.2: Exclamation marks welcome)。\n'
            '感嘆符が消えると Sabi との対照が失われ、'
            '§5.4「2 人の台詞を混ぜても区別がつくこと」を満たせなくなります。\n'
            '意図的にトーンダウンさせる場合は _liliaNoExclamationAllowlist に'
            '理由と解除条件を書いて追加してください。\n'
            '${offenders.join('\n')}',
      );
    });

    test('Lilia 台詞の "!" は 2 個まで', () {
      final offenders = <String>[];
      liliaLines().forEach((k, v) {
        final n = '!'.allMatches(v).length;
        if (n > 2) offenders.add('$k ($n 個): $v');
      });

      expect(offenders, isEmpty,
          reason: 'persona guide §2.2: Two exclamation marks per line is the '
              'ceiling。3 個以上は customer-service script 的な過剰さになります。\n'
              '${offenders.join('\n')}');
    });

    test('Lilia 台詞が 1 件以上ある (guard の空振り検出)', () {
      expect(liliaLines().length, greaterThan(10));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // C: 禁止語彙 (guide §1.4 / §5.1)
  // ───────────────────────────────────────────────────────────────────────────
  group('C: 禁止語彙', () {
    test('Sabi / Lilia 台詞に hard-banned な語が含まれない', () {
      final offenders = <String>[];
      final persona = {...sabiLines(), ...liliaLines()};

      persona.forEach((key, value) {
        final allowed = _bannedVocabAllowlist[key] ?? const <String>{};
        for (final w in _hardBannedWords) {
          if (allowed.contains(w)) continue;
          if (_hasWord(value, w)) offenders.add('[$w] $key: $value');
        }
        for (final p in _hardBannedPhrases) {
          if (allowed.contains(p)) continue;
          if (value.toLowerCase().contains(p.toLowerCase())) {
            offenders.add('[$p] $key: $value');
          }
        }
      });

      expect(
        offenders,
        isEmpty,
        reason: 'persona guide §1.4 の禁止語彙です。\n'
            'これらは英語圏の self-help / wellness アプリのクリシェで、'
            'Sabi を「よくある励ましアプリ」に見せてしまいます。\n'
            'reviewer 判断が要る場合は _bannedVocabAllowlist に'
            '理由と解除条件を書いて追加してください。\n'
            '${offenders.join('\n')}',
      );
    });

    test('Sabi 台詞に Sabi 固有の禁止語が含まれない', () {
      final offenders = <String>[];

      sabiLines().forEach((key, value) {
        final allowed = _bannedVocabAllowlist[key] ?? const <String>{};
        for (final w in _sabiOnlyBannedWords) {
          if (allowed.contains(w)) continue;
          if (_hasWord(value, w)) offenders.add('[$w] $key: $value');
        }
      });

      expect(
        offenders,
        isEmpty,
        reason: 'Sabi の語彙は「静かな聖域」のトーンに合わせます '
            '(persona guide §1.4)。\n'
            'なお Lilia には本チェックをかけていません —— 彼女の "Great work!" は '
            '§2.2 の cheerful な register に沿った自然な英語で、\n'
            'Sabi の制限を適用すると §5.4「2 人の対照」が失われるためです。\n'
            '${offenders.join('\n')}',
      );
    });

    test('ユーザーを friend / buddy / champion 等と呼びかけない', () {
      final offenders = <String>[];
      final persona = {...sabiLines(), ...liliaLines()};

      persona.forEach((key, value) {
        for (final w in _vocativeBannedWords) {
          if (_hasVocative(value, w)) offenders.add('[$w] $key: $value');
        }
      });

      expect(
        offenders,
        isEmpty,
        reason: 'persona guide §5.1: No line addresses user as "friend", '
            '"buddy", "champion", "hero"。\n'
            '馴れ馴れしさ / 見下しに読まれます。\n'
            '(機能名としての friend —— "Friend ID copied." 等 —— は対象外です)\n'
            '${offenders.join('\n')}',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // C-2: LLM 文体マーカー (2026-08-04 追加)
  // ───────────────────────────────────────────────────────────────────────────
  group('C-2: LLM 文体マーカー', () {
    test('形式ばった言い回しを使っていない (Let us / Do not / Kindly)', () {
      // **全 en key** が対象。UI ラベルでも「Let us …」は同じく不自然なため。
      final offenders = <String>[];
      en.forEach((key, value) {
        for (final p in _stiltedPhrases) {
          if (RegExp(p.pattern).hasMatch(value)) {
            offenders.add('[${p.suggestion} に] $key: $value');
          }
        }
      });

      expect(
        offenders,
        isEmpty,
        reason: '短縮しない形式ばった言い回しは、日常のアプリ文言では '
            '**式辞や聖書のように響きます**。\n'
            '文法エラーではないので AI レビューでは素通りしやすく '
            '(「格調高い」と評価されることすらある)、ここで機械的に落とします。\n'
            '2026-08-04 の実測では Sabi 台詞に "Let us …" が 8 件ありました。\n'
            '${offenders.join('\n')}',
      );
    });

    test('サビを老いた存在として描写していない', () {
      // 対象は **Sabi 台詞 + 値に "Sabi" を含む key**。
      // 後者を含めるのは、サビを描写するのが台詞とは限らないため
      // (authOnboardingSlide1TitleSabi_message のようなタイトル行もある)。
      final target = <String, String>{
        ...sabiLines(),
        for (final e in en.entries)
          if (RegExp(r'\bSabi\b').hasMatch(e.value)) e.key: e.value,
      };

      final offenders = <String>[];
      target.forEach((key, value) {
        for (final p in _agedSabiPatterns) {
          if (RegExp(p, caseSensitive: false).hasMatch(value)) {
            offenders.add('[$p] $key: $value');
          }
        }
      });

      expect(
        offenders,
        isEmpty,
        reason: 'CLAUDE.md はサビを **30〜40 代の紳士的なフクロウ**と定義し、\n'
            '老人口調 (「ワシは見ておったぞ」等) を明確に禁止しています。\n'
            '英語では "wise old owl" が固定表現なので LLM が強く引き寄せられ、\n'
            '**日本語側が最も避けている性格付けを英語で再導入**することになります。\n'
            '実際 batch 01 のレビューで 2 回連続で提案されました。\n'
            '「賢者」の訳語としての wise は正しいので、直すのは old の方です。\n'
            '${offenders.join('\n')}',
      );
    });

    test('softener を 1 文に 2 つ以上重ねていない', () {
      final offenders = <String>[];
      sabiLines().forEach((key, value) {
        final hit = _hedgeWords
            .where((w) => value.toLowerCase().contains(w))
            .toList();
        if (hit.length >= 2) offenders.add('[${hit.join(" + ")}] $key: $value');
      });

      expect(
        offenders,
        isEmpty,
        reason: '日本語の「〜ようですね」は softener 1 つですが、英語で '
            "don't have + quite enough + just yet と重ねると\n"
            '丁寧を通り越して **言い訳がましく** 読めます。\n'
            '単独使用 (not quite ready / quite a few) は自然なので落としません。\n'
            '${offenders.join('\n')}',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // D: ja / en のトーン整合 — 原文に無い感嘆符を英訳で足していないか
  // ───────────────────────────────────────────────────────────────────────────
  group('D: ja / en のトーン整合', () {
    test('日本語原文に "!" が無い Lilia 台詞で、英訳だけ 3 個以上に増えていない', () {
      // Lilia は英語で `!` を足してよい (日本語の「〜ですよ!」が英語で自然に
      // なるよう調整するのは想定内)。ただし原文 0 個 → 英訳 3 個以上は
      // 明らかな増幅なので拾う。
      final offenders = <String>[];
      liliaLines().forEach((k, v) {
        final jaVal = ja[k];
        if (jaVal == null) return;
        final jaN = '!'.allMatches(jaVal).length + '！'.allMatches(jaVal).length;
        final enN = '!'.allMatches(v).length;
        if (jaN == 0 && enN >= 3) offenders.add('$k (ja=$jaN → en=$enN): $v');
      });

      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// helpers
// ─────────────────────────────────────────────────────────────────────────────

Map<String, String> _readArbMessages(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue,
      reason: '$path が見つかりません。プロジェクトルート (mobile/) から実行してください');
  final decoded = json.decode(f.readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final e in decoded.entries)
      if (!e.key.startsWith('@') && e.value is String) e.key: e.value as String,
  };
}

/// 単語境界での一致判定 (Pre-mortem S2)。
///
/// 部分一致にすると `pal` が `palette` を、`hero` が `heroic` を拾う。
bool _hasWord(String text, String word) =>
    RegExp(r'\b' + RegExp.escape(word) + r's?\b', caseSensitive: false)
        .hasMatch(text);

/// **呼びかけとしての**使用かを判定する。
///
/// 拾う: "Well done, friend." / "Nice work, champion!" / "You did it, hero"
/// 拾わない: "Friend ID copied." / "one per friend per day" / "Friend Profile"
bool _hasVocative(String text, String word) {
  final w = RegExp.escape(word);
  // ① 直前がカンマ — 英語の呼格はほぼ必ずカンマで区切られる
  if (RegExp(',\\s*$w\\b', caseSensitive: false).hasMatch(text)) return true;
  // ② 文頭の呼びかけ ("Friend, ..." のような形)
  if (RegExp('^$w\\s*,', caseSensitive: false).hasMatch(text.trim())) {
    return true;
  }
  return false;
}
