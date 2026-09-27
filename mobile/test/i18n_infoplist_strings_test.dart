// 【2026-08-09 / FEAT-489 Phase 5 (v1.1 G4)】iOS ネイティブ権限ダイアログの構造ガード。
//
// ## なぜ必要か
//
// 権限ダイアログ (NSSpeechRecognitionUsageDescription 等) は **iOS 自身が描画する**
// ため、**ARB では 1 文字も localize されない**。`i18n_coverage_test.dart` の check C
// (ja/en の ARB key 差分ゼロ) は緑のまま、英語ユーザーに日本語のシステムダイアログを
// 出すことができてしまう —— 既存の i18n ガードが構造的に届かない唯一の領域である。
//
// 実際 2026-08-09 に `CFBundleLocalizations` へ `en` を足した時点で、
// 3 つの UsageDescription は Info.plist に日本語直書きのままだった。
//
// ## 3 つの check
//
// - A: `CFBundleLocalizations` の**全 locale** に `<locale>.lproj/InfoPlist.strings`
//      が存在する (**列挙ではなく発見**。v2.0 で中国語 / 韓国語を足しても自動で効く)
// - B: 全 locale の key 集合が一致し、Info.plist の UsageDescription 群と過不足なく
//      対応する (片方だけ足す / 片方だけ消す を止める)
// - C: `ja` 以外の locale に日本語 (かな + CJK) が残っていない
//
// ## 設計メモ
//
// Info.plist 側の UsageDescription は **fallback として意図的に残してある**。
// InfoPlist.strings が何らかの理由で bundle に入らなくても、空ダイアログではなく
// 日本語の説明が出る。check B はその値が `ja.lproj` と一致することまでは見ない
// —— fallback が古くなっても実害が無い一方、一致を強制すると「Info.plist だけ直して
// テストが落ちる」摩擦の方が大きいため。**ずれて困るのは key であって値ではない。**
//
// 実行方法:
// ```powershell
// cd mobile; flutter test test/i18n_infoplist_strings_test.dart
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `ios/Runner/Info.plist` から `<key>` → 値を素朴に読む。
///
/// `plist` パッケージを足さずに済ませるための最小実装。対象は
/// `<string>` 単値と `<array><string>` のみで、本テストにはこれで足りる。
Map<String, dynamic> _readInfoPlist(File f) {
  final text = f.readAsStringSync();
  final result = <String, dynamic>{};
  final keyRe = RegExp(r'<key>([^<]+)</key>');
  for (final m in keyRe.allMatches(text)) {
    final key = m.group(1)!;
    final rest = text.substring(m.end);
    final arr = RegExp(r'^\s*<array>(.*?)</array>', dotAll: true).firstMatch(rest);
    final str = RegExp(r'^\s*<string>(.*?)</string>', dotAll: true).firstMatch(rest);
    // 直後に来た方を採用する (array と string のどちらが先に現れるか)
    if (arr != null && (str == null || arr.start < str.start)) {
      result[key] = RegExp(r'<string>(.*?)</string>', dotAll: true)
          .allMatches(arr.group(1)!)
          .map((e) => e.group(1)!)
          .toList();
    } else if (str != null) {
      result[key] = str.group(1)!;
    }
  }
  return result;
}

/// `.strings` を読む。`/* */` コメントを落として `"k" = "v";` を拾う。
Map<String, String> _readStrings(File f) {
  final body =
      f.readAsStringSync().replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final pairs = RegExp(r'"([^"]+)"\s*=\s*"([^"]*)"\s*;');
  final map = <String, String>{};
  for (final m in pairs.allMatches(body)) {
    map[m.group(1)!] = m.group(2)!;
  }
  // 対応付けから漏れた記述が無いこと (構文崩れの検出)
  final leftover = body.replaceAll(pairs, '').trim();
  expect(leftover, isEmpty,
      reason: '${f.path}: `"key" = "value";` として解析できない記述が残っている -> $leftover');
  return map;
}

void main() {
  late final Map<String, dynamic> infoPlist;
  late final List<String> locales;
  late final Set<String> usageKeys;
  late final Map<String, Map<String, String>> byLocale;

  setUpAll(() {
    final plistFile = File('ios/Runner/Info.plist');
    expect(plistFile.existsSync(), isTrue,
        reason: 'ios/Runner/Info.plist が見つからない (cwd 不一致)');
    infoPlist = _readInfoPlist(plistFile);

    locales = (infoPlist['CFBundleLocalizations'] as List).cast<String>();
    usageKeys = infoPlist.keys.where((k) => k.endsWith('UsageDescription')).toSet();

    byLocale = {
      for (final loc in locales)
        if (File('ios/Runner/$loc.lproj/InfoPlist.strings').existsSync())
          loc: _readStrings(File('ios/Runner/$loc.lproj/InfoPlist.strings')),
    };
  });

  group('check A: CFBundleLocalizations の全 locale に InfoPlist.strings がある', () {
    test('宣言した言語すべてに実体がある', () {
      // 【意図】locale を**列挙せず発見する**。v2.0 で言語を足したとき、
      // CFBundleLocalizations に 1 行足しただけで .lproj を忘れるとここで落ちる。
      expect(locales, isNotEmpty, reason: 'CFBundleLocalizations が空');
      final missing =
          locales.where((l) => !byLocale.containsKey(l)).toList()..sort();
      expect(
        missing,
        isEmpty,
        reason: 'CFBundleLocalizations に宣言があるのに '
            'ios/Runner/<locale>.lproj/InfoPlist.strings が無い: $missing\n'
            '宣言だけ足すと、その言語のユーザーに Info.plist の日本語が出る。',
      );
    });
  });

  group('check B: key 集合が locale 間で一致し、Info.plist と対応する', () {
    test('Info.plist の UsageDescription を全 locale が過不足なく持つ', () {
      expect(usageKeys, isNotEmpty,
          reason: 'Info.plist に UsageDescription が 1 件も無い (読み取り失敗の疑い)');
      for (final entry in byLocale.entries) {
        expect(
          entry.value.keys.toSet(),
          usageKeys,
          reason: '${entry.key}.lproj/InfoPlist.strings の key が Info.plist と食い違う。\n'
              '権限を足す / 消すときは Info.plist と全 locale を同時に直すこと。',
        );
      }
    });
  });

  group('check C: ja 以外に日本語が残っていない', () {
    test('en 等に かな / CJK が混入していない', () {
      final cjk = RegExp(r'[぀-ヿ一-鿿]');
      for (final entry in byLocale.entries) {
        if (entry.key == 'ja') continue;
        for (final kv in entry.value.entries) {
          expect(
            cjk.hasMatch(kv.value),
            isFalse,
            reason: '${entry.key}.lproj の ${kv.key} に日本語が残っている: "${kv.value}"',
          );
        }
      }
    });
  });
}
