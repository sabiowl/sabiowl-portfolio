// 【FEAT-489 Phase 2E】i18n カバレッジの構造ガード。
//
// ## なぜ必要か
//
// Phase 2 の feature 別内訳表 (2026-07-30 作成) は当時の `lib/features/` の grep に
// 依存しており、**以後追加された 4 feature (shop / puzzle_world / task_suggestion /
// announcement) を拾えていなかった**。この 4 つは `AppLocalizations` 参照が 1 件も
// ないまま Phase 2A-2D を通過し、2026-08-02 の PM verify で初めて検出された。
//
// 根本原因は「表に無い dir が静かに増えた」こと。同じ事故を人間の目視ではなく CI で
// 止めるためのテストが本ファイル。
//
// ## 3 つの check
//
// - A: feature dir 網羅 — UI (pages/ or widgets/) を持つ dir は必ず l10n を参照する
// - B: 残 hardcode 閾値 — 日本語リテラル総数が既知の baseline を超えたら fail
// - C: ARB 整合 — ja / en の key 差分ゼロ + en 側に日本語残留ゼロ
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/i18n_coverage_test.dart
// ```

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 閾値
// ─────────────────────────────────────────────────────────────────────────────

/// check B の上限。**下げる方向にのみ更新すること**。
///
/// ## この数字の根拠 (2026-08-02 Phase 2F-a 完了時点の実測)
///
/// 本ファイル下部の filter (コメント / raw string / RegExp / developer-facing /
/// API enum key) を通した後の実測値は **62 件** (Phase 2E 時点は 150 件)。
/// 内訳を目視分類した結果、**残りはすべて「意図的に残すもの」か「別条件待ち」**:
///
/// | 分類 | 件数 | なぜ残っているか |
/// |---|---:|---|
/// | ジョブ名 (`job_choices.dart` / `job.dart`) | 29 | **Backend `Job.job_name_en` (migration 0198) の prod deploy 待ち**。Mobile を先に出すと API 由来「戦士」/ ローカル "Warrior" の画面内 2 言語混在になる (Phase 2F Pre-mortem S3) |
/// | 日本語パーサのトークン (`smart_text_parser`) | 15 | **恒久的に残る**。`replaceAll('来週', '')` 等は日本語入力を解析するロジックそのもので翻訳対象ではない。英語入力の解析は別の設計判断 |
/// | dev 専用セットアップ手順 (`firebase_options_dev.dart`) | 7 | dev flavor 未設定時に開発者へ出す `throw` の文言。エンドユーザーに到達しない |
/// | Backend エラー文字列との照合 (`settings_page.dart`) | 5 | `raw.contains('別の Sabiowl')` / `defaultLikeNames` 等。**表示ではなく判定データ**なので翻訳すると判定が壊れる |
/// | ジョブ種別の判定データ (`battle_orchestrator._attackTypeOf`) | 2 | 表示名ベースの判定で、既に dead branch。修正はゲームバランス変更を伴うため PM 判断待ち (同関数のコメント参照) |
/// | 既定プレイヤー名 (`'勇者'` / `'ゲスト'`) | 3 | 保存される**ユーザーデータの初期値**。locale で変えると `settings_page` の「初期名のままか」判定と食い違う |
/// | 同期状態のログ文言 (`calendar_page`) | 1 | `debugPrint` の引数だが複数行に跨るため filter が拾えていない |
///
/// 閾値は 62 + マージン 5 = **67**。マージンを 5 に絞っているのは、
/// 大きく取ると「気付かないうちに 20 件増えていた」を許してしまい、
/// 本テストが形骸化するため (handoff Pre-mortem S4)。
///
/// **次に下げるタイミング**: Backend migration 0198 の prod deploy 後、
/// ジョブ名 29 件を回収したら **38 + 5 = 43** まで下げること。
/// 上げる変更は「なぜ増やすのか」を PR に書けないなら入れてはいけない。
const int kMaxJapaneseLiterals = 67;

