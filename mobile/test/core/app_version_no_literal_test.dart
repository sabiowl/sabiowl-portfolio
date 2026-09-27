// 【BUG-151 (2026-09-02)】アプリのバージョンをリテラルで書くことを構造的に禁じる。
//
// ## なぜこのテストが要るか
//
// 発見時、バージョン表示が 2 箇所あり **片方だけが本物を読んでいた**:
//
//   ホームのドロワー   PackageInfo.fromPlatform()   → 1.1.1  ✅
//   設定 → アプリ情報  Text('1.0.0') のリテラル      → 1.0.0  ❌
//
// v1.0 → v1.1.0 → v1.1.1 のあいだ「片方だけ正しい」状態が続いていた。
// 2 画面を並べて見る機会が無いので誰も気付けなかった。
//
// 🔴 **`appVersionProvider` を作るだけでは再発を防げない。**
// 3 箇所目を足す人が、また `Text('1.1.2')` と書けてしまう。
// **止めるのは仕組みであって、注意書きではない。**
//
// ## 何を見ているか
//
// `lib/` 配下の Dart 文字列リテラルに、`x.y` / `x.y.z` 形式の
// **バージョンらしき値**が無いことを assert する。
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/core/app_version_no_literal_test.dart
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 失敗時に必ず出す文言。直し方まで書く。
const _howToFix = '\n'
    '───────────────────────────────────────────────────────────\n'
    'アプリのバージョンはリテラルで書かないでください。\n'
    '真実値は pubspec.yaml の `version:` です。\n'
    '\n'
    '  final version = ref.watch(appVersionProvider).valueOrNull;\n'
    '\n'
    '  (lib/core/providers/app_version_provider.dart)\n'
    '\n'
    'BUG-151: 設定画面が Text(\'1.0.0\') のリテラルだったため、\n'
    'v1.1.0 / v1.1.1 を出してもそこだけ 1.0.0 のまま残っていました。\n'
    '───────────────────────────────────────────────────────────';

/// バージョンらしき文字列リテラル。`'1.0.0'` / `"1.1"` / `'v1.1.2'` を拾う。
final _versionLiteral = RegExp(r'''(['"])v?\d+\.\d+(\.\d+)?\1''');

/// 🔵 バージョンではないと判断できるもの。**足すときは理由を書くこと。**
///
/// ここを安易に伸ばすと、このテストは何も見なくなる。
const _allowedContext = <String>[
  // ライブラリのバージョン制約や URL のパスセグメント等、
  // 「アプリのバージョン」ではない用途が出たらここに書く。
];

void main() {
  group('アプリのバージョンをリテラルで書かない (BUG-151)', () {
    late final List<File> dartFiles;

    setUpAll(() {
      final libDir = Directory('lib');
      expect(libDir.existsSync(), isTrue,
          reason: 'lib/ が cwd 配下に見つからない (mobile/ で実行すること)');
      dartFiles = libDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          // 自動生成物は対象外 (l10n は ARB 由来、.g.dart は build_runner 由来)。
          .where((f) => !f.path.endsWith('.g.dart'))
          .where((f) => !f.path.contains('${Platform.pathSeparator}l10n${Platform.pathSeparator}'))
          .toList();
    });

    test('A: lib/ にバージョンらしき文字列リテラルが無い', () {
      final offenders = <String>[];

      for (final file in dartFiles) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          // コメント行は対象外 (経緯の説明でバージョンを書くのは正当)。
          final trimmed = line.trimLeft();
          if (trimmed.startsWith('//') || trimmed.startsWith('///') ||
              trimmed.startsWith('*')) {
            continue;
          }
          if (_allowedContext.any(line.contains)) continue;
          final match = _versionLiteral.firstMatch(line);
          if (match != null) {
            offenders.add('${file.path}:${i + 1}  ${match.group(0)}');
          }
        }
      }

      expect(offenders, isEmpty,
          reason: 'バージョンらしきリテラルが残っています:\n'
              '${offenders.join('\n')}$_howToFix');
    });

    test('B: 🔴 空振り検出 —— 走査が実際にファイルを読んでいる', () {
      // A が「1 ファイルも読んでいない」状態でも緑になるのを防ぐ。
      // FEAT-536 では空振り検出が本体と別ロジックだったため、走査を潰しても
      // 両方緑のままだった。ここでは A と同じ dartFiles を見る。
      expect(dartFiles.length, greaterThan(100),
          reason: 'lib/ の Dart ファイルが少なすぎる。走査対象の収集が壊れている');

      // 正規表現が本当に版数を拾えることも確かめる (パターンの腐り検出)。
      expect(_versionLiteral.hasMatch("Text('1.0.0')"), isTrue);
      expect(_versionLiteral.hasMatch('const v = "1.1";'), isTrue);
      expect(_versionLiteral.hasMatch("label: 'v1.1.2'"), isTrue);
      // 版数でないものを拾わないことも確かめる (誤検知で allowlist が肥大化する)。
      expect(_versionLiteral.hasMatch("padding: 1.0"), isFalse);
      expect(_versionLiteral.hasMatch("opacity: 0.38"), isFalse);
    });

    test('C: appVersionProvider が pubspec を読む実装のままである', () {
      final f = File('lib/core/providers/app_version_provider.dart');
      expect(f.existsSync(), isTrue,
          reason: 'appVersionProvider が見つからない$_howToFix');
      final src = f.readAsStringSync();
      expect(src.contains('PackageInfo.fromPlatform()'), isTrue,
          reason: 'appVersionProvider が PackageInfo を読まなくなっている。'
              'ここを固定値にすると本テストは緑のまま嘘の版数を出す$_howToFix');
    });
  });
}
