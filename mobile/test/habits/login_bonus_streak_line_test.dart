// 【FEAT-539 (2026-09-05)】ログインボーナスの「連続日数（累計日数）」行。
//
// ## 🔴 このテストが 3 状態すべてを踏む理由
//
// 表示は 2 状態ではなく **3 状態**である。
//
// | 状態 | 判定 | 表示 |
// |---|---|---|
// | 真の初日 | `total_days == 1` | **行を出さない** |
// | **連続が途切れた翌日** | `streak_days == 1 && total_days > 1` | **累計だけ** |
// | 通常 | `streak_days > 1` | 連続 + 累計 |
//
// 実装者が「**初日だけ出さない**」と読み違えると、真ん中の分岐が丸ごと落ちる。
// そのとき、昨日まで 38 日続けていた人に「**1 日連続**」と出る ——
// CLAUDE.md の「停滞も休息も肯定する」「無理に高く積もうとしなくていいんです」
// というサビの使命と正面から衝突する形である。
// **落ちても他の 2 状態は緑のまま通る**ので、ここで明示的に踏む。
//
// 🔵 3 状態の判定に Backend のフラグは使っていない。
//    「連続 1 なのに累計が 2 以上」は「昨日は達成していないが、過去に達成した
//    日がある」と同値だからである。この同値性が崩れていないことも、
//    ここが唯一の見張り番になる。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/features/habits/widgets/login_bonus_calendar_dialog.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

/// Backend `today_login_bonus` の最小形。既存キーは常に付ける。
Map<String, dynamic> _bonus({int? streakDays, int? totalDays}) => {
      'amount': 20,
      'days_count': 40,
      'granted_daily_tickets': 0,
      'granted_weekly_tickets': 0,
      if (streakDays != null) 'streak_days': streakDays,
      if (totalDays != null) 'total_days': totalDays,
    };

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> bonus, {
  Locale locale = const Locale('ja'),
}) async {
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: LoginBonusCalendarDialog(bonus: bonus)),
  ));
  await tester.pump(const Duration(milliseconds: 800));
}

final _streakLine = find.byKey(const Key('login_bonus_streak_line'));

void main() {
  group('FEAT-539 連続日数（累計日数）の 3 状態', () {
    testWidgets('① 真の初日は行を出さない', (tester) async {
      await _pump(tester, _bonus(streakDays: 1, totalDays: 1));
      expect(_streakLine, findsNothing);
    });

    testWidgets('② 連続が途切れた翌日は「累計だけ」出す', (tester) async {
      // 昨日まで 38 日続いていた人が 1 日空けた翌日。
      // 🔴 ここで「1 日連続」と出してはいけない。
      await _pump(tester, _bonus(streakDays: 1, totalDays: 39));
      expect(_streakLine, findsOneWidget);
      expect(find.text('累計 39 日'), findsOneWidget);
      expect(find.textContaining('連続'), findsNothing);
    });

    testWidgets('③ 通常は連続 + 累計を出す', (tester) async {
      await _pump(tester, _bonus(streakDays: 12, totalDays: 40));
      expect(_streakLine, findsOneWidget);
      expect(find.text('12 日連続（累計 40 日）'), findsOneWidget);
    });
  });

  group('FEAT-539 古い Backend / 欠損値', () {
    testWidgets('streak_days が無ければ行を描画しない', (tester) async {
      // 古い Backend がキーを返さない期間がある。`?? 0` で 0 に潰すと
      // 「0 日連続」という嘘が出るので、**行ごと出さない**。
      await _pump(tester, _bonus(totalDays: 40));
      expect(_streakLine, findsNothing);
    });

    testWidgets('total_days が無ければ行を描画しない', (tester) async {
      await _pump(tester, _bonus(streakDays: 12));
      expect(_streakLine, findsNothing);
    });

    testWidgets('両方無くても落ちない (既存の報酬表示は出る)', (tester) async {
      await _pump(tester, _bonus());
      expect(_streakLine, findsNothing);
      expect(find.text('+20'), findsOneWidget);
    });
  });

  group('FEAT-539 英語 (FEAT-489 の launch 対象)', () {
    testWidgets('英語の語順が自然であること', (tester) async {
      // ⚠️ 日本語の直訳 ("12 days consecutive (total 40 days)") にしない。
      await _pump(
        tester,
        _bonus(streakDays: 12, totalDays: 40),
        locale: const Locale('en'),
      );
      expect(find.text('12-day streak (40 days total)'), findsOneWidget);
    });

    testWidgets('途切れた翌日も英語で累計だけ', (tester) async {
      await _pump(
        tester,
        _bonus(streakDays: 1, totalDays: 39),
        locale: const Locale('en'),
      );
      expect(find.text('39 days total'), findsOneWidget);
      expect(find.textContaining('streak'), findsNothing);
    });
  });

  group('FEAT-539 既存表示を壊していない', () {
    testWidgets('報酬とチケットは従来どおり出る', (tester) async {
      await _pump(tester, {
        'amount': 500,
        'days_count': 1,
        'granted_daily_tickets': 3,
        'granted_weekly_tickets': 3,
        'streak_days': 1,
        'total_days': 1,
      });
      expect(find.text('+500'), findsOneWidget);
      expect(find.text('デイリー × 3'), findsOneWidget);
      expect(find.text('ウィークリー × 3'), findsOneWidget);
      // Day 1 なので連続行は出ない
      expect(_streakLine, findsNothing);
    });
  });
}
