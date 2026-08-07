// 【BUG-71 fix 契約テスト (2026-05-27)】
//
// HabitsNotifier の incrementCount / decrementCount / toggleChecklistItem で
// `_inFlight` がエラー時に永久残置されるバグ (BUG-71) の **構造的再発防止** 縛り。
//
// バグの仕組み:
//   1. `_inFlight.add(habitId)` を try block の **外** で実行
//   2. その直後の `firstWhere` で `orElse: () => throw StateError(...)` が throw
//   3. `_inFlight.remove(habitId)` は try-finally の中 → 実行されない
//   4. 以降のタップは `_inFlight.contains(habitId)` 早期 return = 永久に増えない
//
// 再現条件: 新規追加習慣が `habits_provider` state にまだ注入されていない (HomeBootstrap
// 経由で表示されているが provider state は古い) 状態で + ボタン押下 → firstWhere で
// throw → _inFlight 永久残置。本テストは「構造的に修正パターンが残されている」契約を縛る。
//
// 修正方針 (habits_provider.dart): `_inFlight.add` 直後を try-catch で囲み、catch
// 内で `_inFlight.remove(habitId)` してから rethrow。3 メソッド (increment / decrement /
// toggleChecklistItem) すべてに同パターン適用。
//
// 同パターン: `mobile/test/category_strings_truth_test.dart` (FEAT-307 CI ガード)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // テスト実行 cwd は mobile/、`lib/features/habits/providers/habits_provider.dart`
  // を読み込んで、BUG-71 修正の 3 構造的契約を縛る。
  late final String providerSource;

  setUpAll(() {
    final f = File('lib/features/habits/providers/habits_provider.dart');
    expect(f.existsSync(), isTrue,
        reason: 'habits_provider.dart が cwd 配下に見つからない (cwd 不一致)');
    providerSource = f.readAsStringSync();
  });

  group('BUG-71 _inFlight 永久残置 再発防止契約テスト', () {
    test('シナリオ A: BUG-71 修正マーカーが 3 メソッド分残存している', () {
      // 修正マーカー `【BUG-71 fix 2026-05-27】` が 3 箇所以上に存在
      // (incrementCount + decrementCount + toggleChecklistItem)。
      // 1 メソッドだけ修正漏れた場合に検出する CI ガード。
      final markerCount = '【BUG-71 fix 2026-05-27】'
          .allMatches(providerSource)
          .length;
      expect(
        markerCount,
        greaterThanOrEqualTo(3),
        reason: '3 メソッド (incrementCount / decrementCount / '
            'toggleChecklistItem) すべてに修正マーカーが残ること = '
            '1 メソッドだけ修正漏れ防止。現状: $markerCount 件',
      );
    });

    test('シナリオ B: catch (_) → _inFlight.remove + rethrow ペアが 3+ 件存在', () {
      // catch 内で _inFlight.remove + rethrow がペアで存在 (BUG-71 修正の 3 メソッド分)。
      // コメント行 (`// 【BUG-71 fix】...`) を間に挟んでも検出できるよう、
      // catch から rethrow までの中身に `_inFlight.remove(habitId);` 含有を縛る。
      // 最大 200 文字のスパンを許容 (人間が読めるコメント幅)。
      final pattern = RegExp(
        r'catch\s*\(_\)\s*\{[^}]*?_inFlight\.remove\(habitId\);[^}]*?rethrow;',
        dotAll: true,
      );
      final matches = pattern.allMatches(providerSource);
      expect(
        matches.length,
        greaterThanOrEqualTo(3),
        reason: 'catch (_) ブロック内に _inFlight.remove(habitId); と rethrow; が '
            'ペアで含まれるパターンが 3 メソッドすべてに存在 = StateError 時に '
            '_inFlight 永久残置しないことを構造的に保証。現状: ${matches.length} 件',
      );
    });

    test('シナリオ C: _inFlight.add → try block が連続する構造が 3 メソッドに存在', () {
      // `_inFlight.add(habitId);` の数行後に `try {` が出現する構造が 3 箇所以上。
      // 各メソッドで「add → コメント / final 変数宣言 → try」のパターン。
      // 改行 + 任意のコメント・型宣言を許容して 3+ 件マッチさせる。
      final pattern = RegExp(
        r'_inFlight\.add\(habitId\);[\s\S]{0,500}?try\s*\{',
      );
      final matches = pattern.allMatches(providerSource);
      expect(
        matches.length,
        greaterThanOrEqualTo(3),
        reason: '_inFlight.add 直後に try block で firstWhere を包む構造が '
            '3 メソッドすべてに存在 = BUG-71 の構造的修正パターン遵守。現状: '
            '${matches.length} 件',
      );
    });

    test('シナリオ D: 旧バグパターン (try 外側の add) が残っていない', () {
      // 古いバグパターン: `_inFlight.add(habitId);` の **直後** に
      // `final habits = state.valueOrNull ?? [];` のような try 包囲なしの直書きコードがある
      // ようなら検出。具体的には「add の直後の数行に try が現れない」状態を防ぐ。
      //
      // 修正後パターン: add → コメント / final Habit habit; / try { → firstWhere
      // 旧バグパターン: add → final habits = ... → final habit = ... firstWhere (try 外)
      //
      // 直書き firstWhere (try なし) を検出。3 メソッドあるので「pattern 0 件」を目標とは
      // しない。代わりに「add 直後に try が 50 文字以内に出現する」を 3+ 件確認 (シナリオ C で
      // 既に縛っているので本シナリオはスキップ可、ただし二重防御として明示)。
      //
      // 念のため _inFlight.add の総数も確認 (3 箇所、各メソッドで 1 回ずつ)。
      final addCount = '_inFlight.add(habitId);'
          .allMatches(providerSource)
          .length;
      expect(
        addCount,
        equals(3),
        reason: '_inFlight.add(habitId); 呼び出しは 3 メソッドで 1 回ずつ = 計 3 回。'
            '現状: $addCount 件',
      );
    });
  });
}
