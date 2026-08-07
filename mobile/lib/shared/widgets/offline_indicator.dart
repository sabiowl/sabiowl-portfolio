import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/connectivity_indicator.dart';
import '../../core/services/connectivity_service.dart';  // 【FEAT-402】
import '../../core/theme/app_theme.dart';
import '../../l10n/app_localizations.dart';

/// 【FEAT-280】オフライン表示中 / 最新化中の薄い帯。
///
/// 【FEAT-402 (2026-06-01)】OS レベル接続判定 (`isOnlineProvider`) を
/// 統合して、OS が「online」と言っている間は橙色帯を出さない設計に変更。
/// 旧実装は事後判定 (`connectivityProvider`) のみを見ていたため、API 1 件失敗
/// で「接続環境良好なのにオフライン表示」が頻発していた。
///
/// 表示制御の優先順位:
/// - `isOnlineOS == true` + `!isFetching` → 非表示 (OS 信頼)
/// - `isOnlineOS == true` + `isFetching`  → 「最新化中...」プログレス帯
/// - `isOnlineOS == false`                 → 「オフライン表示中」橙色帯
///   (OS が確定的に offline 報告した時のみ)
///
/// サビ口調ルール遵守: 「うまくいきませんでした」等のネガティブワード回避、
/// 穏やかな丁寧体で「最新化中...」「現在オフラインで表示しています」を表現。
class OfflineIndicator extends ConsumerWidget {
  const OfflineIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final state    = ref.watch(connectivityProvider);
    // 【FEAT-402】OS レベル接続判定。事後判定 (markOffline) より優先。
    // 真のオフライン (Wi-Fi/Mobile 全切断) のみ false、それ以外は true。
    final isOnlineOS = ref.watch(isOnlineProvider);

    // 【FEAT-402】OS が online と言っている間は橙色帯を出さない。
    // 「最新化中...」は維持 (cached + fetch 並行表示の UX 価値あり)。
    if (isOnlineOS) {
      if (!state.isFetching) return const SizedBox.shrink();
      return _IndicatorBar(
        backgroundColor: AppTheme.primary.withValues(alpha: 0.18),
        textColor:       AppTheme.primary,
        icon:            Icons.sync,
        message:         l10n.sharedOfflineIndicatorFetching,
      );
    }

    // OS が明確に offline (Wi-Fi/Mobile 全切断) → 橙色帯
    return _IndicatorBar(
      backgroundColor: const Color(0xFFB45309), // amber-700 系（穏やかな警告色）
      textColor:       Colors.white,
      icon:            Icons.cloud_off_outlined,
      message:         l10n.sharedOfflineIndicatorOffline,
    );
  }
}

class _IndicatorBar extends StatelessWidget {
  const _IndicatorBar({
    required this.backgroundColor,
    required this.textColor,
    required this.icon,
    required this.message,
  });

  final Color backgroundColor;
  final Color textColor;
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      // 表示・非表示の遷移を柔らかく（Pre-mortem #5: UI 瞬き対策の一部）
      duration: const Duration(milliseconds: 220),
      child: Container(
        key: ValueKey(message),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: backgroundColor,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: textColor, size: 14),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                message,
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