// ─────────────────────────────────────────────────────────────────────────────
// filter 定義 (handoff §2.5 / develop.md §Phase 2C 知見 1)
// ─────────────────────────────────────────────────────────────────────────────

/// 日本語 (ひらがな / カタカナ / 漢字) の判定。
///
/// **絵文字を含めないことが重要**。develop.md §Phase 2C 知見 1 が報告した
/// 「`'💎'` や `'🪶'` が日本語として誤検出される」現象は、shell の grep が
/// `[あ-ん一-龯]` をバイト範囲として解釈することに起因する。Dart では
/// Unicode コードポイントで判定するため、範囲を正確に切れば混入しない。
final _japanese = RegExp(r'[ぁ-ゟ゠-ヿ一-鿿]');

/// Dart の文字列リテラル (raw 文字列 `r'...'` を含む)。
final _stringLiteral = RegExp(r"""r?'(?:[^'\\\n]|\\.)*'|r?"(?:[^"\\\n]|\\.)*"?""");

/// 開発者向け出力。ユーザーには見えないので l10n 対象外。
final _developerFacing = RegExp(
  r'\b(debugPrint|print|assert|throw\s+\w*(Exception|Error)|FormatException'
  r'|StateError|ArgumentError|UnimplementedError)\b',
);

final _regExpCall = RegExp(r'\bRegExp\s*\(');

/// 【FEAT-514】通貨記号の hardcode 判定 (check E)。
///
/// - `¥` / `€` / `£` / `₩` は Dart の構文上の意味を持たないため、文字列リテラル内に
///   現れた時点で価格の hardcode とみなす。
/// - `$` は文字列補間 (`$name` / `${expr}`) と衝突するので、**直後が数字のときだけ**
///   通貨記号と判定する。Dart の識別子は数字で始められないため、`'$0.99'` は
///   補間ではありえず、`'$errorCode'` / `'${e}'` を誤検出しない (Pre-mortem S4)。
final _currencyHardcode = RegExp(r'[¥€£₩]|\$\s*\d');

/// Backend の API 値そのもの (表示値ではない)。
///
/// `Habit.CATEGORY_CHOICES` の 11 値 + `CharacterStat` の 6 軸。
/// これらは `'運動' => l10n.habitCategoryExercise` のように **switch の key** として
/// 現れるのが正しい姿 (Data + Display 分離)。表示側は l10n を通っているので、
/// key 側のリテラルを hardcode 残として数えてはいけない。
///
/// 真実値: `backend/api/constants.py` の `CATEGORY_STAT_MAP` / CLAUDE.md
/// 「カテゴリ → 6 ステータス分散マッピング」。
const _apiEnumValues = <String>{
  // Habit.CATEGORY_CHOICES (11 値)
  '運動', '学習', '仕事', '体力', '美容', '健康', '精神', '創造', '社交', '休息', 'その他',
  // CharacterStat 6 軸
  '運動力', '学習力', '健康力', '精神力', '創造力', '貢献力',
};

/// 【FEAT-489 Phase 2G-a】check C (en 側に日本語が残っていない) の**意図的な例外**。
///
/// 言語選択の選択肢は、現在の表示言語に関わらず **その言語自身の表記 (endonym)**
/// で出すのが業界標準 (iOS / Android / GitHub / Google すべて同様)。
/// 英語 UI で「Japanese」と訳してしまうと、**誤って英語に切り替えてしまった
/// 日本語話者が元に戻す手がかりを失う** —— 一番助けが要る人が詰む。
///
/// ここに追加してよいのは「翻訳漏れではなく、翻訳しないことが正しい」と
/// 説明できる key だけ。増やすときは必ず理由をコメントに残すこと。
const _endonymKeys = <String>{
  'settingsLanguageOptionJa',  // 日本語 (en 側でも「日本語」のまま)
};

