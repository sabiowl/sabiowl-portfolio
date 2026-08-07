import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 【FEAT-206 / FEAT-219】サビ口調の退行を防ぐ CI ガード。
///
/// `mobile/lib/` 配下の Dart ファイルに、CLAUDE.md「サビの口調ルール」で禁止された
/// 表現が含まれていないかを検査する。違反があるとテスト失敗 → CI ブロック。
///
/// 検査ロジック:
/// 1. **完全一致**（`forbiddenPatterns`）: FEAT-206 由来。語句単位で禁止
/// 2. **正規表現**（`forbiddenRegex`）: FEAT-219 で追加。文末「〜よ」/「〜しよう」/「〜したい」
///    の接尾パターンを検出。**文字列リテラル（`'...'` / `"..."` 内）のみ対象**にして
///    コメント・識別子の偽陽性を抑制。`〜ますよ` / `〜ですよ`（CLAUDE.md で許容）は
///    lookbehind で除外。直後に hiragana/katakana/kanji が続くケース（`いいよね` 等）も
///    lookahead で除外。
///
/// 例外的に許容したいファイルは `allowedExceptions`（パス部分一致）に追加してください。
///
/// 実行方法:
/// ```powershell
/// cd mobile
/// flutter test test/sabi_tone_test.dart
/// ```
void main() {
  group('サビ口調ガード（FEAT-206 / FEAT-219）', () {
    // ── 既存: 完全一致禁止語句（FEAT-206 から維持）──────────────────
    const forbiddenPatterns = <String, String>{
      // ── 老人口調（CLAUDE.md 禁止）─────────────────────────────────
      'じゃよ':    '老人口調「じゃよ」は禁止。「ですよ」等の紳士的トーンへ',
      'じゃのう':  '老人口調「じゃのう」は禁止',
      'なのじゃ':  '老人口調「なのじゃ」は禁止',
      'ですぞ':    '老人口調「ですぞ」は禁止',
      'お主':      '老人口調「お主」は禁止。「あなた」へ',
      'ワシ':      '老人口調「ワシ」は禁止。一人称は省略 or 「私」',

      // ── 少年口調・カジュアル過剰（CLAUDE.md 禁止）─────────────────
      'やったね':  '少年口調「やったね」は禁止。「素晴らしいですね」等へ',

      // ── 第三者視点（サビ本人の声で書く）────────────────────────
      'サビが再挑戦': '第三者視点「サビが〜」は禁止。サビ本人の声で書く',
    };

    // ── 【FEAT-219 新規】文字列リテラル内のみを対象にした正規表現禁止 ──
    //
    // 文字列リテラルは Dart のソースコード上で `'...'` または `"..."` で囲まれる。
    // コメント文や識別子・関数名は対象外にすることで偽陽性を抑制する。
    //
    // 設計判断:
    // - 文末「〜よ」: `(?<!ます)(?<!です)(?<!ました)(?<!でした)` で
    //   `〜ますよ` / `〜ですよ` / `〜ましたよ` / `〜でしたよ` の許容形を除外。
    //   敬体過去形「〜ましたよ / 〜でしたよ」は CLAUDE.md「〜ますよ / 〜ですよ」許容の
    //   自然な延長として紳士的トーン扱い（FEAT-265 hotfix で追加、2026-05-21）。
    //   直後に hiragana/katakana/kanji が続くケース（`いいよね` `今日もよろしく` 等）も
    //   negative lookahead `(?![ぁ-んァ-ヴ一-龯])` で除外。
    // - 「〜しよう」/「〜したい」: `し(よう|たい)` 限定。`〜ましょう`（小文字 `ょ`）は
    //   別文字なのでマッチしない。`〜したいのです` のように直後に hiragana が続けば
    //   許容（lookahead で除外）。
    final forbiddenRegex = <RegExp, String>{
      // 文末「〜よ」: ひらがな/カタカナ語幹に直接「よ」が付く少年口調。
      // 例（検出）: `'ないよ。'` `'ないよ'` `'いるよ\n'` `'たよ✉️'`
      // 例（除外）: `'ますよ'` `'ですよ'` `'ましたよ'` `'でしたよ'`（許容）/ `'いいよね'`（後ろがひらがな）
      //
      // 【FEAT-265 hotfix】2026-05-21: 敬体過去形「〜ましたよ / 〜でしたよ」も許容に追加。
      // CLAUDE.md「〜ますよ / 〜ですよ」の自然な延長として、敬体過去形も紳士的トーン扱い。
      //
      // `[^'"\n]*` で改行をまたぐ greedy match を抑制（コメント文を誤検出しないため）。
      // Dart の通常文字列リテラルは 1 行内で閉じる（複数行は `'''...'''` か `\n` escape）。
      RegExp(r"""['"][^'"\n]*[ぁ-んァ-ヴ]+(?<!ます)(?<!です)(?<!ました)(?<!でした)よ(?![ぁ-んァ-ヴ一-龯])"""):
          '少年口調「〜よ」(文末)は禁止。「〜ですね」「〜ますよ」「〜ましたよ」等の紳士的トーンへ',

      // volitional 「〜しよう」 / desiderative 「〜したい」
      // 例（検出）: `'勉強しよう！'` `'追加したい？'` `'交換しよう'`
      // 例（除外）: `'ましょう'`（別文字）/ `'お届けしたいのです'`（直後ひらがな）
      RegExp(r"""['"][^'"\n]*し(よう|たい)(?![ぁ-んァ-ヴ一-龯])"""):
          '少年口調(volitional / desiderative)は禁止。「〜してみてはいかがでしょうか」「〜しましょう」等へ',

      // 【FEAT-231 v2】一般 volitional「〜よう」（し 前置なし）の検出。
      // FEAT-219 の `し(よう|たい)` regex は `はじめよう` `集めよう` 等を見逃していた。
      // negative lookbehind で「でしょう」「ましょう」「いきましょう」（紳士的）を許容、
      // negative lookahead で `〜ようか` `〜ようね`（疑問形、紳士的）を許容。
      // 後置条件 `[！。']` で「文末 / 文区切り / 引用符閉じ」に限定し、文中の
      // `〜ようです` `〜ように` 等の誤検出を排除。
      // 例（検出）: `'はじめよう！'` `'集めよう'` `'頑張ろう。'`（ろうは別文字なので未対象）
      // 例（除外）: `'でしょう。'` `'参りましょう。'` `'いきましょうか'` `'ようです'`
      RegExp(r"""['"][^'"\n]*(?<!で)(?<!まし)(?<!きまし)(?<!し)よう(?![うかね])[！。']"""):
          '少年口調(general volitional 〜よう)は禁止。「〜しましょう」「〜してみましょう」等の紳士的トーンへ',

      // 【FEAT-231 v2】🪶 マーカー付き文字列の「！」検出。
      // CLAUDE.md「サビ台詞で「！」は禁止」明示違反。🪶 マーカーは「サビが寄り添っている
      // サイン」のため、！ との共存は CLAUDE.md「絵文字: システム文末尾に「🪶」のみ可」と矛盾。
      // 順序を両方カバー（！...🪶 と 🪶...！）+ 全角 ! と半角 ! の両方をカバー。
      RegExp(r"""['"][^'"\n]*！[^'"\n]*🪶[^'"\n]*['"]"""):
          'サビ台詞（🪶 マーカー付き）で「！」は禁止。「。」または「〜ですね。」等の穏やかな確信形へ',
      RegExp(r"""['"][^'"\n]*🪶[^'"\n]*![^'"\n]*['"]"""):
          'サビ台詞（🪶 マーカー付き）で「！」は禁止。「。」または「〜ですね。」等の穏やかな確信形へ',
    };

    // 例外的に許容するファイル（パス部分一致でファイル全体をスキップ）。
    // 主にユーザー入力例・サンプル文を保持しているファイルに使う（サビ本人の声ではないため）。
    // 【SEC-11】FEAT-219 で追加した sabi_navigation_overlay.dart / sabi_text_input_sheet.dart
    // は SabiNavigate(LLM) 完全廃止に伴いファイル自体が消滅したため除外も不要に。
    const allowedExceptions = <String>{};

    test('lib/ 配下に禁止口調が含まれていない', () {
      final libDir = Directory('lib');
      expect(
        libDir.existsSync(),
        isTrue,
        reason: 'mobile/lib/ ディレクトリが見つかりません。'
            'プロジェクトルート（mobile/）から `flutter test test/sabi_tone_test.dart` を実行してください。',
      );

      // パスセパレータを `/` に正規化してから判定（Windows: `\` → `/`）
      String normalizePath(String p) => p.replaceAll('\\', '/');

      final dartFiles = libDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          // 自動生成ファイルは検査対象外
          .where((f) =>
              !f.path.endsWith('.g.dart') &&
              !f.path.endsWith('.freezed.dart'))
          .toList();

      final allViolations = <String>[];

      for (final file in dartFiles) {
        final normalizedPath = normalizePath(file.path);
        final isAllowed = allowedExceptions
            .any((ex) => normalizedPath.contains(ex));
        if (isAllowed) continue;

        final content = file.readAsStringSync();

        // ── 1. 完全一致検査（従来 / FEAT-206）────────────────────
        for (final entry in forbiddenPatterns.entries) {
          if (content.contains(entry.key)) {
            allViolations.add('  - ${file.path}: "${entry.key}" → ${entry.value}');
          }
        }

        // ── 2. 正規表現検査（FEAT-219 新規 / 文字列リテラル内のみ）─
        for (final entry in forbiddenRegex.entries) {
          final matches = entry.key.allMatches(content);
          for (final m in matches) {
            // マッチ全体は文字列リテラルを含むため、最後の 20 文字程度を表示
            final raw = m.group(0)!;
            final preview = raw.length > 30
                ? '...${raw.substring(raw.length - 30)}'
                : raw;
            allViolations.add(
              '  - ${file.path}: "$preview" → ${entry.value}',
            );
          }
        }
      }

      expect(
        allViolations,
        isEmpty,
        reason:
            '【FEAT-206 / FEAT-219】サビ口調 CI ガードで違反検出:\n${allViolations.join('\n')}\n\n'
            'CLAUDE.md「サビの口調ルール」に従って紳士的トーンへ修正してください。\n'
            'ユーザー入力サンプル等の文芸的例外は `allowedExceptions` にファイルパスを追加可能です。',
      );
    });
  });
}
