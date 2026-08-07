import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';

import '../../../core/theme/app_theme.dart';
import '../models/gamification_models.dart';

/// 【2026-06-27】6 ステータスを 6 角形レーダーチャートで可視化する widget。
///
/// 表示順は固定 (運動 → 学習 → 健康 → 精神 → 創造 → 貢献) で、`stats` 配列の
/// 順序に依存しない (`CharacterStat.name` で識別)。
///
/// 【2026-06-27 v2 仕様】描画スケールと表示ラベルを分離するハイブリッド方式:
/// - **描画半径**: stats 内 max(progressPercent) を頂点 100% とした相対比で
///   フィット。序盤 (全 12% 等) でもチャートいっぱいに描画され、ステータス間
///   の強弱が視覚化される。
/// - **頂点ラベル % 値**: `progressPercent` (Lv 50 = 100% の絶対基準) を表示。
///   ユーザーは「自分の絶対進捗」と「相対的な強弱」の両方を 1 枚で読み取れる。
///   FIFA / ウイイレ等の能力値レーダーで使われる定番パターン。
///
/// 各頂点には短縮ラベル (運動 / 学習 等) + その下に絶対 % 値を表示する。
///
/// `size` は外形 (ラベル領域込み) のピクセル。中央にデータ六角形が描画される。
class StatHexagonChart extends StatelessWidget {
  final List<CharacterStat> stats;
  final double size;

  /// 表示固定順 (時計回り、12 時方向 = 運動力)。
  static const _displayOrder = <String>[
    '運動力', '学習力', '健康力', '精神力', '創造力', '貢献力',
  ];

  const StatHexagonChart({
    super.key,
    required this.stats,
    this.size = 120,
  });

  @override
  Widget build(BuildContext context) {
    if (stats.isEmpty) return SizedBox(width: size, height: size);
    final l10n = AppLocalizations.of(context)!;
    final ordered = _orderedStats();
    final shortLabels = {
      for (final name in _displayOrder) name: labelFor(l10n, name)
    };
    return Semantics(
      label: l10n.gamifStatHexagonSemantics,
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _HexagonChartPainter(orderedStats: ordered, shortLabels: shortLabels),
        ),
      ),
    );
  }

  /// `_displayOrder` に従って stats を並び替える。
  /// 対応する stat が見つからないキーは Lv=0 のダミーを返す
  /// (Backend 仕様変更でカテゴリ欠落しても描画が崩れないようにする)。
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

  static String labelFor(AppLocalizations l10n, String statName) {
    return switch (statName) {
      '運動力' => l10n.gamifStatHexagonLabelExercise,
      '学習力' => l10n.gamifStatHexagonLabelStudy,
      '健康力' => l10n.gamifStatHexagonLabelHealth,
      '精神力' => l10n.gamifStatHexagonLabelMental,
      '創造力' => l10n.gamifStatHexagonLabelCreativity,
      '貢献力' => l10n.gamifStatHexagonLabelContribution,
      _ => statName,
    };
  }

  /// ステータス名 (運動力 / 学習力 …) の表示ラベル。
  ///
  /// 【FEAT-489 Phase 2C follow-up (2026-08-02)】`CharacterStat.name` は Backend
  /// 由来の日本語 enum 値なので、そのまま描画すると英語 locale で日本語が出る。
  /// 頂点用の短縮ラベル ([labelFor]) と対になる正式名として本メソッドを使うこと。
  /// stats_page / level_up_dialog の 2 経路で同じ switch を重複させないため
  /// [labelFor] と同居させている。
  static String fullNameFor(AppLocalizations l10n, String statName) {
    return switch (statName) {
      '運動力' => l10n.gamifStatFullNameExercise,
      '学習力' => l10n.gamifStatFullNameStudy,
      '健康力' => l10n.gamifStatFullNameHealth,
      '精神力' => l10n.gamifStatFullNameMental,
      '創造力' => l10n.gamifStatFullNameCreativity,
      '貢献力' => l10n.gamifStatFullNameContribution,
      _ => statName,
    };
  }
}

class _HexagonChartPainter extends CustomPainter {
  final List<CharacterStat> orderedStats;
  final Map<String, String> shortLabels;

  _HexagonChartPainter({required this.orderedStats, required this.shortLabels});

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
    // ラベル分のマージンを引いてチャート本体の半径を決める
    // 【2026-06-27】各頂点に「名前 + %」の 2 段ラベルを置くため余白を 14 → 20 へ拡大
    final outer = math.min(canvasSize.width, canvasSize.height) / 2 - 20;
    if (outer <= 0) return;

    // 12 時方向から時計回りに 60° 刻み。dart の atan2 系と Canvas の Y 軸 (下向き)
    // を合わせるため -π/2 オフセットで開始点を上に固定。
    final angles = List<double>.generate(
      6, (i) => -math.pi / 2 + i * (math.pi / 3),
    );

