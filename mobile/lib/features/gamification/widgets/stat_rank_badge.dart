import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';

import '../../../core/theme/app_theme.dart';
import '../models/gamification_models.dart';

/// 【2026-06-27】6 ステータスの総合ランク (SS〜D) を円形バッジで表示する widget。
///
/// `stats_page` でキャラ枠 (アバター + 名前 + Lv) の右隣に配置する用途。
/// サイズはアバター (radius 36 = 72px) と整合する円形 (default 72px) で、
/// バランスを取って左寄せレイアウト全体が破綻しない設計。
///
/// ランク色:
///   SS = ゴールド (AppTheme.gold、最高位の威厳)
///   S  = オレンジ (Colors.orange、達人)
///   A  = 紫 (AppTheme.primary、熟練)
///   B  = 水色 (Colors.lightBlueAccent、中堅)
///   C  = 緑 (Colors.greenAccent、修行中)
///   D  = 落ち着いた白 (Colors.white60、まだこれから — Sabi 哲学整合)
///
/// D ランクをグレーアウトせず白で表示するのは、Sabiowl の「停滞も休息も肯定」
/// 哲学に整合するため。「ダメ」ではなく「これから伸びる人」として描く。
class StatRankBadge extends StatelessWidget {
  final StatRank rank;
  final double size;

  const StatRankBadge({
    super.key,
    required this.rank,
    this.size = 72,
  });

  Color get _rankColor {
    switch (rank) {
      case StatRank.ss: return AppTheme.gold;
      case StatRank.s:  return Colors.orange;
      case StatRank.a:  return AppTheme.primary;
      case StatRank.b:  return Colors.lightBlueAccent;
      case StatRank.c:  return Colors.greenAccent;
      case StatRank.d:  return Colors.white60;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final color = _rankColor;
    // SS は文字が 2 桁で詰まりやすいため fontSize を 1 段下げる
    final fontSize = rank == StatRank.ss ? 24.0 : 30.0;
    return Semantics(
      label: l10n.gamifStatRankBadgeSemantics(rank.label),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 2),
              boxShadow: [
                // SS は淡くハロー効果で「特別感」を演出 (他ランクは shadow なし)
                if (rank == StatRank.ss)
                  BoxShadow(
                    color: color.withValues(alpha: 0.35),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              rank.label,
              style: TextStyle(
                color: color,
                fontSize: fontSize,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
                height: 1.0,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.gamifStatRankBadgeLabel,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