/// 【FEAT-489 Phase 2G-b §2.4】ja と en が**一致していて正しい** key。
///
/// この check の目的は「訳し忘れて日本語をそのままコピーした」痕跡を拾うこと。
/// 以下は一致が正しいので除外する:
///
///   - 固有名詞 (アプリ名)
///   - placeholder と記号だけで構成され、訳す語が無いもの
///   - 英語圏でもそのまま通じる借用語 (ToDo)
///   - 言語選択の endonym (両言語で同じ表記にするのが正しい / [_endonymKeys] 参照)
///
/// 追加するときは「なぜ一致が正しいか」を必ず書くこと。
const _jaEnIdenticalAllowlist = <String>{
  // 固有名詞
  'appTitle',                                   // Sabiowl
  // placeholder + 記号のみ (訳す語が無い)
  'battlePartyWeaponSlotEquipped',              // 🗡️ {name} (+{atkBonus})
  'gamifCharacterJobMasteryMax',                // {jobName} Lv 10 (Max)
  'gamifCharacterJobMasteryProgress',           // {jobName} Lv {level} / 10
  'habitEditHabitLegendaryUnlockedChip',        // {label} ({slotsUsed}/{slotsTotal})
  'socialNotificationsPageAnnouncementDateShort',  // {year}/{month}/{day}
  'coreNotificationTaskDueTitle',               // 📋 {title}
  'battleLogAttackLine',                        // {attacker} {ability} → {target} -{damage} HP
  // 英語圏でもそのまま通じる借用語
  'calendarDailyTaskTodoSection',               // ToDo
  'freeMemoPageEmptyFlowLeafTodo',              // ToDo
  // 言語選択の endonym (_endonymKeys 参照)
  'settingsLanguageOptionJa',                   // 日本語
  'settingsLanguageOptionEn',                   // English
};

// ─────────────────────────────────────────────────────────────────────────────

