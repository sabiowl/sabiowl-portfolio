import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';

import '../../../core/theme/app_theme.dart';
import '../models/gamification_models.dart';
import 'stat_hexagon_chart.dart';

/// 【2026-06-27】6 ステータスを「短縮名 + 累計 EXP + (絶対 %)」の縦リストで
/// 表示する widget。`StatHexagonChart` の左隣に並べて使う想定 (stats_page)。
///
/// 表示例:
///   運動  425  (85%)      Exercise  425  (85%)
///   学習  460  (92%)      Study     460  (92%)
///   健康  980  (98%)      Health    980  (98%)
///   ...
///
/// - 名前は `StatHexagonChart.labelFor` で短縮 (運動 / 学習 / ...) し、チャート
///   ラベルと表記揺れを起こさない。
/// - 累計 EXP は `CharacterStatComputed.cumulativeExp` (Flutter 側計算)。
/// - % は `progressPercent` (Lv 50 = 100% 基準) で、チャートの正規化と一致。
/// - 表示順は `StatHexagonChart` と同じ固定順 (運動 → 学習 → 健康 → 精神 →
///   創造 → 貢献) で並べ、リスト行とチャート頂点を 1:1 で読み比べられる設計。
///
/// ## 【2026-08-11】`Row` × 6 → `Table` に変更した理由
///
/// ラベル列は `SizedBox(width: 32)` の固定幅だった。コメントに「短縮ラベル
/// 「運動」」とあるとおり **日本語 2 文字を基準にした値**で、英語の `Exercise`
/// (8 文字) は入らず **`Exer` / `cise` と単語の途中で折り返していた**
/// (実機の英語スクリーンショットで検出)。`Study` → `Stud`/`y`、
/// `Mental` → `Ment`/`al` も同様。
///
/// ラベル自体は `StatHexagonChart.labelFor` で locale 対応済だったのに、
/// **幅だけが日本語のまま取り残されていた** —— FEAT-489 (英語化) の配線漏れ。
///
/// 固定幅を広げる / locale で出し分ける案も検討したが、いずれも
/// **「日本語 2 文字」を「英語 8 文字」に置き換えるだけ**で、3 言語目を足せば
/// 同じ問題が再発する。`Table` の [IntrinsicColumnWidth] は
/// **その列の全セルのうち最大幅**に自動で合わせるので、
///
///   - マジックナンバーが消える (幅の根拠がコードから不要になる)
///   - 日本語のレイアウトは実質変わらない (最長ラベルが従来と同じ幅に落ち着く)
///   - **6 行の左揃えが保たれる** —— `Row` を 6 個並べる構造では行をまたいだ
///     列幅の同期ができず、これが固定幅を必要としていた元の理由だった
///
/// という 3 点を同時に満たす。ellipsis (`Exerci…`) や `FittedBox` (英語だけ
/// 極小フォント) は可読性を落とすため採らなかった。
class StatSummaryList extends StatelessWidget {
  final List<CharacterStat> stats;

  /// チャートと同じ固定表示順。
  static const _displayOrder = <String>[
    '運動力', '学習力', '健康力', '精神力', '創造力', '貢献力',
  ];

  const StatSummaryList({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    if (stats.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    return Table(
      // 0: ラベル   —— 6 行の最長に自動で合わせる (locale 非依存)
      // 1: 累計 EXP —— 残り幅を占有し、右揃えで桁を揃える
      // 2: (%)      —— 「(100%)」まで入る固定幅
      columnWidths: const <int, TableColumnWidth>{
        0: IntrinsicColumnWidth(),
        1: FlexColumnWidth(),
        2: FixedColumnWidth(44),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        for (final s in _orderedStats())
          _statRow(StatHexagonChart.labelFor(l10n, s.name),
              s.cumulativeExp, s.progressPercent),
      ],
    );
  }

  TableRow _statRow(String label, int value, int percent) {
    return TableRow(
      children: [
        // ── 短縮ラベル。`softWrap: false` で **折り返しを構造的に禁止**する。
        //    IntrinsicColumnWidth が必要幅を確保するので溢れないが、万一
        //    確保に失敗しても「単語の途中で改行」だけは起こさない。
        Padding(
          padding: const EdgeInsets.only(right: 4, top: 2.5, bottom: 2.5),
          child: Text(
            label,
            softWrap: false,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        // ── 累計 EXP (右寄せで桁を揃える)
        Padding(
          padding: const EdgeInsets.only(right: 6, top: 2.5, bottom: 2.5),
          child: Text(
            '$value',
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        // ── % 値 (チャート頂点の % と同期)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.5),
          child: Text(
            '($percent%)',
            textAlign: TextAlign.right,
            style: TextStyle(
              color: AppTheme.primary.withValues(alpha: 0.95),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  List<CharacterStat> _orderedStats() {
    final byName = {for (final s in stats) s.name: s};
    return [
      for (final name in _displayOrder)
        byName[name] ??
            CharacterStat(
              id: -1, name: name, level: 0, currentExp: 0, maxExp: 1,
            ),
    ];
  }
}
