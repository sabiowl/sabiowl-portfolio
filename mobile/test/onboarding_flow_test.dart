// 【FEAT-512 (2026-07-30)】チュートリアル flow 図 widget テスト。
//
// テスト一覧:
//   T01: SabiHabitOnboardingFlow — 3 ステップと CTA ボタンが描画される
//   T02: SabiHabitOnboardingFlow — onAddHabit コールバックが発火する
//   T03: SabiGuildOnboardingFlow — 3 ステップが描画される
//   T04: SabiGachaOnboardingFlow — 3 ステップとサビ口調テキストが描画される
//   T05: SabiChallengeOnboardingFlow — Bronze/Silver/Gold leaf が描画される
//   T06: SabiStatsOnboardingFlow — 3 stat leaf (運動力/学習力/精神力) が描画される
//   T07: SabiFlowBox — icon と label が描画される
//   T08: SabiFlowArrow — 描画されるがサイズ 0 以上
//   T09: SabiFlowLeaf — circular chip が描画される
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

import 'package:sabiowl/features/habits/widgets/sabi_habit_onboarding_flow.dart';
import 'package:sabiowl/features/guild/widgets/sabi_guild_onboarding_flow.dart';
import 'package:sabiowl/features/gamification/widgets/sabi_gacha_onboarding_flow.dart';
import 'package:sabiowl/features/challenge/widgets/sabi_challenge_onboarding_flow.dart';
import 'package:sabiowl/features/gamification/widgets/sabi_stats_onboarding_flow.dart';
import 'package:sabiowl/shared/widgets/sabi_flow_diagram.dart';

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(
        locale: const Locale('ja'),
        localizationsDelegates: [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('ja'), Locale('en')],
        theme: ThemeData.dark(),
        home: Scaffold(body: child),
      ),
    );

// ─────────────────────────────────────────────────────────────────────────────
// T01: SabiHabitOnboardingFlow renders 3 steps + CTA
// ─────────────────────────────────────────────────────────────────────────────
void main() {
  testWidgets('T01: SabiHabitOnboardingFlow renders 3 steps and CTA', (tester) async {
    await tester.pumpWidget(_wrap(
      SabiHabitOnboardingFlow(onAddHabit: () {}),
    ));
    await tester.pump();

    expect(find.text('① カテゴリを選ぶ'), findsOneWidget);
    expect(find.text('② 続ける'), findsOneWidget);
    expect(find.text('③ 積み重ねる'), findsOneWidget);
    expect(find.text('最初の習慣を始める'), findsOneWidget);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // T02: SabiHabitOnboardingFlow — onAddHabit fires on tap
  // ─────────────────────────────────────────────────────────────────────────
  testWidgets('T02: SabiHabitOnboardingFlow onAddHabit fires', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_wrap(
      SabiHabitOnboardingFlow(onAddHabit: () => tapped = true),
    ));
    await tester.pump();

    await tester.tap(find.text('最初の習慣を始める'));
    expect(tapped, isTrue);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // T03: SabiGuildOnboardingFlow renders 3 steps
  // ─────────────────────────────────────────────────────────────────────────
  testWidgets('T03: SabiGuildOnboardingFlow renders 3 steps', (tester) async {
    await tester.pumpWidget(_wrap(const SabiGuildOnboardingFlow()));
    await tester.pump();

    expect(find.text('① 敵を選ぶ'), findsOneWidget);
    expect(find.text('② 出陣する'), findsOneWidget);
    expect(find.text('③ 報酬を受け取る'), findsOneWidget);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // T04: SabiGachaOnboardingFlow renders steps + Sabi text
  // ─────────────────────────────────────────────────────────────────────────
  testWidgets('T04: SabiGachaOnboardingFlow renders steps and Sabi text', (tester) async {
    await tester.pumpWidget(_wrap(const SabiGachaOnboardingFlow()));
    await tester.pump();

    expect(find.text('① チケットで引く'), findsOneWidget);
    expect(find.text('② キャラを迎える'), findsOneWidget);
    expect(find.text('③ 一緒に戦う'), findsOneWidget);
    expect(find.textContaining('静かに祝いましょう'), findsOneWidget);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // T05: SabiChallengeOnboardingFlow renders Bronze/Silver/Gold leaves
  // ─────────────────────────────────────────────────────────────────────────
  testWidgets('T05: SabiChallengeOnboardingFlow renders 3 tier leaves', (tester) async {
    await tester.pumpWidget(_wrap(const SabiChallengeOnboardingFlow()));
    await tester.pump();

    expect(find.text('ブロンズ'), findsOneWidget);
    expect(find.text('シルバー'), findsOneWidget);
    expect(find.text('ゴールド'), findsOneWidget);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // T06: SabiStatsOnboardingFlow renders stat leaves
  // ─────────────────────────────────────────────────────────────────────────
  testWidgets('T06: SabiStatsOnboardingFlow renders stat leaves', (tester) async {
    await tester.pumpWidget(_wrap(const SabiStatsOnboardingFlow()));
    await tester.pump();

    expect(find.text('運動力'), findsOneWidget);
    expect(find.text('学習力'), findsOneWidget);
    expect(find.text('精神力'), findsOneWidget);
    expect(find.textContaining('6 つのステータス'), findsOneWidget);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // T07: SabiFlowBox renders icon and label
  // ─────────────────────────────────────────────────────────────────────────
  testWidgets('T07: SabiFlowBox renders icon and label', (tester) async {
    await tester.pumpWidget(_wrap(
      const SabiFlowBox(icon: '🌱', label: 'テストラベル'),
    ));
    await tester.pump();

    expect(find.text('🌱'), findsOneWidget);
    expect(find.text('テストラベル'), findsOneWidget);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // T08: SabiFlowArrow renders without overflow
  // ─────────────────────────────────────────────────────────────────────────
  testWidgets('T08: SabiFlowArrow renders without overflow', (tester) async {
    await tester.pumpWidget(_wrap(const Column(
      children: [SabiFlowArrow()],
    )));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(SabiFlowArrow), findsOneWidget);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // T09: SabiFlowLeaf renders circular chip
  // ─────────────────────────────────────────────────────────────────────────
  testWidgets('T09: SabiFlowLeaf renders icon and label', (tester) async {
    await tester.pumpWidget(_wrap(
      const SabiFlowLeaf(icon: '📚', label: '学習力'),
    ));
    await tester.pump();

    expect(find.text('📚'), findsOneWidget);
    expect(find.text('学習力'), findsOneWidget);
  });
}
