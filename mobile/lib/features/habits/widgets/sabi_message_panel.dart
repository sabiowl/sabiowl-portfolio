import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers/time_segment_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/time_segment_theme.dart';
import '../../../shared/widgets/sabi_icon.dart';
import '../../calendar/providers/calendar_provider.dart'
    show streakDataProvider; // P2-3 マイルストーンチップ
// 【SEC-11】SabiNavigationOverlay は 2026-05-15 機能廃止で削除済み。サビアイコンの
// タップでオーバーレイを起動していたが、本ファイルでは長押し休息日登録のみに縮減。
// 【FEAT-424 (2026-06-10)】休息日機能廃止に伴い、長押し休息日登録も撤去。

/// Sabi（フクロウキャラクター）のメッセージバブルを表示するウィジェット。
/// 時間帯に応じてアイコンの光彩色が変化する。
/// [emotion] で表情画像が切り替わる（デフォルト: [SabiEmotion.normal]）。
class SabiMessagePanel extends ConsumerStatefulWidget {
  const SabiMessagePanel({
    super.key,
    required this.message,
    this.emotion = SabiEmotion.normal,
  });

  final String message;
  final SabiEmotion emotion;

  @override
  ConsumerState<SabiMessagePanel> createState() => _SabiMessagePanelState();
}

