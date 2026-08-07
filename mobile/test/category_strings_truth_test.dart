// 【FEAT-307】カテゴリ真実値 CI ガード
//
// migration 0066 で死語化された旧カテゴリリテラル ('メンタル' / '作業' / '交流')
// が mobile/lib 配下の **アクティブコード** に混入していないか、CI で検出する。
//
// FEAT-213 (11 値カテゴリ統一) で真実値が確定:
//   '運動', '学習', '仕事', '体力', '美容', '健康', '精神', '創造', '社交', '休息', 'その他'
//
// 旧死語:
//   'メンタル' → '精神'
//   '作業'   → '仕事'
//   '交流'   → '社交'
//
// 新たに死カテゴリリテラルが追加された瞬間に CI が落ちる = 構造的再発防止。
// コメント内の説明文 (// 'メンタル' は死語化済) は除外 (Pre-mortem #3 対応)。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no stale category literals in mobile/lib (FEAT-213 真実値ガード)',
      () async {
    // テスト実行ディレクトリは mobile/ (flutter test 実行時の cwd)。
    // lib/ 以下を再帰的に走査する。
    final dir = Directory('lib');
    expect(dir.existsSync(), isTrue,
        reason: 'mobile/lib ディレクトリが見つからない (cwd 不一致)');

    // 死語化済リテラル (シングルクオート + 文字列、Dart string literal 形式)
    const stale = <String>["'メンタル'", "'作業'", "'交流'"];

    final hits = <String>[];
    await for (final entity in dir.list(recursive: true)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.dart')) continue;

      final content = await entity.readAsString();
      for (final needle in stale) {
        if (_containsOutsideComments(content, needle)) {
          hits.add('${entity.path}: contains $needle');
        }
      }
    }

    expect(hits, isEmpty,
        reason: '死カテゴリリテラルが残存しています (FEAT-213 真実値違反):\n'
            '${hits.join('\n')}\n'
            'migration 0066 真実値: メンタル → 精神 / 作業 → 仕事 / 交流 → 社交');
  });
}

/// 簡易: `//` 以降の行末コメント / `///` doc comment は除外する。
///
/// `/* ... */` ブロックコメントは除外しない (本 FEAT 時点で全 stale が単行
/// 形式のため対象外で OK)。将来 false positive が出たら除外パターン拡張。
bool _containsOutsideComments(String content, String needle) {
  final lines = content.split('\n');
  for (final line in lines) {
    // `//` 位置を見つけて、それ以前 (= コード部分) のみを needle 検索対象とする。
    final commentIdx = line.indexOf('//');
    final codeLine = commentIdx >= 0 ? line.substring(0, commentIdx) : line;
    if (codeLine.contains(needle)) return true;
  }
  return false;
}
