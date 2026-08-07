// FEAT-508 (2026-07-29) HighlightedText 契約テスト (6 件)
//
// 契約:
//   1. query 空 → 通常 Text 描画 (highlight ロジック未実行)
//   2. 単一マッチ (大文字小文字無視) → 正しいハイライト span
//   3. 複数マッチ → 全件ハイライト
//   4. マッチなし → 全体を通常 span
//   5. 特殊文字 (regex 記号) → literal 扱いでマッチ
//   6. 部分一致 (substring) → 正しくヒット
//
// ⚠️ Text.rich() の内部構造に注意:
//   Flutter の Text.build() は RichText(text: TextSpan(effectiveStyle, children: [ourSpan]))
//   を生成するため、rt.text.children![0] が私たちの TextSpan になる。
//   そのため spans は rt.text.children![0].children!.cast<TextSpan>() で取得する。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/free_memo/widgets/highlighted_text.dart';

void main() {
  const baseStyle = TextStyle(color: Colors.white70, fontSize: 14);

  Widget buildApp(Widget child) => MaterialApp(
        home: Scaffold(body: child),
      );

  /// HighlightedText 内の RichText から TextSpan children を取得。
  /// Flutter Text.build() は RichText.text = TextSpan(effectiveStyle, children: [ourSpan])
  /// を生成するため、ourSpan.children がハイライト span 群になる。
  List<TextSpan> extractSpans(WidgetTester tester) {
    final rt = tester.widget<RichText>(
      find
          .descendant(
            of: find.byType(HighlightedText),
            matching: find.byType(RichText),
          )
          .first,
    );
    final outerRoot = rt.text as TextSpan;
    // Flutter がラップした TextSpan の唯一の子が our TextSpan
    final ourSpan = outerRoot.children![0] as TextSpan;
    return ourSpan.children!.cast<TextSpan>();
  }

  group('HighlightedText — FEAT-508 検索ハイライト契約テスト', () {
    testWidgets('契約 1: query 空なら通常 Text 描画 (ハイライトなし)', (tester) async {
      await tester.pumpWidget(buildApp(
        const HighlightedText(
          content: 'メモ本文',
          query: '',
          style: baseStyle,
        ),
      ));
      expect(find.byType(HighlightedText), findsOneWidget);
      expect(find.text('メモ本文'), findsOneWidget);
    });

    testWidgets('契約 2: 単一マッチ (大文字小文字無視) を正しくハイライト', (tester) async {
      await tester.pumpWidget(buildApp(
        const HighlightedText(
          content: 'ABC 明日 会議',
          query: '明日',
          style: baseStyle,
        ),
      ));
      final children = extractSpans(tester);
      // spans: ['ABC ', HL:'明日', ' 会議']
      expect(children.length, 3);
      expect(children[0].text, 'ABC ');
      expect(children[0].style?.backgroundColor, isNull);
      expect(children[1].text, '明日');
      expect(children[1].style?.backgroundColor, isNotNull);
      expect(children[2].text, ' 会議');
      expect(children[2].style?.backgroundColor, isNull);
    });

    testWidgets('契約 3: 複数マッチを全てハイライト', (tester) async {
      await tester.pumpWidget(buildApp(
        const HighlightedText(
          content: 'テスト テスト',
          query: 'テスト',
          style: baseStyle,
        ),
      ));
      final children = extractSpans(tester);
      // spans: [HL:'テスト', ' ', HL:'テスト']
      expect(children.length, 3);
      expect(children[0].style?.backgroundColor, isNotNull);
      expect(children[1].text, ' ');
      expect(children[1].style?.backgroundColor, isNull);
      expect(children[2].style?.backgroundColor, isNotNull);
    });

    testWidgets('契約 4: マッチなしなら全体を通常 span で描画', (tester) async {
      await tester.pumpWidget(buildApp(
        const HighlightedText(
          content: 'hello world',
          query: 'xyz',
          style: baseStyle,
        ),
      ));
      final children = extractSpans(tester);
      // spans: ['hello world'] (HL span なし)
      expect(children.length, 1);
      expect(children[0].text, 'hello world');
      expect(children[0].style?.backgroundColor, isNull);
    });

    testWidgets('契約 5: 特殊文字 (regex 記号) が literal 扱い', (tester) async {
      await tester.pumpWidget(buildApp(
        const HighlightedText(
          content: '価格 [500] 円',
          query: '[500]',
          style: baseStyle,
        ),
      ));
      final children = extractSpans(tester);
      // spans: ['価格 ', HL:'[500]', ' 円']
      expect(children.length, 3);
      expect(children[1].text, '[500]');
      expect(children[1].style?.backgroundColor, isNotNull);
    });

    testWidgets('契約 6: query 部分一致でも substring hit', (tester) async {
      await tester.pumpWidget(buildApp(
        const HighlightedText(
          content: '明日打ち合わせ',
          query: '合わせ',
          style: baseStyle,
        ),
      ));
      final children = extractSpans(tester);
      // spans: ['明日打ち', HL:'合わせ']
      expect(children.length, 2);
      expect(children[0].text, '明日打ち');
      expect(children[1].text, '合わせ');
      expect(children[1].style?.backgroundColor, isNotNull);
    });
  });
}
