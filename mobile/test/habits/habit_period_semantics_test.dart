// 【FEAT-520 (2026-08-06)】`reset_cycle` / `frequency` を実際に機能させる Flutter 側契約。
//
// 指示書 §6.3 の 2 点:
//   1. `Habit.fromJson` が `period_count` / `period_done` 欠落時に現行挙動へ落ちる
//   2. `frequency='weekly'` + `periodDone=true` + `todayCount=0` で
//      **カードは達成済み外観 / ボタンは未チェック** になる
//
// 2 番目が本 FEAT で最も壊れやすい箇所である (§5.4 / Pre-mortem #5):
// 「達成済みなんだからボタンも ✓ にすべきでは」と揃えたくなるが、Backend の
// `_apply_minus()` は今日の log が 0 なら `no_op` で何もしないため、揃えた瞬間に
// **週次習慣の翌日にボタンが無反応**になる。エラーも出ないので気付けない。
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/habits/habit_period_semantics_test.dart
// ```

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/features/habits/models/habit.dart';
import 'package:sabiowl/features/habits/models/player.dart';
import 'package:sabiowl/features/habits/providers/habits_provider.dart';
import 'package:sabiowl/features/habits/widgets/habit_card.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

/// Backend の habit 1 件分の JSON を組み立てる。
Map<String, dynamic> _json({
  int id = 1,
  String frequency = 'daily',
  String resetCycle = 'daily',
  String habitType = 'count',
  int? todayCount,
  int? periodCount,
  bool? periodDone,
  int streak = 0,
}) =>
    <String, dynamic>{
      'id': id,
      'name': 'ランニング',
      'category': '運動',
      'frequency': frequency,
      'reset_cycle': resetCycle,
      'habit_type': habitType,
      'difficulty': 'normal',
      'priority': 'medium',
      'order': 0,
      'streak': streak,
      'best_streak': 0,
      'total_count': 0,
      'is_active': true,
      'memo': '',
      'is_public': true,
      'shield_active': false,
      'checklist_items': <dynamic>[],
      if (todayCount != null)
        'today_log': {'count': todayCount, 'exp_gained': 0},
      if (periodCount != null) 'period_count': periodCount,
      if (periodDone != null) 'period_done': periodDone,
    };

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  // A: 旧 Backend へのフォールバック
  // ───────────────────────────────────────────────────────────────────────────
  group('A: fromJson のフォールバック (§5.1)', () {
    test('period_count / period_done が無ければ今日の値に落ちる', () {
      final h = Habit.fromJson(_json(todayCount: 3));

      expect(
        h.periodCount, 3,
        reason: '0 で潰すと、更新前の Backend に繋いだ瞬間にバッジが消える',
      );
      expect(
        h.periodDone, isTrue,
        reason: 'false で潰すと、完了済みの習慣が未完了に見える',
      );
    });

    test('today_log も無ければ 0 / false', () {
      final h = Habit.fromJson(_json());
      expect(h.periodCount, 0);
      expect(h.periodDone, isFalse);
    });

    test('新 Backend の値をそのまま採用する', () {
      final h = Habit.fromJson(_json(
        frequency: 'daily',
        resetCycle: 'weekly',
        todayCount: 0,
        periodCount: 5,
        periodDone: false,
      ));

      expect(h.periodCount, 5, reason: '今週の回数合計');
      expect(h.todayCount, 0);
      expect(
        h.periodDone, isFalse,
        reason: 'frequency=daily なので「今日やったか」が判定軸',
      );
    });

    test('period_count は 0 でも today_log にフォールバックしない', () {
      // `?? ` は null 合体なので 0 は素通りするはずだが、`if (x > 0)` のような
      // 書き方に変わると週明けのリセットが効かなくなる。
      final h = Habit.fromJson(_json(todayCount: 4, periodCount: 0));
      expect(h.periodCount, 0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // B: 完了の 2 概念
  // ───────────────────────────────────────────────────────────────────────────
  group('B: isCompletedToday と isCompletedInPeriod (§5.3 / §5.4)', () {
    test('週次習慣を月曜に達成 → 火曜は「期間内は完了 / 今日は未完了」', () {
      final h = Habit.fromJson(_json(
        frequency: 'weekly',
        resetCycle: 'weekly',
        periodCount: 1,
        periodDone: true,
      ));

      expect(h.isCompletedInPeriod, isTrue, reason: 'カードの外観はこちら');
      expect(
        h.isCompletedToday, isFalse,
        reason: '✓ / + / − ボタンはこちら。ここを periodDone に繋ぐと '
            '_apply_minus() の no_op を踏んでボタンが無反応になる (§5.4)',
      );
    });

    test('daily 習慣では 2 つが一致する (既存ユーザーの大多数は挙動不変)', () {
      final done = Habit.fromJson(_json(todayCount: 1, periodCount: 1, periodDone: true));
      expect(done.isCompletedToday, isTrue);
      expect(done.isCompletedInPeriod, isTrue);

      final notDone = Habit.fromJson(_json(periodCount: 0, periodDone: false));
      expect(notDone.isCompletedToday, isFalse);
      expect(notDone.isCompletedInPeriod, isFalse);
    });

    test('progress は periodProgress が無ければ期間完了で 1.0', () {
      final h = Habit.fromJson(_json(
        frequency: 'weekly', resetCycle: 'weekly',
        periodCount: 1, periodDone: true,
      ));
      expect(
        h.progress, 1.0,
        reason: 'weekly+weekly は period_progress が null なので、'
            'periodDone を見ないと週の途中で進捗 0 に戻る',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // C: 楽観的更新 — バッジが即座に動くこと
  // ───────────────────────────────────────────────────────────────────────────
  group('C: 楽観的更新 (BUG-73 の症状を再発させない)', () {
    test('+1 で periodCount も増える', () {
      final h = Habit.fromJson(_json(
        frequency: 'daily', resetCycle: 'weekly',
        todayCount: 0, periodCount: 4, periodDone: false,
      ));
      final next = h.optimisticIncrement();

      expect(
        next.periodCount, 5,
        reason: 'バッジは periodCount を表示する。ここを更新しないと '
            '「+ を押しても数字が増えない」= BUG-73 と同じ症状になる',
      );
      expect(next.todayCount, 1);
      expect(next.periodDone, isTrue, reason: '今日やった事実はどの期間窓にも入る');
    });

    test('-1 で periodCount も減る', () {
      final h = Habit.fromJson(_json(
        frequency: 'daily', resetCycle: 'weekly',
        todayCount: 1, periodCount: 5, periodDone: true,
      ));
      final next = h.optimisticDecrement();

      expect(next.periodCount, 4);
      expect(next.todayCount, 0);
      expect(
        next.periodDone, isFalse,
        reason: 'frequency=daily で今日が 0 になったので完了は外れる',
      );
    });

    test('週次 frequency では -1 しても periodDone を勝手に外さない', () {
      // 週の別の日に達成が残っている可能性をクライアントからは判定できない。
      // 次の refresh で Backend が正しい値を返す。
      final h = Habit.fromJson(_json(
        frequency: 'weekly', resetCycle: 'weekly',
        todayCount: 1, periodCount: 3, periodDone: true,
      ));
      final next = h.optimisticDecrement();

      expect(next.periodCount, 2);
      expect(next.periodDone, isTrue);
    });

    test('集計窓が空になれば periodDone も外れる', () {
      final h = Habit.fromJson(_json(
        frequency: 'weekly', resetCycle: 'weekly',
        todayCount: 1, periodCount: 1, periodDone: true,
      ));
      final next = h.optimisticDecrement();

      expect(next.periodCount, 0);
      expect(next.periodDone, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // D: カードの外観と操作系が分かれていること (§6.3-2)
  // ───────────────────────────────────────────────────────────────────────────
  group('D: HabitCard の外観 / 操作の分離', () {
    Future<void> pumpCard(WidgetTester tester, Habit habit) async {
      await tester.pumpWidget(ProviderScope(
        // HabitCard は shield ボタンのために playerNotifierProvider を watch する。
        // 実物のままだと API 取得の Timer が pending のまま tear down されるので、
        // 固定値を返す notifier に差し替える。
        overrides: [
          playerNotifierProvider.overrideWith(_MockPlayerNotifier.new),
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

    testWidgets(
        'weekly + periodDone=true + todayCount=0 → '
        '名前は取り消し線 / ✓ ボタンは未チェック', (tester) async {
      final habit = Habit.fromJson(_json(
        frequency: 'weekly',
        resetCycle: 'weekly',
        habitType: 'checklist',
        periodCount: 1,
        periodDone: true,
      ));

      await pumpCard(tester, habit);

      final nameStyle = tester
          .widgetList<AnimatedDefaultTextStyle>(
            find.ancestor(
              of: find.text('ランニング'),
              matching: find.byType(AnimatedDefaultTextStyle),
            ),
          )
          .first
          .style;
      expect(
        nameStyle.decoration, TextDecoration.lineThrough,
        reason: 'カードの外観は frequency 期間基準 (isCompletedInPeriod)。'
            '週次習慣は週内ずっと達成済みに見えるのがユーザー期待',
      );

      expect(
        find.byIcon(Icons.check_circle_outline), findsOneWidget,
        reason: '✓ ボタンは今日基準 (isCompletedToday) のまま。'
            'ここが Icons.check_circle になっていると decrementCount が呼ばれ、'
            '_apply_minus() の no_op でタップが無反応になる (§5.4)',
      );
      expect(find.byIcon(Icons.check_circle), findsNothing);
    });

    testWidgets('今日も達成していれば ✓ ボタンもチェック済みになる', (tester) async {
      final habit = Habit.fromJson(_json(
        frequency: 'weekly',
        resetCycle: 'weekly',
        habitType: 'checklist',
        todayCount: 1,
        periodCount: 1,
        periodDone: true,
      ));

      await pumpCard(tester, habit);

      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsNothing);
    });

    testWidgets('バッジは reset_cycle 期間内の回数合計を出す', (tester) async {
      final habit = Habit.fromJson(_json(
        frequency: 'daily',
        resetCycle: 'weekly',
        todayCount: 0,
        periodCount: 5,
        periodDone: false,
      ));

      await pumpCard(tester, habit);

      expect(
        find.text('+5'), findsOneWidget,
        reason: '今日は 0 回でも、今週の合計 5 回がバッジに出ること。'
            'これが本 FEAT のユーザー報告そのもの '
            '(「毎週リセットなら 1 週間の回数は蓄積したまま」)',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // E: ストリーク保護ボタンの表示条件 (FEAT-523 Phase 2 案 B)
  // ───────────────────────────────────────────────────────────────────────────
  group('E: ストリーク保護ボタンと periodDone (FEAT-523 案 B)', () {
    Future<void> pumpCard(WidgetTester tester, Habit habit) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          playerNotifierProvider.overrideWith(_MockPlayerNotifier.new),
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

    /// 保護ボタンの有無。`_StreakProtectButton` は private なので、
    /// 中で描かれる 🛡️ 絵文字の有無で判定する
    /// (`habit_card.dart` 内でこの絵文字を使うのは保護ボタンだけ)。
    bool shieldShown(WidgetTester tester) =>
        find.text('🛡️').evaluate().isNotEmpty;

    testWidgets('日次習慣・今日未達成 → 従来どおり表示される (案 B は no-op)',
        (tester) async {
      // 【実測の要点】daily では periodDone == (todayCount > 0) なので、
      // todayCount == 0 のとき periodDone は必ず false。
      // = 案 B を足しても既存ユーザーの大多数には 1 度も影響しない。
      await pumpCard(tester, Habit.fromJson(_json(
        frequency: 'daily', resetCycle: 'daily',
        streak: 7, periodCount: 0, periodDone: false,
      )));
      expect(
        shieldShown(tester), isTrue,
        reason: '日次習慣の保護導線が消えている。保護ボタンは「保護の予約」の'
            '唯一の入口なので、ここが消えると予約手段が無くなる',
      );
    });

    testWidgets('週次習慣・期間は達成済み・今日はまだ → 表示しない (案 B が効く 1 ケース)',
        (tester) async {
      await pumpCard(tester, Habit.fromJson(_json(
        frequency: 'weekly', resetCycle: 'weekly',
        streak: 7, periodCount: 1, periodDone: true,
      )));
      expect(
        shieldShown(tester), isFalse,
        reason: '期間の義務を果たしている習慣に「守りますか」と聞くのは '
            'FEAT-420 予約モードの趣旨 (途切れそうな時だけ静かに差し出す) と'
            '合っていない',
      );
    });

    testWidgets('週次習慣・期間も未達成 → 表示される', (tester) async {
      await pumpCard(tester, Habit.fromJson(_json(
        frequency: 'weekly', resetCycle: 'weekly',
        streak: 7, periodCount: 0, periodDone: false,
      )));
      expect(shieldShown(tester), isTrue,
          reason: '週次でも期間未達成なら従来どおり差し出す');
    });
  });
}

/// API を叩かない [PlayerNotifier]。実物は build() で HTTP を張るため、
/// widget テストで dispose 後に Timer が残る。
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
        // 【FEAT-523 Phase 2 案 B】保護ボタンの表示条件を満たす在庫を持たせる。
        // 在庫 0 だと group E が「案 B が効いた」のか「在庫が無い」のか
        // 区別できず、テストが空振りする。
        streakProtectionCount: 3,
      );
}
