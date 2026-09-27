// 【ゲームプレイレビュー 20260824 §4-1 #1 (2026-08-25)】
// カウント習慣の ＋ / チェックリスト習慣の ✓ が、**飛行中のタップを黙って捨てて
// いた**ことに対する契約テスト。
//
// 何が起きていたか:
//
//   tap 1 ─→ 🔔 lightImpact ─→ incrementCount ─→ _inFlight.add ─→ POST …(往復中)
//   tap 2 ─→ 🔔 lightImpact ─→ incrementCount ─→ return          ← 何も起きない
//   tap 3 ─→ 🔔 lightImpact ─→ incrementCount ─→ return          ← 何も起きない
//
// **振動は 3 回鳴り、数字は 1 しか増えない。** 触覚は人間がもっとも疑わない
// 感覚チャネルなので、「鳴った = 届いた」と身体が判断する。数字が追随しないと
// 「このアプリはカウントを取りこぼす」と学習する —— 実際には正しく 1 回入って
// いるのに、である。
//
// 🔴 `_inFlight` guard 自体は BUG-71 の構造修正として正しい。**間違っていたのは
// guard が働いたことを UI が一切伝えていなかったこと**で、本テストが縛るのも
// そこだけである。guard には触らない。
//
// 縛る 3 点:
//   A. 飛行中の 2 回目のタップで **触覚が鳴らない**（= 嘘をつかない）
//   B. 飛行中は **spinner が出る**（= 処理中が目に見える）/ 往復が終われば戻る
//   C. 解放が `finally` にある（`_inFlight` はまさにこの解放漏れで BUG-71 になった）
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/habits/habit_action_tap_feedback_test.dart
// ```

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/features/habits/models/habit.dart';
import 'package:sabiowl/features/habits/models/player.dart';
import 'package:sabiowl/features/habits/providers/habits_provider.dart';
import 'package:sabiowl/features/habits/widgets/habit_card.dart';
import 'package:sabiowl/features/habits/widgets/todo_section.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

