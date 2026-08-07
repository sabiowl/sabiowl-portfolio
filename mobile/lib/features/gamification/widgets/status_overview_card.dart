import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';

import '../../../core/theme/app_theme.dart';
import '../models/gamification_models.dart';
import 'stat_hexagon_chart.dart';
import 'stat_rank_badge.dart';
import 'stat_summary_list.dart';

/// 【2026-06-27】ステータス画面 / フレンドプロフィール画面で共有する
/// 「6 ステータス総覧カード」widget。
///
/// 構造:
/// ```
/// ╔═══════════════════════════════╗
/// ║ [avatarSection] subaru   [D] ║
/// ║                Lv. 31        ║
/// ║                              ║
/// ║ 運動 1338 (12%)    ╱╲       ║
/// ║ 学習 1213 (12%)   ╱  ╲      ║
/// ║ ...              ╱  ▣  ╲     ║
/// ╚═══════════════════════════════╝
/// ```
///
/// 設計判断:
/// - `avatarSection` は caller から渡す。stats_page では Hero + ZoomIndicator +
///   GestureDetector で全画面表示遷移、friend_profile_page では別 heroTag の
///   Hero / 全画面表示経路を caller 側で組み立てる (heroTag 競合回避)。
/// - `name` / `level` / `stats` は caller から純粋データを受ける。
/// - カードスタイルは `_StatCard` / `_CrystalInventoryCard` と統一
///   (AppTheme.card + 角丸 14 + border white 12%、padding 14、margin bottom 16)。
class StatusOverviewCard extends StatelessWidget {
  final Widget avatarSection;
  final String name;
  final int level;
  final List<CharacterStat> stats;

  /// チャートサイズ (default 140、小型機種で 130 等に調整可)。
  final double chartSize;

  /// 【2026-07-09】自画面 (stats_page) では non-null 指定で 名前横に ✏️ ペン icon
  /// を表示、tap → callback 実行 (名前変更 dialog 展開)。null (default) の時
  /// は表示なし = friend_profile_page 経由の呼出は影響なし。
  final VoidCallback? onEditName;

  /// 【2026-07-09】自画面 (stats_page) では non-null 指定でアバター下に
  /// 「キャラ変更」チップを表示、tap → callback 実行 (`/character` へ遷移)。
  /// null (default) の時は表示なし = friend_profile_page 経由の呼出は影響なし。
  final VoidCallback? onChangeCharacter;

  const StatusOverviewCard({
    super.key,
    required this.avatarSection,
    required this.name,
    required this.level,
    required this.stats,
    this.chartSize = 140,
    this.onEditName,
    this.onChangeCharacter,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1 段目: アバター (caller 提供) + 名前/Lv (Expanded) + ランクバッジ
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 【2026-07-09】アバター + 下部「キャラ変更」チップを Column で束ねる。
              // onChangeCharacter=null の時は Column 高さ増加ゼロ (SizedBox.shrink)。
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  avatarSection,
                  if (onChangeCharacter != null) ...[
                    const SizedBox(height: 6),
                    _ChangeCharacterChip(onTap: onChangeCharacter!),
                  ],
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        // 【2026-07-09】自画面のみ ✏️ ペン icon を表示。
                        // Apple HIG 44pt tap 領域確保のため minWidth/minHeight を明示。
                        if (onEditName != null)
                          IconButton(
                            onPressed: onEditName,
                            icon: Icon(
                              Icons.edit_outlined,
                              size: 16,
                              color: Colors.white.withValues(alpha: 0.60),
                            ),
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            tooltip: AppLocalizations.of(context)!.gamifStatusEditNameTooltip,
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Lv. $level',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ),
              ),
              StatRankBadge(rank: stats.overallRank),
            ],
          ),
          const SizedBox(height: 12),
          // 2 段目: 実数値+% リスト (Expanded) + 6 角形チャート (固定幅)
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: StatSummaryList(stats: stats)),
              const SizedBox(width: 8),
              StatHexagonChart(stats: stats, size: chartSize),
            ],
          ),
        ],
      ),
    );
  }
}

/// 【2026-07-09】アバター下に配置する「キャラ変更」ミニチップ。
///
/// 動線: 従来はホーム/ギルドの Drawer から `/character` へ移動 (2 タップ経路) だったが、
/// user 要望「ステータス画面のキャラアイコン近くでキャラ変更もできるように」に
/// 応じてアバター直下に配置、1 タップで character 選択画面へ。
class _ChangeCharacterChip extends StatelessWidget {
  const _ChangeCharacterChip({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: AppTheme.primary.withValues(alpha: 0.4),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.swap_horiz,
                size: 12,
                color: AppTheme.primary.withValues(alpha: 0.9),
              ),
              const SizedBox(width: 3),
              Text(
                AppLocalizations.of(context)!.gamifStatusChangeCharButton,
                style: TextStyle(
                  fontSize: 10,
                  color: AppTheme.primary.withValues(alpha: 0.9),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
