// 【FEAT-518 (2026-08-05)】ガチャ排出確率画面の UI 契約テスト。
//
// App Store Review Guideline 3.1.1 対応画面のため、「確率が実際に画面に出ている」
// ことを CI で締める。Backend 側の数値正当性は
// backend/api/tests/test_gacha_odds.py が担保しているので、
// 本テストは **表示経路が生きているか** に集中する。
//
// シナリオ:
//   1. 確率テーブルが表示される (ticket ラベル / 報酬名 / パーセント)
//   2. 同名・detail 違いの報酬が個別に表示される (Pre-mortem #3 の UI 側)
//   3. 小数第 2 位まで表示される (Weekly キャラ 0.50% が 0.5% や 1% に丸まらない)
//   4. 注記が表示される
//   5. 取得失敗時はサビ口調のエラーと再試行ボタンが出る

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/features/gamification/models/gamification_models.dart';
import 'package:sabiowl/features/gamification/pages/gacha_odds_page.dart';
import 'package:sabiowl/features/gamification/providers/gamification_provider.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

GachaOdds _mockOdds() => const GachaOdds(
      ticketTypes: [
        GachaOddsTicketType(
          ticketType: 'daily',
          label: 'デイリー',
          raritySummary: [
            GachaOddsRaritySummary(rarity: 'N', probability: 60.0),
            GachaOddsRaritySummary(rarity: 'R', probability: 30.0),
            GachaOddsRaritySummary(rarity: 'SR', probability: 9.0),
            GachaOddsRaritySummary(rarity: 'SSR', probability: 1.0),
          ],
          rewards: [
            // 同名 + detail 違い (Pre-mortem #3)
            GachaOddsReward(
              name: '経験値ボーナス',
              detail: 'EXP +30',
              rarity: 'N',
              rewardType: 'exp',
              icon: '⭐',
              probability: 35.0,
            ),
            GachaOddsReward(
              name: '経験値ボーナス',
              detail: 'EXP +60',
              rarity: 'N',
              rewardType: 'exp',
              icon: '🌿',
              probability: 25.0,
            ),
          ],
        ),
        GachaOddsTicketType(
          ticketType: 'weekly',
          label: 'ウィークリー',
          raritySummary: [
            GachaOddsRaritySummary(rarity: 'SSR', probability: 19.5),
          ],
          rewards: [
            // 小数第 2 位が意味を持つケース
            GachaOddsReward(
              name: 'レアキャラ (SSR)',
              detail: '未開放キャラから1体',
              rarity: 'SSR',
              rewardType: 'character',
              icon: '✨',
              probability: 0.5,
            ),
          ],
        ),
      ],
      notes: ['キャラクター報酬は、まだ解放していないキャラクターの中から均等に抽選されます。'],
    );

Widget _harness(List<Override> overrides) {
  return ProviderScope(
    overrides: overrides,
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('ja'),
      home: GachaOddsPage(),
    ),
  );
}

void main() {
  group('FEAT-518 ガチャ排出確率画面', () {
    testWidgets('1. 確率テーブルが表示される', (tester) async {
      await tester.pumpWidget(_harness([
        gachaOddsProvider.overrideWith((ref) async => _mockOdds()),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('デイリー'), findsOneWidget);
      expect(find.text('ウィークリー'), findsOneWidget);
      expect(find.textContaining('35.00%'), findsOneWidget);
      expect(find.textContaining('25.00%'), findsOneWidget);
    });

    testWidgets('2. 同名で detail 違いの報酬が個別に表示される', (tester) async {
      await tester.pumpWidget(_harness([
        gachaOddsProvider.overrideWith((ref) async => _mockOdds()),
      ]));
      await tester.pumpAndSettle();

      // 同名報酬が 2 件そのまま出ていること (集約されていない)
      expect(find.textContaining('経験値ボーナス'), findsNWidgets(2));
      // detail で区別できること
      expect(find.text('EXP +30'), findsOneWidget);
      expect(find.text('EXP +60'), findsOneWidget);
    });

    testWidgets('3. 小数第 2 位まで表示される (0.5% が丸まらない)', (tester) async {
      await tester.pumpWidget(_harness([
        gachaOddsProvider.overrideWith((ref) async => _mockOdds()),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('0.50%'), findsOneWidget);
      // 「1%」や「0.5%」に丸められていないこと
      expect(find.text('1%'), findsNothing);
      expect(find.text('0.5%'), findsNothing);
    });

    testWidgets('4. 注記が表示される', (tester) async {
      await tester.pumpWidget(_harness([
        gachaOddsProvider.overrideWith((ref) async => _mockOdds()),
      ]));
      await tester.pumpAndSettle();

      // 注記は確率テーブルの下にあるため、テスト用の狭い viewport では
      // 画面外にある。スクロールして到達できることまで含めて契約とする。
      final notes = find.textContaining('まだ解放していないキャラクター');
      await tester.scrollUntilVisible(notes, 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();

      expect(notes, findsOneWidget);
    });

    testWidgets('5. 取得失敗時はサビ口調のエラーと再試行ボタンが出る', (tester) async {
      await tester.pumpWidget(_harness([
        gachaOddsProvider.overrideWith((ref) async => throw Exception('boom')),
      ]));
      await tester.pumpAndSettle();

      // 生の例外が UI に漏れていないこと (pre-commit hook と同じ原則)
      expect(find.textContaining('Exception'), findsNothing);
      expect(find.textContaining('🪶'), findsOneWidget);
      expect(find.text('再試行'), findsOneWidget);
    });
  });
}