Map<String, dynamic> _json({
  int id = 1,
  String habitType = 'count',
  int? todayCount,
}) =>
    <String, dynamic>{
      'id': id,
      'name': '水を飲む',
      'category': '健康',
      'frequency': 'daily',
      'reset_cycle': 'daily',
      'habit_type': habitType,
      'difficulty': 'normal',
      'priority': 'medium',
      'order': 0,
      'streak': 0,
      'best_streak': 0,
      'total_count': 0,
      'is_active': true,
      'memo': '',
      'is_public': true,
      'shield_active': false,
      'checklist_items': <dynamic>[],
      if (todayCount != null)
        'today_log': {'count': todayCount, 'exp_gained': 0},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> haptics;

  setUp(() {
    haptics = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add('${call.arguments}');
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpCard(WidgetTester tester, Habit habit) async {
    // 🔴 `Completer` は **testWidgets の本体の中**で作ること。`setUp` は
    // `fakeAsync` ゾーンの外で走るので、そこで作った Completer を complete しても
    // `tester.pump()` がマイクロタスクを流してくれず、await が再開しない
    // (症状: spinner が永久に消えないように見える)。
    _SlowHabitsNotifier.reset();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        playerNotifierProvider.overrideWith(_MockPlayerNotifier.new),
        habitsNotifierProvider.overrideWith(_SlowHabitsNotifier.new),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ja'),
        home: Scaffold(body: HabitCard(habit: habit)),
      ),
    ));
    await tester.pump();
  }

  // ───────────────────────────────────────────────────────────────────────────
  // A: 飛行中のタップは触覚で嘘をつかない
  // ───────────────────────────────────────────────────────────────────────────
  group('A: 飛行中のタップは触覚で嘘をつかない', () {
    testWidgets('A-1: ＋ の連打で、往復中の 2・3 回目は鳴らない', (tester) async {
      await pumpCard(tester, Habit.fromJson(_json()));

      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pump();

      expect(haptics.length, 1, reason: '1 回目は鳴る');
      expect(_SlowHabitsNotifier.incrementCalls, 1);

      // 往復中にもう 2 回叩く。押せない場所を叩いているので何も起きないのが正解。
      await tester.tap(find.byType(CircularProgressIndicator));
      await tester.pump();
      await tester.tap(find.byType(CircularProgressIndicator));
      await tester.pump();

      expect(haptics.length, 1,
          reason: '🔴 捨てられるタップで振動してはいけない '
              '(振動 3 回 / +1 だけ、が元の症状)');
      expect(_SlowHabitsNotifier.incrementCalls, 1);
    });

    testWidgets('A-2: 往復が終われば、次のタップはまた鳴る', (tester) async {
      await pumpCard(tester, Habit.fromJson(_json()));

      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pump();
      expect(haptics.length, 1);

      _SlowHabitsNotifier.gate.complete();
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pump();

      expect(haptics.length, 2, reason: '解放後は通常どおり反応する');
      expect(_SlowHabitsNotifier.incrementCalls, 2);
    });

    testWidgets('A-3: チェックリストの ✓ も同じ (レビューは ＋ しか挙げていない)',
        (tester) async {
      await pumpCard(tester, Habit.fromJson(_json(habitType: 'checklist')));

      await tester.tap(find.byIcon(Icons.check_circle_outline));
      await tester.pump();
      expect(haptics.length, 1);

      await tester.tap(find.byType(CircularProgressIndicator));
      await tester.pump();

      expect(haptics.length, 1,
          reason: '同じメソッドの 2 件目 —— ＋ だけ直して ✓ を残さないこと');
      expect(_SlowHabitsNotifier.incrementCalls, 1);
    });

    testWidgets('A-4: 達成済みの ✓ (decrementCount 経路) も同じ', (tester) async {
      await pumpCard(
          tester, Habit.fromJson(_json(habitType: 'checklist', todayCount: 1)));

      await tester.tap(find.byIcon(Icons.check_circle));
      await tester.pump();
      expect(haptics.length, 1);
      expect(_SlowHabitsNotifier.decrementCalls, 1);

      await tester.tap(find.byType(CircularProgressIndicator));
      await tester.pump();

      expect(haptics.length, 1);
      expect(_SlowHabitsNotifier.decrementCalls, 1);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // B: 処理中が目に見える
  // ───────────────────────────────────────────────────────────────────────────
  group('B: 処理中が目に見える', () {
    testWidgets('B-1: 往復中は spinner、終われば ＋ に戻る', (tester) async {
      await pumpCard(tester, Habit.fromJson(_json()));

      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: '落ちたタップを「落ちたと分かる形」にする');
      expect(find.byIcon(Icons.add_circle_outline), findsNothing);

      _SlowHabitsNotifier.gate.complete();
      await tester.pump();
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
    });

    testWidgets('B-2: タップ領域 (56px 幅) は spinner 中も縮まない', (tester) async {
      await pumpCard(tester, Habit.fromJson(_json()));

      final before = tester.getSize(find
          .ancestor(
            of: find.byIcon(Icons.add_circle_outline),
            matching: find.byType(SizedBox),
          )
          .last);

      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pump();

      final after = tester.getSize(find
          .ancestor(
            of: find.byType(CircularProgressIndicator),
            matching: find.byType(SizedBox),
          )
          .last);

      expect(after.width, before.width,
          reason: 'spinner にしたせいで押せる面積が変わってはいけない');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // D: ToDo カード (FEAT-533 §8-3、同じホーム画面の隣のカード)
  // ───────────────────────────────────────────────────────────────────────────
  group('D: ToDo カードも飛行中は鳴らない', () {
    Future<void> pumpTodoSection(WidgetTester tester) async {
      _SlowHabitsNotifier.reset();
      _SlowHabitsNotifier.habits = <Habit>[
        Habit.fromJson(_json(id: 7, habitType: 'todo')),
      ];

      await tester.pumpWidget(ProviderScope(
        overrides: [
          playerNotifierProvider.overrideWith(_MockPlayerNotifier.new),
          habitsNotifierProvider.overrideWith(_SlowHabitsNotifier.new),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('ja'),
          home: const Scaffold(body: SingleChildScrollView(child: TodoSection())),
        ),
      ));
      await tester.pump();
      await tester.pump();
    }

    /// ToDo カードの GestureDetector。`Text` 自体はスクロールビューの中で
    /// hit test に乗らないので、**ジェスチャを持つ祖先**を叩く。
    Finder todoCard() => find
        .ancestor(
          of: find.text('水を飲む'),
          matching: find.byType(GestureDetector),
        )
        .last;

    testWidgets('D-1: 往復中の 2・3 回目のタップは触覚を鳴らさない', (tester) async {
      await pumpTodoSection(tester);

      expect(find.text('水を飲む'), findsOneWidget, reason: 'ToDo カードが出ていない');

      final card = todoCard();
      await tester.tap(card);
      await tester.pump();

      expect(haptics.length, 1, reason: '1 回目は鳴る');
      expect(_SlowHabitsNotifier.incrementCalls, 1);

      await tester.tap(card);
      await tester.pump();
      await tester.tap(card);
      await tester.pump();

      expect(haptics.length, 1,
          reason: '🔴 FEAT-532 が habit_card で直したのと同じ嘘が、'
              '同じホーム画面の隣のカードで鳴っていた');
      expect(_SlowHabitsNotifier.incrementCalls, 1);
    });

    testWidgets('D-3: 通信に失敗したら、ToDo カードも黙らない', (tester) async {
      await pumpTodoSection(tester);
      _SlowHabitsNotifier.shouldThrow = true;

      await tester.tap(todoCard());
      await tester.pump();

      _SlowHabitsNotifier.gate.complete();
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('通信が滞って'),
        findsOneWidget,
        reason: '🔴 §9-5 —— `HabitsNotifier` の catch は rollback するだけで '
            '何も言わない。ここで出さないと、同じホーム画面で習慣カードは謝るのに '
            'ToDo カードだけ無言で元に戻る',
      );
    });

    testWidgets('D-2: 往復が終われば、次のタップはまた鳴る', (tester) async {
      await pumpTodoSection(tester);

      await tester.tap(todoCard());
      await tester.pump();
      expect(haptics.length, 1);

      _SlowHabitsNotifier.gate.complete();
      await tester.pump();
      await tester.pump();

      await tester.tap(todoCard());
      await tester.pump();

      expect(haptics.length, 2);
      expect(_SlowHabitsNotifier.incrementCalls, 2);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // C: フラグの解放が finally にある
  // ───────────────────────────────────────────────────────────────────────────
  group('C: フラグの解放が finally にある', () {
    String handlerBody() {
      final f = File('lib/features/habits/widgets/habit_card.dart');
      expect(f.existsSync(), isTrue, reason: 'cwd 不一致?');
      final src = f.readAsStringSync();
      final handler =
          src.substring(src.indexOf('Future<void> _handleCountAction'));
      return handler.substring(0, handler.indexOf('\n  }'));
    }

    test('C-1: _actionInFlight の解放が finally 節に書かれている', () {
      final body = handlerBody();

      expect(body, contains('finally {'),
          reason: '🔴 catch だけで解放すると、throw されない異常系でボタンが '
              '永久に spinner のまま固まる (BUG-71 と同型)');

      final finallyIdx = body.indexOf('finally {');
      final releaseIdx = body.indexOf('_actionInFlight = false');
      expect(releaseIdx, greaterThan(finallyIdx),
          reason: '解放は finally の中に置くこと');
    });

    test('C-2: 触覚は guard の内側で鳴らしている', () {
      final body = handlerBody();

      final guardIdx = body.indexOf('if (_actionInFlight) return;');
      final hapticIdx = body.indexOf('HapticFeedback.lightImpact()');
      expect(guardIdx, greaterThanOrEqualTo(0),
          reason: '早期 return の guard が必要');
      expect(hapticIdx, greaterThan(guardIdx),
          reason: '🔴 guard より前で鳴らすと、捨てられるタップでも振動する');
    });
  });
}

/// API を叩かず、往復を [gate] で止められる [HabitsNotifier]。
class _SlowHabitsNotifier extends HabitsNotifier {
  static late Completer<void> gate;
  static int incrementCalls = 0;
  static int decrementCalls = 0;

  /// `TodoSection` のように `habitsNotifierProvider` の state を読む widget 用。
  static List<Habit> habits = <Habit>[];

  /// 通信失敗の再現用。`gate` 解決後に throw する。
  static bool shouldThrow = false;

  static void reset() {
    gate = Completer<void>();
    incrementCalls = 0;
    decrementCalls = 0;
    habits = <Habit>[];
    shouldThrow = false;
  }

  @override
  Future<List<Habit>> build() async => habits;

  @override
  Future<bool> incrementCount(int habitId, {AppLocalizations? l10n}) async {
    incrementCalls++;
    await gate.future;
    if (shouldThrow) throw Exception('network');
    return true;
  }

  @override
  Future<bool> decrementCount(int habitId) async {
    decrementCalls++;
    await gate.future;
    return true;
  }
}

/// API を叩かない [PlayerNotifier]（`habit_period_semantics_test.dart` と同型）。
class _MockPlayerNotifier extends PlayerNotifier {
  @override
  Future<Player> build() async => const Player(
        id: 1,
        name: 'テストプレイヤー',
        gender: 'f',
        level: 2,
        currentExp: 0,
        maxExp: 200,
        allocatablePoints: 0,
        diamonds: 0,
        diamondsTotal: 0,
        friendId: 'TEST0001',
        dailyTickets: 0,
        weeklyTickets: 0,
        monthlyTickets: 0,
        reminderEnabled: false,
        mode: 'training',
        streakProtectionCount: 3,
      );
}
