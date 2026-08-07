import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../features/habits/models/habit.dart' show HabitReward;
import '../../l10n/app_localizations.dart';

/// 【FEAT-498 §2.3 (2026-07-31)】報酬演出の強度制御。
///
/// - `normal`: 習慣完了 / タイムライン達成 / かけら獲得の主軸経路 (gold + bolt アイコン)
/// - `subtle`: memo 変換 (+3 EXP) の control 経路 (primary tint + prefix label)。
///
/// 目的: 「Sabiowl で EXP が入る = この overlay で表示される」という単一語彙を
/// 確立しつつ、+3 EXP に対して習慣完了と同レベルの演出を出して「報酬インフレ感」を
/// 招くのを防ぐ (Pre-mortem S1)。
enum RewardIntensity { normal, subtle }

/// 習慣達成・タイムライン達成時に画面下部に表示するフローティングトースト。
///
/// [OverlayEntry] に挿入して使用する。スライドアップ + フェードイン (200 ms) で登場し、
/// 1.2 秒後にフェードアウト (200 ms) で退場する（合計約 1.6 秒）。
///
/// BUG-S: 旧実装は 2.8 秒間表示していたため、複数 habit を連続タップした際に
/// 2 件目のトーストが 1 件目を即座に上書きし、最初の達成感が失われていた。
/// 表示時間を 1.2 秒に短縮し、上書きが起こる時間窓を縮めることで体感を改善する
/// （軽微改善・抜本的な FIFO キュー化は将来課題）。
///
/// 【FEAT-498 §2.3 (2026-07-31)】memo 変換の +3 EXP を「習慣完了 / かけら獲得と
/// 同じ RewardToastOverlay レイヤー」に寄せるため [intensity] + [leadingText] を追加。
class RewardToastOverlay extends StatefulWidget {
  const RewardToastOverlay({
    super.key,
    required this.reward,
    this.intensity = RewardIntensity.normal,
    this.leadingText,
  });

  final HabitReward reward;

  /// 演出強度。default = normal (既存挙動)、subtle = memo 変換等の軽量経路。
  final RewardIntensity intensity;

  /// 【FEAT-498 §2.3】subtle 経路で reward 表示の前に付ける prefix ラベル
  /// (例: 「予定 に決めました 」)。normal 経路では null 推奨 (無視される)。
  final String? leadingText;

  @override
  State<RewardToastOverlay> createState() => _RewardToastOverlayState();
}

class _RewardToastOverlayState extends State<RewardToastOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double>   _opacity;
  late final Animation<Offset>   _slide;
  late final Animation<double>   _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide   = Tween<Offset>(
      begin: const Offset(0, 0.6),
      end:   Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    // 【FEAT-498 §2.3】subtle 経路の「brief scale-up」演出用 (spec §2.3)。
    // normal 経路では build 側で無視するため既存挙動に影響しない。
    _scale = Tween<double>(begin: 0.88, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));

    _ctrl.forward();
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) _ctrl.reverse();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final isSubtle = widget.intensity == RewardIntensity.subtle;
    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned(
              bottom: 72 + bottomPad,
              left:   0,
              right:  0,
              child: Center(
                child: FadeTransition(
                  opacity: _opacity,
                  child: SlideTransition(
                    position: _slide,
                    // 【FEAT-498 §2.3】subtle 経路のみ scale-up 追加 (normal は既存挙動維持)
                    child: isSubtle
                        ? ScaleTransition(scale: _scale, child: _buildCard())
                        : _buildCard(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard() {
    return widget.intensity == RewardIntensity.subtle
        ? _buildSubtleCard()
        : _buildNormalCard();
  }

  Widget _buildNormalCard() {
    final l10n = AppLocalizations.of(context)!;
    final hasBonus   = widget.reward.bonusExp > 0;
    final hasDiamond = widget.reward.diamondEarned;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
      decoration: BoxDecoration(
        color:        const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: const Color(0xFFFFD700).withValues(alpha: 0.30),
        ),
        boxShadow: [
          BoxShadow(
            color:      const Color(0xFFFFD700).withValues(alpha: 0.12),
            blurRadius: 18,
          ),
          BoxShadow(
            color:      Colors.black.withValues(alpha: 0.40),
            blurRadius: 12,
            offset:     const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bolt_rounded, color: Color(0xFFFFD700), size: 17),
          const SizedBox(width: 5),
          Text(
            '+${widget.reward.totalExp} EXP',
            style: const TextStyle(
              color:         Color(0xFFFFD700),
              fontSize:      15,
              fontWeight:    FontWeight.bold,
              letterSpacing: 0.3,
            ),
          ),
          if (hasBonus) ...[
            const SizedBox(width: 5),
            Text(
              l10n.sharedRewardToastBonusLabel(widget.reward.bonusExp),
              style: TextStyle(
                color:    const Color(0xFFFFD700).withValues(alpha: 0.65),
                fontSize: 11,
              ),
            ),
          ],
          if (hasDiamond) ...[
            const SizedBox(width: 14),
            Container(width: 1, height: 16, color: Colors.white12),
            const SizedBox(width: 14),
            const Text('💎', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 4),
            const Text(
              '+1',
              style: TextStyle(
                color:      Colors.lightBlueAccent,
                fontSize:   14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 【FEAT-498 §2.3 (2026-07-31)】subtle 経路 (memo 変換等) の control 表示。
  ///
  /// normal 経路 (gold + bolt) との差別化:
  /// - サイズ縮小 (padding 16/8、border radius 20)
  /// - primary tint (gold ではなく purple)、報酬インフレ感を抑制
  /// - leadingText prefix (「予定 に決めました 」等) + 「+N EXP 🪶」を 1 本の文章化
  /// - Sabi マーカー 🪶 で「あなたのペースで進んでいますよ」の柔らかいトーン
  Widget _buildSubtleCard() {
    final leading = widget.leadingText ?? '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color:        const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.35),
        ),
        boxShadow: [
          BoxShadow(
            color:      AppTheme.primary.withValues(alpha: 0.10),
            blurRadius: 12,
          ),
          BoxShadow(
            color:      Colors.black.withValues(alpha: 0.30),
            blurRadius: 8,
            offset:     const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading.isNotEmpty) ...[
            Text(
              leading,
              style: const TextStyle(
                color:      Colors.white,
                fontSize:   13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            '+${widget.reward.totalExp} EXP',
            style: TextStyle(
              color:         AppTheme.primary,
              fontSize:      13,
              fontWeight:    FontWeight.bold,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 4),
          const Text(
            '🪶',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}
