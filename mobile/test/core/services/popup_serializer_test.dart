// 【FEAT-534 (2026-08-29)】PopupSerializer の順序と、Phase 1 の回帰ガード。
//
// ## 何が壊れていたか
//
// **A: 2 秒の無音が critical section の内側にあった。**
// `puzzle_piece_listener` は `PopupSerializer.enqueue` した task の**中**で
// 2 秒寝ていた。待たせたい相手はかけら overlay だけ (RewardToast 1.7s を先に
// 見せるため) なのに、**キューにいる全員が道連れで 2 秒待たされていた**。
//
// **B: 表示順が設計判断ではなかった。**
// FIFO なので「誰が先に enqueue を呼んだか」で決まる。かけらは `build` の同期
// パスで、他は `addPostFrameCallback` の中で enqueue するので、**かけらが
// 構造的に必ず先頭**になる。これは「かけらを最初に見せる」という判断の結果では
// なく、**片方が同期・片方が postFrame という実装差の副産物**だった。
//
// 結果として「ユーザーがタップした行為に対する報酬 (ログインボーナス)」より
// 「世界の副作用 (かけら)」が先に出ていた。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/core/services/popup_serializer.dart';

void main() {
  setUp(PopupSerializer.resetForTest);

  group('優先度', () {
    test('待機中の popup は優先度順に出る (enqueue 順ではない)', () async {
      final shown = <String>[];
      // 先に「世界の変化」(4) を積み、あとから「タップの直接の結果」(1) を積む。
      // FEAT-534 以前はこの順に出ていた = enqueue 順。
      final blocker = Completer<void>();
      // ダミーの先行 task でキューを占有し、その間に 2 件を積む。
      final first = PopupSerializer.enqueue(
        () => blocker.future,
        priority: PopupPriority.monthlyTicket,
      );
      final piece = PopupSerializer.enqueue(() async {
        shown.add('piece');
      }, priority: PopupPriority.puzzlePiece);
      final levelUp = PopupSerializer.enqueue(() async {
        shown.add('levelUp');
      }, priority: PopupPriority.levelUp);

      blocker.complete();
      await Future.wait([first, piece, levelUp]);

      expect(shown, ['levelUp', 'piece'],
          reason: 'あとから積まれた高優先度が、まだ表示していない低優先度を追い越すこと。');
    });

    test('同一優先度は FIFO を維持する', () async {
      final shown = <String>[];
      final blocker = Completer<void>();
      final first = PopupSerializer.enqueue(() => blocker.future,
          priority: PopupPriority.levelUp);
      final a = PopupSerializer.enqueue(() async => shown.add('a'),
          priority: PopupPriority.puzzlePiece);
      final b = PopupSerializer.enqueue(() async => shown.add('b'),
          priority: PopupPriority.puzzlePiece);
      final c = PopupSerializer.enqueue(() async => shown.add('c'),
          priority: PopupPriority.puzzlePiece);

      blocker.complete();
      await Future.wait([first, a, b, c]);

      expect(shown, ['a', 'b', 'c'],
          reason: '🔴 同一優先度の FIFO は既存の挙動。壊さないこと。');
    });

    test('優先度を渡さない popup は最後尾に回る', () async {
      final shown = <String>[];
      final blocker = Completer<void>();
      final first = PopupSerializer.enqueue(() => blocker.future,
          priority: PopupPriority.levelUp);
      final unranked = PopupSerializer.enqueue(() async => shown.add('unranked'));
      final gift = PopupSerializer.enqueue(() async => shown.add('gift'),
          priority: PopupPriority.friendGift);

      blocker.complete();
      await Future.wait([first, unranked, gift]);

      expect(shown, ['gift', 'unranked'],
          reason: '宣言し忘れた popup が黙って先頭に割り込むより、最後に回って'
              '「順序表に載せ忘れている」と気づけるほうがよい。');
    });

    test('🔴 表示中の popup は追い越されない', () async {
      // 「まだ出ていない popup どうし」の追い越しは意図した挙動だが、
      // **既に走り出した task を割り込ませてはいけない** (§6 の警告)。
      final events = <String>[];
      final running = Completer<void>();
      final release = Completer<void>();

      final lowPriorityRunning = PopupSerializer.enqueue(() async {
        events.add('low:start');
        running.complete();
        await release.future;
        events.add('low:end');
      }, priority: PopupPriority.friendGift);   // 5 = 最も後ろ

      await running.future;   // low が「表示中」になるまで待つ

      // 表示中に最優先の popup が来る。
      final highPriority = PopupSerializer.enqueue(() async {
        events.add('high');
      }, priority: PopupPriority.levelUp);      // 1 = 最優先

      // 追い越されていないこと = high はまだ走っていない。
      await Future<void>.delayed(Duration.zero);
      expect(events, ['low:start'],
          reason: '表示中の popup が高優先度に割り込まれている。');

      release.complete();
      await Future.wait([lowPriorityRunning, highPriority]);
      expect(events, ['low:start', 'low:end', 'high']);
    });
  });

  group('堅牢性 (既存の挙動を壊していないこと)', () {
    test('task が例外を投げても後続は出る', () async {
      final shown = <String>[];
      final failing = PopupSerializer.enqueue(() async {
        throw StateError('boom');
      }, priority: PopupPriority.levelUp);
      final next = PopupSerializer.enqueue(() async => shown.add('next'),
          priority: PopupPriority.loginBonus);

      await expectLater(failing, throwsStateError,
          reason: '例外は enqueue した本人に返ること。');
      await next;
      expect(shown, ['next'], reason: '1 つの popup の失敗で後続が止まらないこと。');
    });

    test('すべて捌けたらキューは空に戻る', () async {
      await PopupSerializer.enqueue(() async {});
      expect(PopupSerializer.waitingCount, 0);
      expect(PopupSerializer.isBusy, isFalse);
    });
  });

  group('🔴 Phase 1 の回帰ガード —— 2 秒の待機を task の中に戻さないこと', () {
    // §7.4。振る舞いテストではなくソース走査にしているのは、
    // 「キューを握ったまま寝ている」かどうかが **どこで待つか** の問題であって、
    // シリアライザ側からは観測できないため。task の中で寝れば必ず全員が待つ
    // (それがシリアライザの仕事) ので、シリアライザを直しても防げない。
    // 防げるのは「待つ場所を間違えない」ことだけである。
    const path = 'lib/features/puzzle_world/widgets/puzzle_piece_listener.dart';

    test('_kOverlayShowDelay の待機が enqueue より前にある', () {
      final lines = File(path).readAsLinesSync();
      final delayLines = <int>[];
      final enqueueLines = <int>[];
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (line.contains('Future.delayed(_kOverlayShowDelay)')) {
          delayLines.add(i + 1);
        }
        if (line.contains('PopupSerializer.enqueue(')) {
          enqueueLines.add(i + 1);
        }
      }

      expect(delayLines.length, 2,
          reason: 'task 経路と quest 経路の 2 箇所で待つ想定。'
              '見つかったのは $delayLines');
      expect(enqueueLines.length, 3,
          reason: 'task / quest / 完成モーダルの 3 経路。見つかったのは $enqueueLines');

      // 各 delay の**直後**の enqueue より前に居ること = enqueue の外で待っている。
      for (final delayLine in delayLines) {
        final enclosing = enqueueLines.where((e) => e < delayLine).length;
        final following = enqueueLines.where((e) => e > delayLine);
        expect(following, isNotEmpty,
            reason: '$path:$delayLine の待機のあとに enqueue が無い。');
        // 「直前の enqueue が閉じている」ことまでは静的には言えないので、
        // **delay が enqueue の引数ブロックの内側にインデントされていないか**を見る。
        final indent = lines[delayLine - 1].length -
            lines[delayLine - 1].trimLeft().length;
        expect(indent, lessThanOrEqualTo(6),
            reason: '''
$path:$delayLine の `Future.delayed(_kOverlayShowDelay)` が深くインデント
されている = `PopupSerializer.enqueue(() async { ... })` の**中**で寝ている。

🔴 task はキューを握っているので、待っているあいだ**他の popup 全員が道連れで
止まる**。待たせたい相手はかけら overlay だけなのに、LoginBonusCalendarDialog も
LevelUpDialog も 2 秒待たされる。間を置きたいなら enqueue する**前**に待つこと。
(参考: 手前にある enqueue の数 = $enclosing)''');
      }
    });

    test('⚠️ _kOverlayShowDelay の値は 2 秒のまま', () {
      // RewardToast の 1700ms と連動している。**本 FEAT で変えたのは置き場所だけ。**
      // 値を縮めると EXP トーストがかけら overlay に隠れる。
      final source = File(path).readAsStringSync();
      expect(source.contains('_kOverlayShowDelay = Duration(seconds: 2)'), isTrue,
          reason: '🔴 値を変えないこと。home_listeners.dart の RewardToast '
              '(1700ms) と連動しており、あちらにも連動注記がある。');
      final toast = File('lib/features/habits/pages/home_listeners.dart')
          .readAsStringSync();
      expect(toast.contains('milliseconds: 1700'), isTrue,
          reason: 'RewardToast の表示時間が変わった。'
              '_kOverlayShowDelay (2 秒) と連動して見直すこと。');
    });
  });
}