void main() {
  late Directory libDir;

  setUpAll(() {
    libDir = Directory('lib');
    expect(
      libDir.existsSync(),
      isTrue,
      reason: 'lib/ が見つかりません。'
          'プロジェクトルート (mobile/) から実行してください。',
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // check A: feature dir 網羅 (本テストの主目的)
  // ───────────────────────────────────────────────────────────────────────────
  test('A: UI を持つ feature dir は必ず AppLocalizations を参照する', () {
    final featuresDir = Directory('lib/features');
    expect(featuresDir.existsSync(), isTrue);

    final offenders = <String>[];

    for (final entity in featuresDir.listSync().whereType<Directory>()) {
      final name = entity.path.split(RegExp(r'[/\\]')).last;

      final dartFiles = entity
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();

      // UI を持たない feature (provider / service だけの dir、例: stats) は対象外。
      // 「pages/ か widgets/ に .dart がある」= 画面を描く dir、と定義する。
      // allowlist を持たない判定にすることで、将来 dir が増えても自動追従する。
      final hasUi = dartFiles.any((f) {
        final p = f.path.replaceAll(r'\', '/');
        return p.contains('/pages/') || p.contains('/widgets/');
      });
      if (!hasUi) continue;

      final referencesL10n = dartFiles.any(
        (f) => f.readAsStringSync().contains('AppLocalizations'),
      );
      if (!referencesL10n) offenders.add(name);
    }

    expect(
      offenders,
      isEmpty,
      reason: '以下の feature は UI を持つのに AppLocalizations 参照が 0 件です。\n'
          'FEAT-489 の ARB 化から漏れている可能性が高いので、\n'
          'doc/instructions/FEAT-489_phase_2_develop_handoff.md §2.0 の表に追加し、\n'
          'ARB 化してください:\n'
          '  ${offenders.join(', ')}',
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // check B: 残 hardcode 閾値
  // ───────────────────────────────────────────────────────────────────────────
  test('B: 日本語 hardcode リテラルが baseline を超えていない', () {
    final hits = _collectJapaneseLiterals(libDir);

    expect(
      hits.length,
      lessThanOrEqualTo(kMaxJapaneseLiterals),
      reason: '日本語 hardcode リテラルが baseline (=$kMaxJapaneseLiterals) を'
          '超えました (実測 ${hits.length} 件)。\n'
          '新規 UI 文言は lib/l10n/app_ja.arb + app_en.arb に追加し、\n'
          'AppLocalizations.of(context)! 経由で参照してください。\n'
          '(BuildContext を持たない層は core/l10n/service_l10n.dart の '
          'ServiceL10n.current)\n'
          '増分の可能性がある箇所:\n'
          '${hits.take(20).map((h) => '  $h').join('\n')}',
    );

    // 減った場合の ratchet 忘れを検出する。閾値が実測から乖離すると
    // 「20 件増えても気付かない」状態に戻り、ガードが形骸化する (Pre-mortem S4)。
    expect(
      hits.length,
      greaterThan(kMaxJapaneseLiterals - 30),
      reason: '実測 ${hits.length} 件に対して baseline '
          '($kMaxJapaneseLiterals) が緩すぎます。\n'
          'kMaxJapaneseLiterals を実測値 + 5 程度まで下げてください '
          '(ratchet)。',
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // check C: ARB 整合
  // ───────────────────────────────────────────────────────────────────────────
  group('C: ARB 整合', () {
    Map<String, dynamic> readArb(String path) {
      final f = File(path);
      expect(f.existsSync(), isTrue, reason: '$path が見つかりません');
      return json.decode(f.readAsStringSync()) as Map<String, dynamic>;
    }

    test('ja / en の key 差分が 0', () {
      final ja = readArb('lib/l10n/app_ja.arb');
      final en = readArb('lib/l10n/app_en.arb');

      // '@' 始まりは metadata (ja のみが持つ)。'@@' は locale 等の予約 key。
      bool isMessage(String k) => !k.startsWith('@');

      final jaKeys = ja.keys.where(isMessage).toSet();
      final enKeys = en.keys.where(isMessage).toSet();

      expect(jaKeys.difference(enKeys), isEmpty,
          reason: 'app_en.arb に未翻訳の key があります');
      expect(enKeys.difference(jaKeys), isEmpty,
          reason: 'app_ja.arb に存在しない key が app_en.arb にあります '
              '(typo か、ja 側の削除漏れ)');
    });

    test('en 側の値に日本語が残っていない', () {
      final en = readArb('lib/l10n/app_en.arb');

      final untranslated = <String>[];
      en.forEach((k, v) {
        if (k.startsWith('@')) return;
        if (_endonymKeys.contains(k)) return;
        if (v is String && _japanese.hasMatch(v)) {
          untranslated.add('$k: $v');
        }
      });

      expect(untranslated, isEmpty,
          reason: 'app_en.arb に日本語が残っています (翻訳漏れ):\n'
              '${untranslated.join('\n')}\n'
              '言語選択の選択肢のように「意図的にその言語自身で表記する」key は '
              '_endonymKeys に理由付きで追加してください。');
    });

    test('en 側の値が空でない', () {
      final empty = <String>[];
      readArb('lib/l10n/app_en.arb').forEach((k, v) {
        if (k.startsWith('@')) return;
        if (v is String && v.trim().isEmpty) empty.add(k);
      });
      expect(empty, isEmpty,
          reason: 'app_en.arb の値が空です。gen-l10n は通りますが画面が無表示に'
              'なります: ${empty.join(', ')}');
    });

    test('ja と en が完全一致していない (訳し忘れて日本語をコピーした痕跡)', () {
      final ja = readArb('lib/l10n/app_ja.arb');
      final en = readArb('lib/l10n/app_en.arb');

      final identical = <String>[];
      en.forEach((k, v) {
        if (k.startsWith('@')) return;
        if (_jaEnIdenticalAllowlist.contains(k)) return;
        if (v is String && ja[k] == v) identical.add('$k: $v');
      });

      expect(
        identical,
        isEmpty,
        reason: 'ja と en が同一文字列です。翻訳せずに日本語をコピーした'
            '可能性があります。固有名詞 / placeholder のみ / 言語自身の表記など'
            '「一致が正しい」key は _jaEnIdenticalAllowlist に追加してください: '
            '${identical.join(", ")}',
      );
    });

    test('ja の全 message key に @description がある', () {
      final ja = readArb('lib/l10n/app_ja.arb');

      final missing = ja.keys
          .where((k) => !k.startsWith('@'))
          .where((k) => !ja.containsKey('@$k'))
          .toList();

      expect(missing, isEmpty,
          reason: 'app_ja.arb の以下の key に @description がありません。\n'
              'Phase 3 の native reviewer は description を頼りに文脈を判断するため必須です '
              '(lib/l10n/README.md §2.3):\n'
              '${missing.join(', ')}');
    });
  });

  test('D: Accept-Language は端末 locale ではなくアプリ解決 locale を送る', () {
    // 【FEAT-489 Phase 2E / Pre-mortem S5】
    // 端末 locale を送ると、UI は BUG-27 対策で ja 固定なのに Backend だけ英語を
    // 返し、1 画面に 2 言語が混在する。regression を source レベルで止める。
    // コメント行は落とす。禁止語は「使うな」と注意書きする側にも出てくるため
    // (実際この判定を書いた当日に自分のコメントで自爆した)。
    final src = File('lib/core/api/api_client.dart')
        .readAsStringSync()
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .map(_stripLineComment)
        .join('\n');

    expect(
      src.contains("options.headers['Accept-Language']"),
      isTrue,
      reason: 'Accept-Language の付与が消えています。Backend の I18nMiddleware に '
          'locale が届かず、Phase 4 の _en field が到達不能に戻ります',
    );
    expect(
      src.contains('ServiceL10n.current.localeName'),
      isTrue,
      reason: 'Accept-Language はアプリが解決した locale '
          '(ServiceL10n.current.localeName) を送ること',
    );
    for (final banned in const [
      'Platform.localeName',
      'window.locale',
      'platformDispatcher.locale',
    ]) {
      expect(src.contains(banned), isFalse,
          reason: '端末 locale ($banned) を Accept-Language に使わないこと '
              '(Pre-mortem S5: 画面内の言語混在)');
    }
  });

  test('E: IAP 価格は storefront 由来で、通貨記号の hardcode がない', () {
    // 【FEAT-514】
    // 2026-07-05 hotfix は「日本 App Store のみで販売する」前提で、通貨コードが
    // JPY 以外のとき package.identifier から日本円固定価格を返していた。v1.1 で
    // 英語圏 storefront を開くと実ユーザーがこの経路に落ち、**Apple は現地通貨で
    // 課金するのに画面には日本円**という価格の誤表示になる。
    //
    // 「storefront を増やすたびに固定価格が復活する」再発を source レベルで止める。
    // check D と同じく **コメント行は落としてから**判定する (Pre-mortem S4:
    // 経緯を説明するコメント内の通貨記号で恒常 red になるのを防ぐ)。
    const path = 'lib/features/shop/pages/diamond_pack_page.dart';
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '$path が見つかりません');
    final raw = file.readAsStringSync();

    final offenders = <String>[];
    final lines = raw.split('\n');
    // コメントを落としたコード部分のみ (check D と同じ前処理)。
    // _stripLineComment は行単位の関数なので、必ず行ごとに適用してから join する。
    final code = lines
        .where((l) => !l.trimLeft().startsWith('//'))
        .map(_stripLineComment)
        .join('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('//')) continue;
      final lineCode = _stripLineComment(line);
      for (final m in _stringLiteral.allMatches(lineCode)) {
        final literal = m.group(0)!;
        if (_currencyHardcode.hasMatch(literal)) {
          offenders.add('$path:${i + 1}  $literal');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '購入画面に通貨記号のリテラルが混入しています。\n'
          '価格は Apple / Google が storefront ごとに解決した '
          'storeProduct.priceString をそのまま表示すること '
          '(FEAT-514 §2.1)。\n'
          '${offenders.join('\n')}',
    );

    // 逆方向の担保: ストア由来の価格を実際に使っていること。
    expect(
      raw.contains('storeProduct.priceString'),
      isTrue,
      reason: '価格表示が storeProduct.priceString を経由していません '
          '(FEAT-514 §2.1)',
    );

    // 固定価格が復活する経路は「通貨で分岐する」ことから始まる。分岐そのものを禁止し、
    // storefront が増えても表示ロジックが変わらないことを構造で保証する。
    expect(
      code.contains('currencyCode'),
      isFalse,
      reason: '通貨コードで表示を分岐させないこと。storefront ごとの通貨・桁区切り・'
          '税表記は既にストアが解決済みで、アプリ側の分岐は価格の誤表示を生む '
          '(FEAT-514 §2.1 / 2026-07-05 hotfix の回帰)',
    );
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// 日本語リテラル収集
// ─────────────────────────────────────────────────────────────────────────────

/// `lib/**/*.dart` から日本語を含む文字列リテラルを収集する。
///
/// 除外するもの (すべて「hardcode ではない」と判定できる根拠がある):
///   - `lib/l10n/` 配下 (ARB の生成物。ここに日本語があるのが正しい)
///   - `.g.dart` / `.freezed.dart` (build_runner 生成物)
///   - `//` で始まる行、および行末コメント
///   - raw string (`r'...'`) と `RegExp(...)` を含む行 — 日本語入力パーサのパターン
///   - `debugPrint` / `throw Exception` / `assert` — 開発者向けでユーザーに見えない
///   - [_apiEnumValues] と完全一致するリテラル — Backend の API 値そのもの
List<String> _collectJapaneseLiterals(Directory libDir) {
  final hits = <String>[];

  final files = libDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) {
        final p = f.path.replaceAll(r'\', '/');
        return !p.contains('/l10n/') &&
            !p.endsWith('.g.dart') &&
            !p.endsWith('.freezed.dart');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    final lines = file.readAsStringSync().split('\n');
    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      if (raw.trimLeft().startsWith('//')) continue;

      final code = _stripLineComment(raw);
      if (_regExpCall.hasMatch(code)) continue;
      if (_developerFacing.hasMatch(code)) continue;

      for (final m in _stringLiteral.allMatches(code)) {
        final literal = m.group(0)!;
        if (literal.startsWith('r')) continue; // raw string = パーサパターン
        if (!_japanese.hasMatch(literal)) continue;

        final inner =
            literal.length >= 2 ? literal.substring(1, literal.length - 1) : '';
        if (_apiEnumValues.contains(inner)) continue;

        final path = file.path.replaceAll(r'\', '/');
        hits.add('$path:${i + 1}  $literal');
      }
    }
  }
  return hits;
}

/// 文字列リテラルの外側にある `//` 以降を落とす。
///
/// `final x = 'a'; // FEAT-169: '今日' or '今月'` のように、**コメント内の
/// 引用符**を拾ってしまうのを防ぐ (develop.md §Phase 2C 知見 1 の false positive)。
String _stripLineComment(String line) {
  String? inString;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (inString != null) {
      if (c == r'\') {
        i++;
        continue;
      }
      if (c == inString) inString = null;
    } else if (c == "'" || c == '"') {
      inString = c;
    } else if (c == '/' && i + 1 < line.length && line[i + 1] == '/') {
      return line.substring(0, i);
    }
  }
  return line;
}
