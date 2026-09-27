// 【FEAT-431 Phase 4】 JobSelectionOverlay widget test 5 件 (S1-S5)。
//
// 検証対象 (FEAT-431_job_list_modal.md §3.6 仕様準拠):
//   S1: モーダルが「ジョブ一覧」ヘッダーを表示
//   S2: 「現在のジョブ: 闇魔導士 (noir)」バナーが表示
//   S3: 設定中ジョブ (闇魔導士) にチェックマーク (Icons.check_circle)
//   S4: 他ジョブ (モンク等) に鍵アイコン (Icons.lock) + 「熟練度 Max で解禁 (v1.1+)」hint
//   S5: 「< 戻る」「×」タップで onClose が発火 (3 経路のうち 2 経路)
//   S6: 【2026-08-09】戦ったことのあるジョブに熟練度バーが出る
//   S7: 【2026-08-09】戦っていないジョブには何も出ない (サビ哲学「押し付けない」)
//
// 設計判断: カード外背景タップで閉じる動線 (3 経路目) は親 (_PartyEditDialogState)
// 側の Stack 背景 GestureDetector の責務 (EquipmentSelectionOverlay と同パターン)
// のため、本 widget の単体 test スコープ外。

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/features/battle/models/job.dart';
import 'package:sabiowl/features/battle/widgets/job_selection_overlay.dart';
import 'package:sabiowl/features/gamification/models/job_mastery.dart';
import 'package:sabiowl/features/gamification/services/job_mastery_service.dart';
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

    // 【2026-08-09】`JobSelectionOverlay` は `JobMasteryBar` (ConsumerWidget) を
    // 含むようになったため ProviderScope が要る。
    //
    // **必ず `jobMasteriesProvider` を override すること。** override しないと
    // 本物の provider が apiClient chain を起動し、その非同期エラーが
    // `dispose` より先に届くかどうかで成否が変わる flaky を作る
    // (`world_frame_mini_battle_test` が踏んでいるのと同じ型。
    //  v1.1 チェックリスト G1 に記録あり)。
    Widget wrap(Widget child, {List<JobMastery> masteries = const []}) {
      return ProviderScope(
        overrides: [
          jobMasteriesProvider.overrideWith((ref) async => masteries),
        ],
        child: MaterialApp(
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
      await tester.pumpWidget(wrap(
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
      await tester.pumpWidget(wrap(
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
      await tester.pumpWidget(wrap(
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
      await tester.pumpWidget(wrap(
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
      await tester.pumpWidget(wrap(
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

    // ── 【2026-08-09】ジョブ熟練度バー ─────────────────────────────
    //
    // 起点: ユーザー報告「熟練度のゲージが見当たらない」。FEAT-511 Phase A は
    // 実装済みだったが表示先がキャラクター画面だけで、**ジョブを見に来る最も
    // 自然な導線であるこの overlay に無かった**。加えて party_edit_dialog には
    // 「熟練度システムは v1.1+ でご用意します」という stale な予告バナーが
    // 残っており、実装済みの機能を未実装に見せていた (同日削除)。

    testWidgets('S6: 戦ったことのあるジョブに熟練度バーが表示される', (tester) async {
      await _useTallSurface(tester);
      await tester.pumpWidget(wrap(
        JobSelectionOverlay(
          currentJob: currentJob,
          currentCharacterName: 'noir',
          onClose: () {},
        ),
        masteries: const [
          JobMastery(
            jobId: 'dark_mage', jobName: '闇魔導士',
            level: 3, exp: 20, expToNext: 30, isMaxed: false,
          ),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('闇魔導士 Lv 3 / 10'), findsOneWidget,
          reason: '装着中ジョブに熟練度ラベルが出ること');
      // 【2026-08-09 修正】旧: 「あと 30 EXP で Lv 4 ですよ 🪶」を期待していた。
      // `expToNext` を残量と誤解した実装に合わせた assert で、**バグを正解として
      // 固定していた** (expToNext=30 は「Lv 3 に必要な総量」なので、exp=20 なら
      // 残りは 10)。分数表記に変更したので実データがそのまま出る。
      expect(find.text('20 / 30 EXP'), findsOneWidget,
          reason: '進捗を「現在 / 必要総量」の分数で出すこと');
      expect(find.byType(LinearProgressIndicator), findsOneWidget,
          reason: 'バーは熟練度のある 1 ジョブぶんだけ');
    });

    testWidgets('S7: 戦っていないジョブには何も表示されない', (tester) async {
      await _useTallSurface(tester);
      await tester.pumpWidget(wrap(
        JobSelectionOverlay(
          currentJob: currentJob,
          currentCharacterName: 'noir',
          onClose: () {},
        ),
        // 熟練度データなし = まだ誰とも戦っていない
      ));
      await tester.pumpAndSettle();

      // 【意図】0 のゲージを 14 本並べて「まだ何もしていない」を突きつけない。
      // サビ哲学「押し付けない」。ここが崩れると overlay が催促の画面になる。
      expect(find.byType(LinearProgressIndicator), findsNothing,
          reason: '未バトルのジョブにバーを出さないこと');
      // 既存の描画契約 (S4 の locked hint) は影響を受けない
      expect(find.text('熟練度 Max で解禁 (v1.1+)'), findsNWidgets(13));
    });
  });
}
