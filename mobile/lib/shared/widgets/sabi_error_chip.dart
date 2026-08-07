import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// サビ風の非ブロッキング・エラー表示チップ（紳士敬語トーン）。
///
/// 用途: `AsyncValue.when` の `error:` ブランチで `const SizedBox.shrink()` を
/// 返していた箇所の置き換え。「データが無い」と「通信に失敗した」を
/// ユーザーに区別させるための小さな注意喚起を担う。
///
/// CLAUDE.md のサビキャラ方針（紳士的フクロウ単一トーン）に従い、
/// メッセージは敬体・🪶 マーカー付き。デフォルト文言は通信エラー想定。
///
/// 例:
/// ```dart
/// ref.watch(someProvider).when(
///   data: (v) => Content(v),
///   loading: () => const CircularProgressIndicator(),
///   error: (e, _) => const SabiErrorChip(),
/// )
/// ```
class SabiErrorChip extends StatelessWidget {
  /// 表示するメッセージ。null の場合はデフォルトの汎用エラー文を使用。
  final String? message;

  /// 「再読み込み」アクション。null の場合はリトライアイコンを表示しない。
  final VoidCallback? onRetry;

  /// チップ周囲の余白。Sliver や Card 内部で微調整する用途。
  final EdgeInsetsGeometry padding;

  /// 中央寄せにするか（リスト要素の代替表示で利用）。
  final bool centered;

  const SabiErrorChip({
    super.key,
    this.message,
    this.onRetry,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    this.centered = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🪶', style: TextStyle(fontSize: 14)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message ?? l10n.sharedSabiErrorChipDefaultMessage,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.6),
                height: 1.4,
              ),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 6),
            InkWell(
              onTap: onRetry,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.refresh,
                  size: 16,
                  color: Colors.white.withValues(alpha: 0.8),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return Padding(
      padding: padding,
      child: centered ? Center(child: chip) : chip,
    );
  }
}

/// `CustomScrollView` 内で使う Sliver ラッパー。
///
/// 例:
/// ```dart
/// CustomScrollView(
///   slivers: [
///     ref.watch(provider).when(
///       data: (v) => SliverList(...),
///       loading: () => const SliverToBoxAdapter(child: ...),
///       error: (e, _) => const SabiErrorChipSliver(),
///     ),
///   ],
/// )
/// ```
class SabiErrorChipSliver extends StatelessWidget {
  final String? message;
  final VoidCallback? onRetry;

  const SabiErrorChipSliver({
    super.key,
    this.message,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: SabiErrorChip(
        message: message,
        onRetry: onRetry,
      ),
    );
  }
}
