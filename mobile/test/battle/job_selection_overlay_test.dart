// 【FEAT-431 Phase 4】 JobSelectionOverlay widget test 5 件 (S1-S5)。
//
// 検証対象 (FEAT-431_job_list_modal.md §3.6 仕様準拠):
//   S1: モーダルが「ジョブ一覧」ヘッダーを表示
//   S2: 「現在のジョブ: 闇魔導士 (noir)」バナーが表示
//   S3: 設定中ジョブ (闇魔導士) にチェックマーク (Icons.check_circle)
//   S4: 他ジョブ (モンク等) に鍵アイコン (Icons.lock) + 「熟練度 Max で解禁 (v1.1+)」hint
//   S5: 「< 戻る」「×」タップで onClose が発火 (3 経路のうち 2 経路)
//
// 設計判断: カード外背景タップで閉じる動線 (3 経路目) は親 (_PartyEditDialogState)
// 側の Stack 背景 GestureDetector の責務 (EquipmentSelectionOverlay と同パターン)
// のため、本 widget の単体 test スコープ外。

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/features/battle/models/job.dart';
import 'package:sabiowl/features/battle/widgets/job_selection_overlay.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

void main() {
  group('FEAT-431 JobSelectionOverlay 描画契約', () {
    // 設定中ジョブ = 闇魔導士 (dark_mage)、キャラ = noir
    const currentJob = Job(
      jobId: 'dark_mage',
      jobName: '闇魔導士',
      atbSpeedModifier: 0.8,
      attackPowerModifier: 1.5,
      onHitEffect: 'burn',
      ultCost: 1,
    );

    Widget _wrap(Widget child) {
      return MaterialApp(
        locale: const Locale('ja'),
        localizationsDelegates: [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('ja'), Locale('en')],
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 340, height: 2000, child: child),
          ),
        ),
      );
    }

    // 14 ジョブ全件が ListView.separated の lazy build 範囲に収まるよう、
    // 物理 viewport を十分な高さに広げる (FEAT-431 Phase 4 修正)。
    Future<void> _useTallSurface(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }

    testWidgets('S1: 「ジョブ一覧」ヘッダーが表示される', (tester) async {
      await _useTallSurface(tester);
      await tester.pumpWidget(_wrap(
        JobSelectionOverlay(
          currentJob: currentJob,
          currentCharacterName: 'noir',
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('ジョブ一覧'), findsOneWidget);
    });

    testWidgets('S2: 「現在のジョブ: 闇魔導士 (noir)」バナーが表示される', (tester) async {
      await _useTallSurface(tester);
      await tester.pumpWidget(_wrap(
        JobSelectionOverlay(
          currentJob: currentJob,
          currentCharacterName: 'noir',
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('現在のジョブ: 闇魔導士 (noir)'), findsOneWidget);
    });

    testWidgets('S3: 設定中ジョブ (闇魔導士) にチェックマークが表示される', (tester) async {
      await _useTallSurface(tester);
      await tester.pumpWidget(_wrap(
        JobSelectionOverlay(
          currentJob: currentJob,
          currentCharacterName: 'noir',
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      // 一覧内の「闇魔導士」カードに check_circle が 1 件のみ表示される
      // (バナーは「現在のジョブ: 闇魔導士 (noir)」という別 Text のため重複しない)
      expect(find.text('闇魔導士'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('S4: 他ジョブ (モンク等) に鍵アイコン + 「熟練度 Max で解禁 (v1.1+)」hint が表示される',
        (tester) async {
      await _useTallSurface(tester);
      await tester.pumpWidget(_wrap(
        JobSelectionOverlay(
          currentJob: currentJob,
          currentCharacterName: 'noir',
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      // 14 ジョブ中、設定中 (闇魔導士) 以外の 13 ジョブが「熟練度 Max で解禁 (v1.1+)」hint
      expect(find.text('熟練度 Max で解禁 (v1.1+)'), findsNWidgets(13));
      // 他ジョブの鍵アイコン (Icons.lock) も 13 件
      expect(find.byIcon(Icons.lock), findsNWidgets(13));
      // 他ジョブカード名の例: モンク
      expect(find.text('モンク'), findsOneWidget);
    });

    testWidgets('S5: 「< 戻る」「×」タップで onClose が発火する', (tester) async {
      await _useTallSurface(tester);
      int closeCount = 0;
      await tester.pumpWidget(_wrap(
        JobSelectionOverlay(
          currentJob: currentJob,
          currentCharacterName: 'noir',
          onClose: () => closeCount++,
        ),
      ));
      await tester.pumpAndSettle();

      // 「＜ 戻る」(Icons.chevron_left) タップ
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      expect(closeCount, 1, reason: '＜ 戻るタップで 1 回目発火');

      // 「×」(Icons.close) タップ
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(closeCount, 2, reason: '× タップで 2 回目発火');
    });
  });
}