class _SabiMessagePanelState extends ConsumerState<SabiMessagePanel>
    with TickerProviderStateMixin {
  // ── ブリージングアニメーション（0.97 ↔ 1.0 を 0.9 秒で反復） ─────────────
  late final AnimationController _breathController;
  late final Animation<double> _breathAnim;

  // 【SEC-11】マイクバッジ + ヒントバッジ + パルスアニメーション + タップ用ヒントは
  // SabiNavigationOverlay 起動の視覚誘導用だったため、本機能廃止に伴い削除。
  // 【FEAT-424 (2026-06-10)】長押し休息日登録も撤去済み。

  // ── メッセージ折り畳み ────────────────────────────────────────────────
  bool _isExpanded = false;

  // ── プリキャッシュ（初回のみ実行）───────────────────────────────────────
  // 【FEAT-225】didChangeDependencies は親 InheritedWidget の更新で呼ばれるため、
  // provider 状態が変わるたびに全 10 枚の再キャッシュリクエストが走っていた。
  // _precached フラグで初回のみ実行するよう修正。
  bool _precached = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_precached) return;
    _precached = true;
    // 全アセットを事前ロードしてチラつきを防ぐ
    for (final assetPath in kSabiAssetMap.values) {
      precacheImage(AssetImage(assetPath), context);
    }
  }

  @override
  void initState() {
    super.initState();

    // ブリージングアニメーション設定
    // 【FEAT-225】900ms → 1800ms に延長（バッテリー消費削減）。
    // スケール 0.97〜1.0 の微小変化は 30fps 相当でも視認不可能なほど滑らかで、
    // 60fps 描画は過剰品質。ホーム常駐ウィジェットの GPU 負荷を実質半減させる。
    _breathController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _breathAnim = Tween<double>(begin: 0.97, end: 1.0).animate(
      CurvedAnimation(parent: _breathController, curve: Curves.easeInOut),
    );

    // 【SEC-11】マイクバッジ パルスアニメーションと "タップ" ヒントの遅延表示は
    // SabiNavigationOverlay 起動誘導用だったため、本機能廃止に伴い init からも撤去。
  }

  @override
  void dispose() {
    _breathController.dispose();
    super.dispose();
  }

  // ── メッセージ本体（折り畳み対応） ───────────────────────────────────────
  static const _kMessageStyle = TextStyle(
    color: Colors.white70,
    fontSize: 14,
    height: 1.5,
  );
  static const _kCollapseLines = 4;

  Widget _buildMessageBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 利用可能な横幅でテキストが何行になるかを測定
        final tp = TextPainter(
          text: TextSpan(text: widget.message, style: _kMessageStyle),
          maxLines: _kCollapseLines,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);

        final needsCollapse = tp.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // テキスト本体（AnimatedSize で高さ変化を滑らか化）
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              child: Text(
                widget.message,
                maxLines:
                    needsCollapse && !_isExpanded ? _kCollapseLines : null,
                overflow:
                    needsCollapse && !_isExpanded
                        ? TextOverflow.clip
                        : TextOverflow.visible,
                style: _kMessageStyle,
              ),
            ),

            // 折り畳みトグルボタン（必要時のみ表示）
            if (needsCollapse) ...[
              const SizedBox(height: 6),
              GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _isExpanded = !_isExpanded);
                },
                behavior: HitTestBehavior.opaque,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _isExpanded
                          ? AppLocalizations.of(context)!.habitSabiPanelCollapse
                          : AppLocalizations.of(context)!.habitSabiPanelExpand,
                      style: const TextStyle(
                        color: AppTheme.primaryLight,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      _isExpanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 15,
                      color: AppTheme.primaryLight,
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final segTheme = TimeSegmentTheme.of(ref.watch(timeSegmentProvider));

    // 時間帯アクセントカラー
    final glowColor = segTheme.accentColor.withValues(
      alpha: segTheme.sabiGlowOpacity,
    );
    final borderColor = segTheme.accentColor.withValues(alpha: 0.50);

    // 【FEAT-225】RepaintBoundary でホーム他レイヤーへの repaint 波及を遮断。
    // 内部の _breathAnim / AnimatedContainer による再描画は
    // この境界内に閉じ込められ、親 ListView や WorldFrameSection に伝播しない。
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Sabi アイコン ──
            // ── ブリージングアニメーション ────────
            AnimatedBuilder(
              animation: _breathAnim,
              builder:
                  (_, child) =>
                      Transform.scale(scale: _breathAnim.value, child: child),
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: borderColor, width: 1.0),
                  boxShadow: [
                    BoxShadow(
                      color: glowColor,
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: SabiIconAnimated(emotion: widget.emotion, size: 52),
              ),
            ),
            const SizedBox(width: 10),
            // ── メッセージバブル ───────────────────────────────────────
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.background,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(4),
                    topRight: Radius.circular(16),
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                  ),
                  border: Border.all(
                    color: AppTheme.primaryLight.withValues(alpha: 0.35),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Sabi',
                      style: TextStyle(
                        color: AppTheme.primaryLight,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _buildMessageBody(),
                    // P2-3: ストリークマイルストーンチップ。
                    // 現在の連続日数が 1 日以上のとき、次のマイルストーン (3/7/14/30/50/100/365)
                    // までの残り日数を静かに提示する。streak == 0 のときは非表示。
                    const _MilestoneChip(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── ストリーク マイルストーンチップ（P2-3 追補） ──────────────────────────────
//
// `streakDataProvider` の `currentStreak` を購読し、次のマイルストーンまでの
// 残り日数を表示する。データ未取得・通信失敗・streak 0 のときは何も描画しない
// （メッセージバブルの高さを変動させない静的フットプリント）。
class _MilestoneChip extends ConsumerWidget {
  const _MilestoneChip();

  // sabi_dialogue.yaml の streak.milestones と整合。
  static const List<int> _kMilestones = [3, 7, 14, 30, 50, 100, 365];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final streakAsync = ref.watch(streakDataProvider);
    return streakAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (data) {
        final streak = data.currentStreak;
        if (streak < 1) return const SizedBox.shrink();
        return _renderChip(context, streak);
      },
    );
  }

  Widget _renderChip(BuildContext context, int streak) {
    // 次のマイルストーンを検索。すべて超過していれば -1。
    final int next = _kMilestones.firstWhere(
      (m) => m > streak,
      orElse: () => -1,
    );

    final l10n = AppLocalizations.of(context)!;
    final String label;
    if (next == -1) {
      // 365 日超 — 圧巻の継続。
      label = l10n.habitSabiPanelStreakOngoing(streak);
    } else {
      final remaining = next - streak;
      label = l10n.habitSabiPanelMilestoneHint(remaining, next);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppTheme.primary.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: AppTheme.primary.withValues(alpha: 0.30),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.local_fire_department,
              size: 12,
              color: AppTheme.primaryLight,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: AppTheme.primaryLight.withValues(alpha: 0.95),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
