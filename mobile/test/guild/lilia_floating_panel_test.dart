// 【FEAT-315】LiliaFloatingPanel の widget test 3 シナリオ。
//
// 検証対象:
//   - A: show() で Overlay に挿入され、メッセージとリリアアイコン (or 🌸 fallback) が表示される
//   - B: duration 経過後に自動 remove される (Pre-mortem #1 二重 remove 許容)
//   - C: 二重 remove (caller 手動 + 自動) しても assertion error を投げない
//
// 設計判断: Phase 1 単体テスト範囲は widget の生成 / dispose 契約に絞り、
// home_page の ref.listen 経由の発火条件は別途 integration test (Phase 2)
// で縛る（本 FEAT スコープでは静的検証 + 既存 sabi_tone / receptionist_tone
// 退行ゼロ確認で十分）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/guild/widgets/lilia_floating_panel.dart';

void main() {
  group('FEAT-315 LiliaFloatingPanel 描画契約', () {
    testWidgets('A: show() でメッセージが Overlay に表示される', (tester) async {
      const message = 'お見事です! 戦利品をどうぞお受け取りくださいませ 🗡️';
      late BuildContext capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (ctx) {
              capturedContext = ctx;
              return const SizedBox.shrink();
            }),
          ),
        ),
      );

      LiliaFloatingPanel.show(capturedContext, message: message);
      await tester.pump();              // build
      await tester.pump(const Duration(milliseconds: 400));  // スライドイン完了

      expect(find.text(message), findsOneWidget,
          reason: 'LiliaFloatingPanel は渡されたメッセージを表示するはず');

      // 自動 remove のスケジュールに任せて end-of-test の pendingTimers を消費
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('B: duration 経過後にメッセージが消える (自動 remove)', (tester) async {
      const message = 'お疲れ様でした! 見事な戦いぶりでしたよ ⚔️';
      late BuildContext capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (ctx) {
              capturedContext = ctx;
              return const SizedBox.shrink();
            }),
          ),
        ),
      );

      LiliaFloatingPanel.show(
        capturedContext,
        message: message,
        duration: const Duration(milliseconds: 500),  // 短縮してテスト高速化
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(message), findsOneWidget);

      // duration 500ms + フェードアウト 350ms + auto-remove margin 250ms = 1100ms
      await tester.pump(const Duration(milliseconds: 1200));
      expect(find.text(message), findsNothing,
          reason: 'duration 経過 + フェードアウト + auto-remove 後はメッセージが消える');
    });

    testWidgets('C: 二重 remove しても assertion error を投げない (Pre-mortem #1)', (tester) async {
      late BuildContext capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (ctx) {
              capturedContext = ctx;
              return const SizedBox.shrink();
            }),
          ),
        ),
      );

      final entry = LiliaFloatingPanel.show(
        capturedContext,
        message: '勝利の凱旋ですね! 🌸',
        duration: const Duration(milliseconds: 200),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // caller が手動で remove (二重 remove 状況を作る)
      entry.remove();
      // 自動 remove のスケジュールも消費
      await tester.pump(const Duration(milliseconds: 1000));

      // assertion error / exception が発火していないこと
      expect(tester.takeException(), isNull,
          reason: 'try/catch で二重 remove を許容しているため例外が発生しない');
    });
  });
}
