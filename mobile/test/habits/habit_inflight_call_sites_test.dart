// 【FEAT-533 (2026-08-25)】`HabitsNotifier._inFlight[habitId]` を共有する
// 3 メソッド（`incrementCount` / `decrementCount` / `toggleChecklistItem`）の
// **呼び出し元すべて**が、guard に落とされたタップで祝わないことの契約テスト。
//
// ## なぜ「呼び出し元の一覧」を縛るのか
//
// FEAT-532 は `habit_card.dart` の ＋ / ✓ を直したが、
// **同じ defect が 3 経路に残っていた**（ゲームプレイレビュー 20260824 §8-3）:
//
//   - `todo_section.dart`      … 触覚だけ鳴って何も起きない（§2-1 と同じ嘘が隣のカードで）
//   - `habit_detail_page.dart` … **サビの成功文言が出る**（触覚の嘘より質が悪い）
//   - `habit_card.dart` の合流点 … `_actionInFlight` と `_toggling` が相互に素通り
//
// 原因はレビューの指示範囲（`habit_card.dart` 1 ファイル）で、実装ではない。
// **同じ穴は「呼び出し元が増えたとき」にまた開く**ので、
// 個別の振る舞いではなく **呼び出し元の集合そのもの**を縛る。
//
// 新しい画面から `incrementCount` を呼ぶと A-1 が red になり、
// 実装者は「3 点セットを当ててから allowlist に足す」ことになる。
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/habits/habit_inflight_call_sites_test.dart
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `_inFlight` を共有する 3 メソッド。
const _guardedMethods = [
  'incrementCount',
  'decrementCount',
  'toggleChecklistItem',
];

/// 🔴 **ここに足す前に、その画面へ 3 点セットを当てること。**
///
///   ① 往復中はタップを受け付けない（`onTap: null` 等）
///   ② 触覚は guard の**内側**でだけ鳴らす
///   ③ 成功文言 / トーストは戻り値が `true` のときだけ出す
///
/// 定義側（`habits_provider.dart`）と HTTP 層（`habits_service.dart`）は
/// 呼び出し元ではないので対象外。
const _knownCallSites = <String>{
  'lib/features/habits/widgets/habit_card.dart',
  'lib/features/habits/widgets/todo_section.dart',
  'lib/features/habits/pages/habit_detail_page.dart',
};

/// 定義側 / HTTP 層。呼び出し元ではない。
const _definitionSites = <String>{
  'lib/features/habits/providers/habits_provider.dart',
  'lib/features/habits/services/habits_service.dart',
  'lib/features/habits/models/habit.dart',
};

/// 行コメント / ブロックコメントを落とす。
/// コメント中の言及（`// habits_provider.incrementCount と同等` 等）を
/// 呼び出しと数えないため。
String _stripComments(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return noBlock
      .split('\n')
      .map((line) {
        final i = line.indexOf('//');
        return i >= 0 ? line.substring(0, i) : line;
      })
      .join('\n');
}