    _drawGrid(canvas, center, outer, angles);
    _drawAxes(canvas, center, outer, angles);
    _drawDataPolygon(canvas, center, outer, angles);
    _drawLabels(canvas, center, outer, angles);
  }

  /// 3 重の同心 6 角形 (33% / 66% / 100% のレベル感を視覚化)。
  void _drawGrid(Canvas canvas, Offset center, double outer, List<double> angles) {
    final gridPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = Colors.white.withValues(alpha: 0.10);
    for (final scale in [0.33, 0.66, 1.0]) {
      final path = Path();
      for (var i = 0; i < 6; i++) {
        final r = outer * scale;
        final p = Offset(
          center.dx + r * math.cos(angles[i]),
          center.dy + r * math.sin(angles[i]),
        );
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      canvas.drawPath(path, gridPaint);
    }
  }

  /// 中心から各頂点に伸びる軸線。
  void _drawAxes(Canvas canvas, Offset center, double outer, List<double> angles) {
    final axisPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = Colors.white.withValues(alpha: 0.08);
    for (final a in angles) {
      canvas.drawLine(
        center,
        Offset(center.dx + outer * math.cos(a), center.dy + outer * math.sin(a)),
        axisPaint,
      );
    }
  }

  /// データ多角形を描画する (描画スケールは「相対比」、ラベル % は「絶対値」)。
  ///
  /// 【2026-06-27 v2 仕様】
  /// 「絶対上限 (Lv 50 = 100%)」を描画半径にすると、序盤 (Lv 6 〜 12%) では
  /// チャートが小さく潰れて見栄えが悪い問題への対処。
  /// 描画半径だけは **stats 内最大 progressPercent を頂点 100%** として相対比で
  /// フィットさせ、チャートいっぱいに広がるようにする。一方、頂点ラベルに表示する
  /// % 値は `progressPercent` (Lv 50 = 100% の絶対基準) のままで、ユーザーは
  /// 「自分の絶対進捗」と「ステータス間の強弱」の両方を 1 枚で読み取れる。
  /// FIFA / ウイイレ等の能力値レーダーで使われる定番パターン。
  ///
  /// 最小値ガード (0.05) で「全 Lv 0」でも多角形が点に潰れない。
  /// 全 stat が同値のときは divisor=max=raw となり全頂点 100% = 正六角形。
  void _drawDataPolygon(
    Canvas canvas, Offset center, double outer, List<double> angles,
  ) {
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = AppTheme.primary.withValues(alpha: 0.32);
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = AppTheme.primary.withValues(alpha: 0.85);
    final vertexPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = AppTheme.primary;

    // 描画スケール用の divisor: stats 内 max(progressPercent)、最低 1 (全 0 ガード)。
    final percents =
        orderedStats.map((s) => s.progressPercent).toList(growable: false);
    final maxPct = percents.fold<int>(0, math.max);
    final divisor = maxPct == 0 ? 1 : maxPct;

    final points = <Offset>[];
    for (var i = 0; i < 6; i++) {
      // 相対比: 自分の % / max(全 stat の %) → 0..1
      // 例: 全 stat 12% なら全頂点 1.0 (正六角形)、運動 12% / 学習 6% なら
      //     運動=1.0 (頂点)、学習=0.5 で描画される。
      final raw = orderedStats[i].progressPercent / divisor;
      // 最低 5% を確保 (全 0 のとき潰れない、視認性確保)
      final scale = raw.clamp(0.05, 1.0);
      final r = outer * scale;
      points.add(Offset(
        center.dx + r * math.cos(angles[i]),
        center.dy + r * math.sin(angles[i]),
      ));
    }

    final path = Path()..moveTo(points[0].dx, points[0].dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    path.close();
    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, strokePaint);

    // 各頂点に小さなドット (Lv 値の可読性向上)
    for (final p in points) {
      canvas.drawCircle(p, 2.2, vertexPaint);
    }
  }

  /// 各頂点の外側に「短縮ラベル + % 値」を 2 段で描画。
  /// 例: 「運動」「85%」 (頂点ごとに 2 行、上下中央揃え)
  void _drawLabels(
    Canvas canvas, Offset center, double outer, List<double> angles,
  ) {
    final nameStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.78),
      fontSize: 9.5,
      fontWeight: FontWeight.w600,
      height: 1.0,
    );
    final percentStyle = TextStyle(
      color: AppTheme.primary.withValues(alpha: 0.95),
      fontSize: 9.0,
      fontWeight: FontWeight.w700,
      height: 1.0,
    );
    for (var i = 0; i < 6; i++) {
      final name = orderedStats[i].name;
      final short = shortLabels[name] ?? name;
      final percent = orderedStats[i].progressPercent;

      final nameTp = TextPainter(
        text: TextSpan(text: short, style: nameStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout();
      final percentTp = TextPainter(
        text: TextSpan(text: '$percent%', style: percentStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout();

      // ラベル中心を「軸の外側 +12px」に置く (2 段ラベルの中央が軸線上に乗る)
      final r = outer + 12;
      final cx = center.dx + r * math.cos(angles[i]);
      final cy = center.dy + r * math.sin(angles[i]);
      // name: 上段、percent: 下段 (行間 1px)
      final blockHeight = nameTp.height + 1 + percentTp.height;
      final nameOrigin = Offset(cx - nameTp.width / 2, cy - blockHeight / 2);
      final percentOrigin = Offset(
        cx - percentTp.width / 2,
        cy - blockHeight / 2 + nameTp.height + 1,
      );
      nameTp.paint(canvas, nameOrigin);
      percentTp.paint(canvas, percentOrigin);
    }
  }

  @override
  bool shouldRepaint(covariant _HexagonChartPainter old) {
    if (old.orderedStats.length != orderedStats.length) return true;
    for (var i = 0; i < orderedStats.length; i++) {
      // 【2026-06-27】% 値も頂点ラベルに含まれるため、progressPercent の変化も
      // repaint トリガーに含める (本質的には level の変化で間接的にカバーされる)。
      if (old.orderedStats[i].level != orderedStats[i].level ||
          old.orderedStats[i].name != orderedStats[i].name) {
        return true;
      }
    }
    return false;
  }
}
