// 【BUG-73 (2026-05-27) / FEAT-520 (2026-08-06)】habit_card._periodCount() の
// structural CI guard。
//
// ## 縛っているのは「日数を回数バッジに出すな」であって「今日の回数だけ出せ」ではない
//
// BUG-73 真因: `_periodCount()` が `period_progress != null` のとき `pp.done`
// (期間内達成**日数**) を返していたため、daily + monthly のような
// `frequency != reset_cycle` の組み合わせで「+ を 3 回押しても +1 のまま」という
// UX バグが発生していた。日数は 1 日に何回押しても増えないため。
// 当時の修正は `todayCount` への一本化。
//
// FEAT-520: その一本化により `reset_cycle` が **何も制御しない設定**として残った
// (バッジは常に今日の回数)。ユーザー報告「リセットが毎週なら 1 週間の回数は
// 蓄積したままにしてほしい」を受け、`habit.periodCount`
// (= `reset_cycle` 期間内の **回数の合計**) に差し替えた。
//
// **`pp.done` と `periodCount` は名前が似ていて中身が違う。**
//
//   pp.done     … 期間内に達成した「日数」 → + を 3 回押しても 1 のまま (BUG-73)
//   periodCount … 期間内の count の合計    → + を 3 回押せば 3 増える (FEAT-520)
//
// したがって BUG-73 の禁止対象は `pp.done` のみで、`periodCount` は禁止されていない。
// ここを取り違えて「FEAT-520 は BUG-73 の巻き戻し」と解釈し、シナリオ B ごと
// 削除すると BUG-73 がそのまま再発する。
//
// 本テストはコードレベルで以下 3 構造を縛る:
//   - `_periodCount()` 内に `return habit.periodCount;` が存在  (FEAT-520)
//   - `_periodCount()` 内に旧バグパターン `return pp.done;` が **存在しない** (BUG-73)
//   - BUG-73 / FEAT-520 の経緯マーカーが habit_card.dart に存在
//
// 同パターン: `mobile/test/category_strings_truth_test.dart` (FEAT-307) +
// `mobile/test/habits/habit_increment_inflight_test.dart` (BUG-71)。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late final String habitCardSource;

  setUpAll(() {
    final f = File('lib/features/habits/widgets/habit_card.dart');
    expect(f.existsSync(), isTrue,
        reason: 'habit_card.dart が cwd 配下に見つからない (cwd 不一致)');
    habitCardSource = f.readAsStringSync();
  });

  group('_periodCount バッジ値の構造ガード (BUG-73 + FEAT-520)', () {
    test('シナリオ A: _periodCount() に return habit.periodCount; が存在', () {
      // メソッド本体内に「return habit.periodCount;」が含まれることを縛る。
      // _periodCount() のシグネチャから次の `}` までを抽出する正規表現。
      final pattern = RegExp(
        r'int\s+_periodCount\(\)\s*\{[\s\S]*?return\s+habit\.periodCount;',
      );
      expect(
        pattern.hasMatch(habitCardSource),
        isTrue,
        reason: '_periodCount() は count 型で habit.periodCount '
            '(= reset_cycle 期間内の回数合計) を返すこと (FEAT-520)。\n'
            'todayCount に戻すと reset_cycle が再び何も制御しない設定になり、'
            '「毎週リセットなら週内の回数を蓄積」というユーザー要件が消える。\n'
            'pp.done に戻すと BUG-73 (+ を押しても数字が増えない) が再発する。',
      );
    });

    test('シナリオ B: 旧バグパターン return pp.done; が _periodCount から撤去済', () {
      // _periodCount() メソッド全体 (シグネチャから対応する `}` まで) に
      // `return pp.done;` が含まれていないことを縛る。本パターンが復活すると
      // BUG-73 が即時再発する。
      //
      // 【FEAT-520】本シナリオは **維持する**。periodCount への差し替えは
      // 「回数合計」への変更であって、「日数」を戻す許可ではない。
      final methodMatch = RegExp(
        r'int\s+_periodCount\(\)\s*\{([\s\S]*?)^\s{2}\}',
        multiLine: true,
      ).firstMatch(habitCardSource);
      expect(methodMatch, isNotNull,
          reason: '_periodCount メソッドが見つからない、シグネチャが変わった?');
      final methodBody = methodMatch!.group(1) ?? '';
      expect(
        methodBody.contains('return pp.done;'),
        isFalse,
        reason: '旧バグパターン `return pp.done;` が _periodCount に復活している。'
            'pp.done は期間内の達成「日数」で、1 日に何回押しても増えない。'
            'daily+monthly 等で「カウントが増えない」UX バグ再発の構造原因、撤去必須。'
            '\nメソッド本体:\n$methodBody',
      );
    });

    test('シナリオ C: BUG-73 / FEAT-520 の経緯マーカーが habit_card.dart に残存', () {
      // 修正経緯の記録 (CLAUDE.md「dead code は削除、ただし意思決定経緯は残す」整合)。
      // 将来「なぜ _periodCount は periodCount を返すのか」「なぜ pp.done は禁止か」を
      // git blame せずに理解できる構造を保証。
      expect(
        habitCardSource.contains('【BUG-73 fix 2026-05-27】'),
        isTrue,
        reason: 'BUG-73 修正マーカーが habit_card.dart に存在すること = '
            '修正経緯の追跡可能性を保証。マーカーを削除する場合は git history で'
            '経緯参照が前提条件',
      );
      expect(
        habitCardSource.contains('【FEAT-520 2026-08-06】'),
        isTrue,
        reason: 'FEAT-520 マーカーが存在すること。pp.done (日数) と '
            'periodCount (回数合計) の違いを説明した箇所であり、'
            'これが消えると次の実装者が同じ取り違えをする',
      );
    });
  });
}