String _read(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue, reason: '$path が見つからない (cwd 不一致?)');
  return f.readAsStringSync();
}

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  // A: 呼び出し元の集合そのもの
  // ───────────────────────────────────────────────────────────────────────────
  group('A: _inFlight を共有する 3 メソッドの呼び出し元', () {
    test('A-1: 呼び出し元は既知の 3 ファイルだけである', () {
      final found = <String>{};

      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final rel = entity.path.replaceAll(r'\', '/');
        if (_definitionSites.contains(rel)) continue;

        final src = _stripComments(entity.readAsStringSync());
        // `habitsNotifierProvider` 経由でのみ `_inFlight` を通る。
        // (`habitsServiceProvider` 直呼びは BUG-56 の documented 経路で、
        //  そちらは `_inFlight` を通らない = 本テストの対象外)
        if (!src.contains('habitsNotifierProvider')) continue;
        if (!_guardedMethods.any((m) => src.contains('.$m('))) continue;

        found.add(rel);
      }

      expect(
        found,
        _knownCallSites,
        reason: '🔴 `_inFlight` を共有するメソッドの呼び出し元が増減した。\n'
            '足す場合は、その画面に 3 点セット '
            '(①往復中はタップを受け付けない ②触覚は guard の内側 '
            '③成功文言は戻り値が true のときだけ) を当ててから '
            '`_knownCallSites` に追記すること。\n'
            'ゲームプレイレビュー 20260824 §8-3 —— FEAT-532 は 1 ファイルだけを直し、'
            '同じ defect が 3 経路に残った。 '
            '⚠️ 探索は `habitsNotifierProvider` の文字列を持つファイルに限定している。'
            'notifier をコンストラクタ引数 / 関数引数として受け渡す書き方を始めたら、'
            'そのファイルは走査から外れるので **この探索条件を見直すこと** '
            '(2026-08-26 時点でそうした書き方はリポジトリに 1 件も無い、§9-6)。',
      );
    });

    test('A-2: 3 メソッドは「実際に送ったか」を bool で返す', () {
      final src = _stripComments(
          _read('lib/features/habits/providers/habits_provider.dart'));

      for (final m in _guardedMethods) {
        expect(src, contains('Future<bool> $m('),
            reason: '$m が bool を返さないと、呼び出し元は '
                '「guard に落とされた」ことを知る手段が無い');
      }
      expect(
        'return false; // 二重送信ガード'.allMatches(src).length,
        0,
        reason: 'コメントは除去済みなので、次の expect で素の形を数える',
      );
      expect(
        RegExp(r'if \(_inFlight\.contains\(habitId\)\) return false;')
            .allMatches(src)
            .length,
        _guardedMethods.length,
        reason: '3 メソッドすべてが guard で false を返すこと。'
            '1 つでも void のままだと、その経路だけ静かに嘘をつく',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // B: 各呼び出し元が実際に守っているか
  // ───────────────────────────────────────────────────────────────────────────
  group('B: 呼び出し元ごとの守り', () {
    test('B-1: todo_section —— 触覚は送信フラグの内側', () {
      final src =
          _stripComments(_read('lib/features/habits/widgets/todo_section.dart'));
      final handler = src.substring(src.indexOf('Future<void> _handleTap()'));
      final body = handler.substring(0, handler.indexOf('\n  }'));

      final guardIdx = body.indexOf('if (_sending) return;');
      final hapticIdx = body.indexOf('HapticFeedback.lightImpact()');
      expect(guardIdx, greaterThanOrEqualTo(0), reason: '送信中 guard が必要');
      expect(hapticIdx, greaterThan(guardIdx),
          reason: '🔴 guard より前で鳴らすと、捨てられるタップでも振動する '
              '(FEAT-532 で habit_card を直したのと同じ嘘)');
      expect(body, contains('finally {'),
          reason: '解放漏れは BUG-71 と同型。ボタンが永久に無反応になる');
      expect(body, contains('habitCardNetworkErrorSabi_message'),
          reason: '🔴 §9-5 —— `HabitsNotifier` の catch は rollback するだけで '
              'ユーザーに何も言わない。ここで出さないと、同じホーム画面で '
              '習慣カードは謝るのに ToDo カードだけ無言で元に戻る');
    });

    test('B-2: habit_detail_page —— 送れていない回はサビが祝わない', () {
      final src = _stripComments(
          _read('lib/features/habits/pages/habit_detail_page.dart'));

      final callIdx = src.indexOf('.incrementCount(habit.id, l10n: l10n)');
      final sentIdx = src.indexOf('if (!sent) return;', callIdx);
      final msgIdx = src.indexOf('habitDetailPageRecordSabi_message1', callIdx);

      expect(callIdx, greaterThanOrEqualTo(0));
      expect(sentIdx, greaterThan(callIdx),
          reason: '戻り値を見ずに SnackBar を出してはいけない');
      expect(msgIdx, greaterThan(sentIdx),
          reason: '🔴 「今日の積み重ねが、世界のどこかで幸運の種になりました。」を'
              '何も記録せずに言わせない。触覚の嘘より質が悪い —— '
              'サビの口を借りた嘘だからである');
    });

    test('B-3: habit_card —— 2 つの守り手が同じ対象を守っている', () {
      final src =
          _stripComments(_read('lib/features/habits/widgets/habit_card.dart'));

      expect(src, contains('_actionInFlight || _toggling.isNotEmpty'),
          reason: '🔴 ＋ / ✓ 側が項目タイルの往復を見ないと、'
              'そちらの飛行中に触覚がまた嘘をつく');
      expect(src, contains('isToggling || _actionInFlight'),
          reason: '🔴 項目タイル側が ✓ の往復を見ないと、楽観的にチェックが付いたまま '
              'toggleChecklistItem が早期 return し (throw しないので catch に入らない)、'
              '「チェックは付いているがサーバーには何も無い」状態が残る');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // C: docstring に数字を書き戻さない (§8-4)
  // ───────────────────────────────────────────────────────────────────────────
  group('C: KO 演出の長さは BattleConstants だけが持つ', () {
    test('C-1: ko_effect_overlay の表が定数を指している', () {
      final src = _read('lib/features/battle/widgets/ko_effect_overlay.dart');
      final head = src.substring(0, src.indexOf('class '));

      expect(head, contains('[BattleConstants.koLabelDuration]'),
          reason: '長さは定数参照で書くこと。数字は腐るが参照は腐らない');
      expect(head, contains('[BattleConstants.koTotalDuration]'));
      // 「以前 650ms と書いていた」という経緯の記述は残してよいので、
      // 表の中に生の ms が復活していないことだけを見る。
      final table =
          head.split('| 区間 | 長さ | 中身 |').last.split('画面シェイク').first;
      expect(RegExp(r'\d+ms').hasMatch(table), isFalse,
          reason: '🔴 表に生の数値を書き戻さないこと。'
              'ゲームプレイレビュー 20260824 のレビュアーは、この表の古い数字を'
              '引用して本文に誤りを出している (§8-4)');
    });
  });
}
