// 【FEAT-524 Phase 2 (2026-08-08)】POST が返した player を捨てないことの契約テスト。
//
// ## 何を守っているか
//
// `POST /habits/<id>/count/` のレスポンスには `PlayerProfileSerializer` の全体が
// 入っている (`habits.py:646`)。つまり**タップ直後の権威ある player は既に手元にある**。
// にもかかわらず旧実装は `level` だけ抜いて残りを捨て、直後の
// `_refreshRelated()` が `invalidate(playerNotifierProvider)` で
// **同じ player を GET /player/ で取り直して**いた
// (player は 1 タップにつき 3 回運ばれ、最初の 1 回が捨てられていた)。
//
// ## なぜソース走査なのか
//
// 「invalidate が走らないこと」は**起きなかった通信**なので、widget test では
// 「たまたま観測しなかっただけ」と区別がつきにくい。実装の分岐そのものを縛る。
// 同パターン: `habit_increment_inflight_test.dart` (BUG-71) /
// `category_strings_truth_test.dart` (FEAT-307)。
//
// ## Pre-mortem #4 / #5 をここで固定する
//
//   #4: player を返さない経路 (minus) は**従来どおり invalidate** に落ちること
//   #5: `ref.invalidate(habitsSummaryProvider)` の行は**残す** (削除は v1.2 送り)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late final String providerSource;
  late final String serviceSource;

  setUpAll(() {
    final p = File('lib/features/habits/providers/habits_provider.dart');
    final s = File('lib/features/habits/services/habits_service.dart');
    expect(p.existsSync(), isTrue, reason: 'habits_provider.dart が見つからない (cwd 不一致)');
    expect(s.existsSync(), isTrue, reason: 'habits_service.dart が見つからない (cwd 不一致)');
    providerSource = p.readAsStringSync();
    serviceSource = s.readAsStringSync();
  });

  group('FEAT-524 Phase 2: POST の player を注入する契約', () {
    test('A: _refreshRelated が Player? を受け取る', () {
      expect(
        RegExp(r'void\s+_refreshRelated\(\{\s*Player\?\s+player\s*\}\)')
            .hasMatch(providerSource),
        isTrue,
        reason: '_refreshRelated は `{Player? player}` を受ける形であること '
            '(player を持っている経路と持っていない経路を 1 箇所で分岐させる)',
      );
    });

    test('B: player 非 null は setFromBootstrap、null は invalidate に分岐する', () {
      // 【Pre-mortem #4】player を返さない経路を invalidate のまま残すのが要件。
      // 「注入だけ入れて else を書き忘れる」と minus 経路の更新が届かなくなる。
      final branch = RegExp(
        r'if\s*\(player\s*!=\s*null\)\s*\{[\s\S]{0,240}?'
        r'setFromBootstrap\(player\)[\s\S]{0,240}?'
        r'\}\s*else\s*\{[\s\S]{0,240}?'
        r'ref\.invalidate\(playerNotifierProvider\)',
      );
      expect(
        branch.hasMatch(providerSource),
        isTrue,
        reason: 'player があれば setFromBootstrap で注入し、無ければ従来どおり '
            'invalidate(playerNotifierProvider) にフォールバックすること',
      );
    });

    test('C: habitsSummaryProvider の invalidate は残っている (Pre-mortem #5)', () {
      // 誰も watch していない実質 no-op だが、削除は `/api/home/` の payload と
      // セットで判断すべきもので v1.2 送り。**「ついで」で消さない**ことを縛る。
      expect(
        providerSource.contains('ref.invalidate(habitsSummaryProvider);'),
        isTrue,
        reason: 'habitsSummaryProvider の invalidate 削除は v1.2 送り (指示書 §3)。'
            'FEAT-524 では残すこと',
      );
    });

    test('D: player を注入する経路は 2 つ (count +1 / checklist toggle)', () {
      final injected =
          RegExp(r'_refreshRelated\(player:\s*result\.player\)').allMatches(providerSource);
      expect(
        injected.length,
        2,
        reason: 'HabitLogResult を返す 2 経路 (incrementCount / toggleChecklistItem) '
            'が player を渡すこと。現状: ${injected.length} 件',
      );
    });

    test('E: minus 経路は引数なしの _refreshRelated() を保つ (Pre-mortem #4)', () {
      // decrementCount は Habit しか返さない = player を持ち帰らない経路。
      // ここに player を渡す形が現れたら、存在しない値を注入していることになる。
      expect(
        RegExp(r'_refreshRelated\(\);').hasMatch(providerSource),
        isTrue,
        reason: 'player を返さない write (minus) は引数なしで呼び、invalidate に落ちること',
      );
    });

    test('F: service が両経路で player を積んでいる', () {
      final parsed =
          RegExp(r'player:\s*_tryParsePlayer\(playerJson\)').allMatches(serviceSource);
      expect(
        parsed.length,
        2,
        reason: 'incrementCount と toggleChecklistItem の双方で '
            'HabitLogResult.player を組み立てること。現状: ${parsed.length} 件',
      );
    });

    test('G: player の parse 失敗はタップを失敗させない', () {
      // `Player.fromJson` は id 欠落で FormatException を投げる (BUG-K の防御)。
      // player の取り込みは最適化であって機能ではないので、失敗しても null に落として
      // invalidate 経路へ逃がす。ここが throw に変わると +1 自体が失敗しうる。
      final guarded = RegExp(
        r'Player\?\s+_tryParsePlayer\([\s\S]{0,400}?try\s*\{[\s\S]{0,200}?'
        r'Player\.fromJson\(json\)[\s\S]{0,200}?catch[\s\S]{0,120}?return\s+null;',
      );
      expect(
        guarded.hasMatch(serviceSource),
        isTrue,
        reason: '_tryParsePlayer は Player.fromJson を try/catch で包み、'
            '失敗時 null を返すこと (null なら呼び出し側が invalidate に落ちる)',
      );
    });
  });
}
