import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../../core/theme/app_theme.dart';
import '../../l10n/app_localizations.dart';

/// 【FEAT-202】読み込み中の温度統一用ウィジェット群。
///
/// 設計原則:
/// - **本物のスケルトン**: 実カードレイアウトの形状を Shimmer で描く。回転する円ではなく、
///   「もうすぐここに、これくらいのカードが来ます」という形を見せる
/// - **サビが寄り添う温度**: 全画面ローディングでは [SabiWaitingPanel] でサビ画像 + 短文
/// - **共通プリミティブ**: [SabiSkeletonBox] を組み合わせて画面別レイアウトを作る
///
/// `SabiErrorChip`（エラー時の温度統一）と対をなす設計で、
/// 「ロードフェーズ」と「エラーフェーズ」の両方で「サビが寄り添うアプリ」の世界観を保つ。

/// 共通スケルトンプリミティブ。指定サイズの灰色プレースホルダを Shimmer で表示。
class SabiSkeletonBox extends StatelessWidget {
  const SabiSkeletonBox({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius = 8,
  });

  final double width;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor:      Colors.white.withValues(alpha: 0.06),
      highlightColor: Colors.white.withValues(alpha: 0.12),
      period:         const Duration(milliseconds: 1500),
      child: Container(
        width:  width,
        height: height,
        decoration: BoxDecoration(
          color:        Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
      ),
    );
  }
}

/// 習慣カード 1 枚分のスケルトン（アイコン + 2 行テキスト + 完了ボタン）。
class HabitCardSkeleton extends StatelessWidget {
  const HabitCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin:  const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppTheme.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: const [
          SabiSkeletonBox(width: 36, height: 36, borderRadius: 18),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SabiSkeletonBox(width: 140, height: 14),
                SizedBox(height: 6),
                SabiSkeletonBox(width: 80, height: 10),
              ],
            ),
          ),
          SabiSkeletonBox(width: 28, height: 28, borderRadius: 14),
        ],
      ),
    );
  }
}

/// 習慣リスト全体のスケルトン（カード `count` 枚分）。
class HabitListSkeleton extends StatelessWidget {
  const HabitListSkeleton({super.key, this.count = 3});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(count, (_) => const HabitCardSkeleton()),
    );
  }
}

/// フレンド一覧のスケルトン（アバター丸 + 2 行テキスト × `count`）。
class FriendListSkeleton extends StatelessWidget {
  const FriendListSkeleton({super.key, this.count = 4});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        count,
        (_) => Container(
          margin:  const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color:        AppTheme.card,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: const [
              SabiSkeletonBox(width: 44, height: 44, borderRadius: 22),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SabiSkeletonBox(width: 120, height: 13),
                    SizedBox(height: 6),
                    SabiSkeletonBox(width: 60, height: 10),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 認証画面など、長時間待機する全画面ローディング用。
/// サビ画像 + 短文 + 細い CircularProgressIndicator の組み合わせで
/// Render コールドスタート 30〜60 秒の沈黙を「サビが寄り添う温度」に保つ。
class SabiWaitingPanel extends StatelessWidget {
  const SabiWaitingPanel({
    super.key,
    this.message,
  });

  /// 表示する待機メッセージ。
  ///
  /// 【FEAT-489 Phase 2D】default parameter は `AppLocalizations` を参照できないため
  /// nullable にして、`build()` 内で `sharedSabiWaitingPanelDefaultSabi_message` に
  /// fallback する。
  final String? message;

  @override
  Widget build(BuildContext context) {
    final text =
        message ?? AppLocalizations.of(context)!.sharedSabiWaitingPanelDefaultSabi_message;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 【FEAT-316】sabi_normal.png → sabi_unified.png に統一（PixelLab 92×92 ドット絵）。
          // Nearest Neighbor 補間でドット感維持。
          SizedBox(
            width:  96,
            height: 96,
            child: Image.asset(
              'assets/images/sabi/sabi_unified.webp',
              fit: BoxFit.contain,
              filterQuality: FilterQuality.none,
              errorBuilder: (_, __, ___) =>
                  const Center(child: Text('🪶', style: TextStyle(fontSize: 48))),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              text,
              style: const TextStyle(
                color:    Colors.white70,
                fontSize: 13,
                height:   1.6,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: 24, height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor:  AlwaysStoppedAnimation(
                Colors.white.withValues(alpha: 0.4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
