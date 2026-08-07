// 【FEAT-466 (2026-06-24)】ChallengePage の widget test 4 シナリオ (指示書 §6-2 W1-W4)。
//
// 検証対象:
//   - W1: 累積 tier カード表示確認 (3 バッジ + 達成済 ✅ 1 つ + 未達 2 つ)
//   - W2: 非累積カード表示確認 (単一目標、3 バッジ非表示)
//   - W3: 詳細アイコン tap → AlertDialog 表示確認
//   - W4: 1 日 1 回ガード情報バナー表示確認
//
// `challengeListProvider` (FutureProvider.autoDispose) を `overrideWith` で
// 差し替え、ApiClient / Dio への実通信を発生させない (FEAT-465 widget test の
// 慣習を継承)。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/challenge/models/challenge.dart';
import 'package:sabiowl/features/challenge/pages/challenge_page.dart';
import 'package:sabiowl/features/challenge/providers/challenge_provider.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

const _infoText = '貢献回数は 1 日 1 人 1 回までカウントされます。'
    '焦らずとも、続けることが力になりますよ 🪶';

ChallengeEntry _tieredEntry() => const ChallengeEntry(
      id: 1,
      title: '7 月運動チャレンジ',
      description: 'みんなで運動習慣を達成しよう',
      category: '運動',
      isTiered: true,
      currentCount: 237,
      progressRate: 47,
      myContributionCount: 23,
      remainingDays: 14,
      startDate: '2026-07-01',
      endDate: '2026-07-31',
      tiers: {
        'bronze': TierInfo(target: 100, rewardExp: 100, achieved: true, remainingCount: 0),
        'silver': TierInfo(target: 250, rewardExp: 300, achieved: false, remainingCount: 13),
        'gold': TierInfo(target: 500, rewardExp: 1000, achieved: false, remainingCount: 263),
      },
    );

ChallengeEntry _flatEntry() => const ChallengeEntry(
      id: 2,
      title: '7 月学習チャレンジ (非累積)',
      description: '単一目標のチャレンジ',
      category: '学習',
      isTiered: false,
      currentCount: 120,
      progressRate: 40,
      myContributionCount: 5,
      remainingDays: 10,
      startDate: '2026-07-01',
      endDate: '2026-07-31',
      tiers: {
        'gold': TierInfo(target: 300, rewardExp: 1000, achieved: false, remainingCount: 180),
      },
    );

void main() {
  group('FEAT-466 ChallengePage 描画契約', () {
    testWidgets('W1: 累積 tier カードに 3 バッジ (達成済 1 + 未達 2) が表示される',
        (tester) async {
      final data = ChallengeListData(
        infoText: _infoText,
        active: [_tieredEntry()],
        pendingRewards: const [],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            challengeListProvider.overrideWith((ref) => Future.value(data)),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('ja'),
            home: ChallengePage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('7 月運動チャレンジ'), findsOneWidget);
      expect(find.textContaining('ブロンズ'), findsOneWidget);
      expect(find.textContaining('シルバー'), findsOneWidget);
      expect(find.textContaining('ゴールド'), findsOneWidget);
      expect(find.text('✅ 達成済み'), findsOneWidget, reason: 'ブロンズのみ達成済み');
      expect(find.text('あと 13 回'), findsOneWidget, reason: 'シルバー残り');
      expect(find.text('あと 263 回'), findsOneWidget, reason: 'ゴールド残り');
    });

    testWidgets('W2: 非累積カードは単一目標表示で 3 バッジが出ない', (tester) async {
      final data = ChallengeListData(
        infoText: _infoText,
        active: [_flatEntry()],
        pendingRewards: const [],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            challengeListProvider.overrideWith((ref) => Future.value(data)),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('ja'),
            home: ChallengePage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('7 月学習チャレンジ (非累積)'), findsOneWidget);
      expect(find.textContaining('ブロンズ'), findsNothing);
      expect(find.textContaining('シルバー'), findsNothing);
      expect(find.text('🥇 目標 G'), findsOneWidget, reason: '非累積は「目標」ラベルの単一バッジのみ');
    });

    testWidgets('W3: 詳細アイコン tap で AlertDialog が表示される', (tester) async {
      final data = ChallengeListData(
        infoText: _infoText,
        active: [_tieredEntry()],
        pendingRewards: const [],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            challengeListProvider.overrideWith((ref) => Future.value(data)),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('ja'),
            home: ChallengePage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(AlertDialog), findsNothing);

      // 【注意】画面上部の情報バナーにも Icons.info_outline (タップ不可の静的
      // Icon) があるため、カードの IconButton はツールチップで一意に特定する。
      await tester.tap(find.byTooltip('詳細を見る'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('📝 説明'), findsOneWidget);
      expect(find.textContaining('累積開放方式'), findsWidgets);
      expect(find.text('閉じる'), findsOneWidget);

      // BUG-65 規範: ポップアップ内に navigation はなく、閉じるのみで完結する。
      await tester.tap(find.text('閉じる'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('W4: 1 日 1 回ガード情報バナーが画面上部に表示される', (tester) async {
      final data = ChallengeListData(
        infoText: _infoText,
        active: [_tieredEntry()],
        pendingRewards: const [],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            challengeListProvider.overrideWith((ref) => Future.value(data)),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('ja'),
            home: ChallengePage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text(_infoText), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsWidgets);
    });
  });
}
