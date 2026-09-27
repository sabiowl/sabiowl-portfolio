// 【FEAT-526 (2026-08-21)】KO 演出 overlay の挙動テスト。
//
// 縛る内容:
//   A. 発火すると拡大 + 暗転 +「K.O.」が出る
//   B. **演出が終わると全部元に戻る** (Pre-mortem #4: 掛かりっぱなしにしない)
//   C. `onFinished` が終了時に **1 回だけ** 呼ばれる (これがゲートの鍵)
//   D. 倍速で短くなる、ただし下限を下回らない (Pre-mortem #5)
//   E. 連戦: 2 回目も頭から再生される (Pre-mortem #6)
//   F. 演出中に離脱 (dispose) しても例外を出さず、onFinished も呼ばない
//   G. overlay が居ないときの `fire()` は false を返す (caller がゲートを開ける根拠)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/constants/battle_constants.dart';
import 'package:sabiowl/features/battle/widgets/ko_effect_overlay.dart';

/// overlay に包まれる「戦闘エリア」の代役。
const _arenaKey = Key('arena');

Widget _host(KoEffectController controller, VoidCallback onFinished) {
  return MaterialApp(
    home: Scaffold(
      body: KoEffectOverlay(
        controller: controller,
        onFinished: onFinished,
        child: const SizedBox(key: _arenaKey, width: 200, height: 200),
      ),
    ),
  );
}

/// 戦闘エリアに掛かっている拡大率 (掛かっていなければ null)。
double? _arenaScale(WidgetTester tester) {
  final transforms = tester.widgetList<Transform>(
    find.ancestor(of: find.byKey(_arenaKey), matching: find.byType(Transform)),
  );
  for (final t in transforms) {
    final sx = t.transform.storage[0];
    if (sx != 1.0) return sx;
  }
  return transforms.isEmpty ? null : 1.0;
}

