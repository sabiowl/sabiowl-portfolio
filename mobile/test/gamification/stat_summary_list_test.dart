// 【2026-08-11】`StatSummaryList` のラベルが 1 行に収まることを縛る。
//
// ## なぜ必要か (実際に起きたこと)
//
// ラベル列は `SizedBox(width: 32)` の固定幅で、コメントに「短縮ラベル「運動」」
// とあるとおり **日本語 2 文字を基準にした値**だった。英語の `Exercise` (8 文字)
// は入らず、実機で **`Exer` / `cise` と単語の途中で折り返していた**。
// `Study` → `Stud`/`y`、`Mental` → `Ment`/`al` も同様。
//
// ラベル自体は `StatHexagonChart.labelFor` で locale 対応済だったのに
// **幅だけが日本語のまま取り残されていた** —— FEAT-489 (英語化) の配線漏れで、
// 英語ユーザー全員に出ていた表示崩れ。英語スクリーンショットの撮影で発覚した。
//
// ## 何を縛るか
//
// 「英語で崩れない」だけを見ると、幅を広げただけの対症療法も緑になる。
// そこで **行数** と **列の揃い** の 2 つを縛る:
//
//   1. 6 ラベルすべてが **1 行** (ja / en 両方)
//   2. 6 行の数値の左端が **同一 x 座標** (= 列が揃っている)
//
// 2 は元の固定幅が守ろうとしていた性質そのもの。`Row` を 6 個並べる構造では
// 行をまたいだ列幅の同期ができないため、これを保ったまま 1 の問題を直すには
// `Table` + `IntrinsicColumnWidth` が要る。**片方だけ直す修正を緑にしない**。
//
// 実行方法:
// ```powershell
// cd mobile; flutter test test/gamification/stat_summary_list_test.dart
// ```
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/gamification/models/gamification_models.dart';
import 'package:sabiowl/features/gamification/widgets/stat_summary_list.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

/// 実画面と同じ「6 角形チャートの左隣」の狭い幅を再現する。
///
/// `status_overview_card.dart` は `Expanded(child: StatSummaryList(...))` +
/// チャート (固定幅) の Row 構成。iPhone 幅からチャートぶんを引くと概ねこの程度。
const double _kListWidth = 190;

const _stats = <CharacterStat>[
  CharacterStat(id: 1, name: '運動力', level: 8, currentExp: 100, maxExp: 355),
  CharacterStat(id: 2, name: '学習力', level: 8, currentExp: 120, maxExp: 355),
  CharacterStat(id: 3, name: '健康力', level: 8, currentExp: 140, maxExp: 355),
  CharacterStat(id: 4, name: '精神力', level: 8, currentExp: 160, maxExp: 355),
  CharacterStat(id: 5, name: '創造力', level: 8, currentExp: 180, maxExp: 355),
  CharacterStat(id: 6, name: '貢献力', level: 8, currentExp: 200, maxExp: 355),
];

Future<void> _pump(WidgetTester tester, Locale locale) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: locale,
    home: const Scaffold(
      body: Center(
        child: SizedBox(
          width: _kListWidth,
          child: StatSummaryList(stats: _stats),
        ),
      ),
    ),
  ));
}

/// `Text` が実際に何行で描画されたかを返す。
///
/// `RenderParagraph.computeLineMetrics()` は Flutter 3.29 の公開 API に無いため、
/// **実際に描画された高さ ÷ 同じ style で 1 行にしたときの高さ** で求める。
/// 折り返していれば 2 以上になる。
int _lineCount(WidgetTester tester, String text) {
  final widget = tester.widget<Text>(find.text(text));
  final box = tester.renderObject<RenderBox>(find.text(text));
  final oneLine = TextPainter(
    text: TextSpan(text: text, style: widget.style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return (box.size.height / oneLine.height).round();
}

/// その locale で表示される 6 ラベル。
List<String> _labels(WidgetTester tester) {
  final l10n = AppLocalizations.of(tester.element(find.byType(StatSummaryList)))!;
  return [
    l10n.gamifStatHexagonLabelExercise,
    l10n.gamifStatHexagonLabelStudy,
    l10n.gamifStatHexagonLabelHealth,
    l10n.gamifStatHexagonLabelMental,
    l10n.gamifStatHexagonLabelCreativity,
    l10n.gamifStatHexagonLabelContribution,
  ];
}

void main() {
  group('StatSummaryList — ラベルが 1 行に収まる', () {
    testWidgets('英語: 6 ラベルすべて 1 行 (Exer/cise の再発防止)', (tester) async {
      await _pump(tester, const Locale('en'));

      for (final label in _labels(tester)) {
        expect(
          _lineCount(tester, label), 1,
          reason: 'ラベル "$label" が折り返している。'
              'ラベル列の幅が英語に足りていない (旧: SizedBox(width: 32))',
        );
      }
    });

    testWidgets('日本語: 6 ラベルすべて 1 行 (英語対応で ja を壊していない)',
        (tester) async {
      await _pump(tester, const Locale('ja'));

      for (final label in _labels(tester)) {
        expect(_lineCount(tester, label), 1, reason: 'ラベル "$label" が折り返している');
      }
    });
  });

  group('StatSummaryList — 列が揃っている', () {
    /// 固定幅ラベルが守っていた性質。幅を広げるだけの対症療法や、
    /// ラベルごとに幅が変わる実装 (Row × 6) を緑にしないためのガード。
    Future<void> expectColumnsAligned(WidgetTester tester, Locale locale) async {
      await _pump(tester, locale);

      final values = _stats.map((s) => s.cumulativeExp.toString()).toSet();
      expect(values.length, _stats.length, reason: '前提: 6 つの数値が互いに異なる');

      final lefts = <double>{
        for (final v in values) tester.getTopLeft(find.text(v)).dx,
      };
      expect(
        lefts.length, 1,
        reason: '6 行の数値の左端が揃っていない (x = $lefts)。'
            'ラベル列の幅が行ごとに変わっている',
      );
    }

    testWidgets('英語', (t) => expectColumnsAligned(t, const Locale('en')));
    testWidgets('日本語', (t) => expectColumnsAligned(t, const Locale('ja')));
  });

  testWidgets('stats が空なら何も描画しない', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('ja'),
      home: Scaffold(body: StatSummaryList(stats: [])),
    ));

    expect(find.byType(Table), findsNothing);
  });
}