void main() {
  group('FEAT-526 KoEffectOverlay', () {
    testWidgets('A: 発火すると拡大 + 暗転 +「K.O.」が出る', (tester) async {
      final controller = KoEffectController();
      await tester.pumpWidget(_host(controller, () {}));

      // 非発火時は素通し = Transform も「K.O.」も無い
      expect(find.byType(KoLabel), findsNothing);
      expect(_arenaScale(tester), isNull,
          reason: '通常時は Transform を挟まない (レイアウトを一切変えない)');

      expect(controller.fire(speedMultiplier: 1.0), isTrue);
      // ヒットストップ + ズームイン + ラベル頭まで進める
      await tester.pump();
      await tester.pump(BattleConstants.koHitStopDuration +
          BattleConstants.koZoomInDuration +
          const Duration(milliseconds: 80));

      expect(_arenaScale(tester), closeTo(BattleConstants.koMaxZoom, 0.01),
          reason: 'ズームは最大倍率まで掛かる');
      expect(find.byType(KoLabel), findsOneWidget);
      expect(find.text(KoLabel.text), findsOneWidget);

      await tester.pumpAndSettle();
    });

    testWidgets('B: 🔴 演出が終わるとズームも暗転も「K.O.」も元に戻る',
        (tester) async {
      // 演出中に離脱した / 終わったのに掛かりっぱなし、が Pre-mortem #4。
      // FEAT-455 が同型の事故 (fadeOut の opacity が次バトルへ持ち越された)。
      final controller = KoEffectController();
      await tester.pumpWidget(_host(controller, () {}));
      controller.fire(speedMultiplier: 1.0);
      await tester.pumpAndSettle();

      expect(find.byType(KoLabel), findsNothing);
      expect(_arenaScale(tester), isNull, reason: 'Transform ごと消えている');
      expect(controller.isPlaying, isFalse);
    });

    testWidgets('C: onFinished が終了時に 1 回だけ呼ばれる', (tester) async {
      var calls = 0;
      final controller = KoEffectController();
      await tester.pumpWidget(_host(controller, () => calls++));

      controller.fire(speedMultiplier: 1.0);
      await tester.pump();
      // 演出の途中ではまだ呼ばれない —— ここが「敵の fadeOut と報酬モーダルを
      // 演出の後ろへ動かす」ゲートの根拠。
      await tester.pump(const Duration(milliseconds: 200));
      expect(calls, 0);

      await tester.pumpAndSettle();
      expect(calls, 1);
    });

    // 【2026-08-22 ユーザー判断】旧題は「3 倍速では演出時間が約 1/3 になる」。
    // 🔴 **もう 1/3 にはならない。**「K.O.」ラベルだけ倍速の対象外にしたので、
    // 縮むのはヒットストップ / ズームだけ (1830 → 1623ms)。
    // 倍速は「戦闘の進行を速く見たい」であって「結果を読む時間を削りたい」
    // ではない、というのが確定した意図 (`koScaledLabel` の doc 参照)。
    testWidgets('D: 3 倍速でも「K.O.」は縮まず、縮むのは前後の区間だけ',
        (tester) async {
      var calls = 0;
      final controller = KoEffectController();
      await tester.pumpWidget(_host(controller, () => calls++));

      controller.fire(speedMultiplier: 3.0);
      await tester.pump();

      // ラベルが縮んでいないので、等速の総時間の半分ではまだ終わっていない。
      // (旧実装ではここで終わっていた = ラベルが 500ms に潰れていた)
      await tester.pump(BattleConstants.koTotalDuration ~/ 2);
      expect(calls, 0, reason: '3 倍速でも「K.O.」の 1.5 秒は削られない');

      // ただし倍速自体は効いている —— 等速の総時間の時点では終わっている。
      await tester.pump(BattleConstants.koTotalDuration);
      expect(calls, 1, reason: '前後の区間は縮むので等速より短く終わる');

      await tester.pumpAndSettle();
    });

    testWidgets('D2: ⏭ Skip (50x) でも「K.O.」は 1.5 秒出る', (tester) async {
      // ユーザー報告の本体。かつては 40ms = 60fps で 2.4 フレームだった。
      var calls = 0;
      final controller = KoEffectController();
      await tester.pumpWidget(_host(controller, () => calls++));

      controller.fire(speedMultiplier: 50.0);
      await tester.pump();
      await tester.pump(BattleConstants.koLabelDuration ~/ 2);
      expect(calls, 0, reason: 'Skip でもラベルの途中では終わらない');

      await tester.pumpAndSettle();
      expect(calls, 1);
    });

    testWidgets('E: 連戦 — 2 回目も頭から再生され、また元に戻る',
        (tester) async {
      // Pre-mortem #6: オートバトルの連戦で 2 回目が出ない / 二重に出る。
      var calls = 0;
      final controller = KoEffectController();
      await tester.pumpWidget(_host(controller, () => calls++));

      controller.fire(speedMultiplier: 1.0);
      await tester.pumpAndSettle();
      expect(calls, 1);

      expect(controller.fire(speedMultiplier: 1.0), isTrue);
      await tester.pump();
      await tester.pump(BattleConstants.koHitStopDuration +
          BattleConstants.koZoomInDuration +
          const Duration(milliseconds: 80));
      expect(find.byType(KoLabel), findsOneWidget,
          reason: '2 戦目も頭から再生される (前回の進捗が残っていない)');

      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(_arenaScale(tester), isNull);
    });

    testWidgets('F: 演出中に離脱しても例外を出さず、onFinished も呼ばない',
        (tester) async {
      // Pre-mortem #4: 演出中に戻るジェスチャで離脱するケース。
      var calls = 0;
      final controller = KoEffectController();
      await tester.pumpWidget(_host(controller, () => calls++));
      controller.fire(speedMultiplier: 1.0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 画面を差し替える = KoEffectOverlay が dispose される
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(calls, 0, reason: '画面が無くなった後にゲートを開けても意味がない');
      expect(controller.isPlaying, isFalse,
          reason: 'detach 済みなので controller から見ても再生中ではない');
    });

    testWidgets('G: overlay が居ないときの fire() は false を返す',
        (tester) async {
      // caller (battle_page) はこの false を見て **自分でゲートを開ける**。
      // ここが true を返してしまうと、敵が永久に消えず報酬モーダルも出ない。
      final controller = KoEffectController();
      expect(controller.fire(speedMultiplier: 1.0), isFalse);
      expect(controller.isPlaying, isFalse);
    });
  });
}
