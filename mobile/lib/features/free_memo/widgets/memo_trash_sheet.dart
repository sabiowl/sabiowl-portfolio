// 【FEAT-500 レビュー §C1 (2026-07-26)】削除メモ (trash) Bottom Sheet。
// memo_page.dart から分離、責務単一化 (~1600 行の巨大 file を 4 分割の 1 つ)。
//
// AppBar 右上のゴミ箱 icon タップで開く。deleted_at IS NOT NULL のメモを
// 一覧表示、各 item で [復元] / [完全削除] 操作を提供 (FEAT-502 で archived_at
// → deleted_at に意味分離、user 削除は deleted_at 判定)。
//
// 設計:
//   - Bottom Sheet 90% height (isScrollControlled: true + Padding)
//   - deletedMemosProvider (StateNotifier.autoDispose) で fetch
//   - 【FEAT-503 アクション6 (2026-07-26)】復元 / 完全削除は楽観更新:
//     先に deletedMemosProvider.optimisticRemove(id) で該当 item だけ即除去
//     (シート全体 spinner・スクロール位置消失・load-more 済ページ消失を防ぐ)、
//     API は await して失敗時のみ refresh() で再同期 + SnackBar (Pre-mortem S1)。
//   - Empty state: 「削除したメモはありません 🪶」
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../models/free_memo.dart';
import '../providers/free_memo_provider.dart';

class MemoTrashSheet extends ConsumerStatefulWidget {
  const MemoTrashSheet({super.key});

  @override
  ConsumerState<MemoTrashSheet> createState() => _MemoTrashSheetState();
}

class _MemoTrashSheetState extends ConsumerState<MemoTrashSheet> {
  Future<void> _handleRestore(FreeMemo memo) async {
    final l10n = AppLocalizations.of(context)!;
    HapticFeedback.selectionClick();
    // 【FEAT-503 アクション6】楽観更新: trash から即除去 (シート全体 spinner を出さない)。
    ref.read(deletedMemosProvider.notifier).optimisticRemove(memo.id);
    try {
      // restoreMemo は内部で active 一覧を再取得 + _setMemos するため、
      // ここで active 側の refresh は不要。
      await ref.read(freeMemoNotifierProvider.notifier).restoreMemo(memo.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.freeMemoTrashSheetRestoreSuccessSnack),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      // Pre-mortem S1: 失敗時は実 DB 状態に再同期 (楽観除去を取り消す) + 案内。
      await ref.read(deletedMemosProvider.notifier).refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.freeMemoTrashSheetRestoreErrorSnack),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// 【FEAT-498 §2.6 (2026-07-31)】trash 全件 完全削除。
  ///
  /// BUG-138 準拠 confirm dialog (左 = Cancel、右 = Action) + 件数明示で
  /// Pre-mortem S4「bulk purge の暴発」を予防。Backend の purge-all/
  /// endpoint は player scope 分離済 + trash (deleted_at IS NOT NULL) 限定。
  Future<void> _handlePurgeAll(int purgeCount) async {
    final l10n = AppLocalizations.of(context)!;
    HapticFeedback.selectionClick();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(l10n.freeMemoTrashSheetPurgeAllConfirmTitle,
            style: const TextStyle(color: Colors.white)),
        content: Text(
          l10n.freeMemoTrashSheetPurgeAllConfirmBody(purgeCount),
          style: const TextStyle(color: Colors.white70),
        ),
        // 【FEAT-498 §2.6 hotfix (2026-07-31)】actionsAlignment 明示 = 短いラベル
        // (「やめる」「完全に削除する」) で OverflowBar が縦積み fallback しないよう
        // 保証。単一 purge dialog (line 62-90) と button 文言を統一。
        actionsAlignment: MainAxisAlignment.end,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.freeMemoDialogCancelAction),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.freeMemoTrashSheetPurgeAction),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    try {
      final actualDeleted =
          await ref.read(deletedMemosProvider.notifier).purgeAllArchived();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.freeMemoTrashSheetPurgeAllSuccessSnack(actualDeleted)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      // Pre-mortem S1 同様: 失敗時は実 DB 状態に再同期 (楽観除去が既に走っていれば取り消し)。
      await ref.read(deletedMemosProvider.notifier).refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.freeMemoTrashSheetPurgeAllErrorSnack),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _handlePurge(FreeMemo memo) async {
    final l10n = AppLocalizations.of(context)!;
    HapticFeedback.selectionClick();
    // BUG-138 準拠: Cancel 左 (「やめる」)、Action 右 (「完全に削除する」赤色)
    final preview = memo.text.length > 30
        ? '${memo.text.substring(0, 30)}…'
        : memo.text;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(l10n.freeMemoTrashSheetPurgeSingleConfirmTitle,
            style: const TextStyle(color: Colors.white)),
        content: Text(
          l10n.freeMemoTrashSheetPurgeSingleConfirmBody(preview),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.freeMemoDialogCancelAction),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.freeMemoTrashSheetPurgeAction),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    // 【FEAT-503 アクション6】楽観更新: trash から即除去。
    ref.read(deletedMemosProvider.notifier).optimisticRemove(memo.id);
    try {
      await ref.read(freeMemoNotifierProvider.notifier).purgeMemo(memo.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.freeMemoTrashSheetPurgeSingleSuccessSnack),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      // Pre-mortem S1: 失敗時は実 DB 状態に再同期 (楽観除去を取り消す) + 案内。
      await ref.read(deletedMemosProvider.notifier).refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.freeMemoTrashSheetPurgeSingleErrorSnack),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final stateAsync = ref.watch(deletedMemosProvider);
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return FractionallySizedBox(
      heightFactor: 0.9,
      child: Padding(
        padding: EdgeInsets.only(bottom: viewInsets),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── ヘッダー ────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Text(
                    l10n.freeMemoTrashSheetTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  // 【FEAT-498 §2.6 hotfix (2026-07-31)】旧: header 右端に配置
                  // (× button 隣接) していたが user 報告「× に近く誤操作リスク」で
                  // memo リスト最下部に移動 (_buildList 末尾)。header は「削除した
                  // メモ」タイトル + × のみのシンプル構成に戻す。
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.pop(context),
                    tooltip: l10n.commonClose,
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            // ── メモ一覧 or 空状態 or ローディング ────────────
            Expanded(
              child: stateAsync.when(
                loading: () => const Center(
                  child: CircularProgressIndicator(color: AppTheme.primary),
                ),
                error: (e, _) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.freeMemoLoadErrorSabi_message,
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () => ref
                            .read(deletedMemosProvider.notifier)
                            .refresh(),
                        child: Text(l10n.freeMemoRetryButton),
                      ),
                    ],
                  ),
                ),
                data: (state) => state.memos.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.delete_outline,
                                  size: 48, color: Colors.white24),
                              const SizedBox(height: 12),
                              Text(
                                l10n.freeMemoTrashSheetEmptySabi_message,
                                style: const TextStyle(
                                    color: Colors.white38, fontSize: 14),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _buildList(state),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 【FEAT-498 §2.5 (2026-07-26)】memos 一覧 + 「もっと読み込む」button。
  /// itemCount = memos.length + (hasMore ? 1 : 0) で末尾に load-more row を差し込む。
  /// Sabi 哲学「押し付けない」との整合: button 文言「もっと読み込む 🪶」の柔らか表現、
  /// 押さないと表示切れる = user 主体で「もっと見たいなら見る」姿勢。
  Widget _buildList(TrashState state) {
    final showLoadMore = state.hasMore;
    // 【FEAT-498 §2.6 hotfix (2026-07-31)】purge-all footer を最下部に配置。
    // 旧: header 右端に配置 → user 報告「× に近く誤操作リスク」→ リスト最下部に
    // 移動 (誤 tap 距離を最大化、Pre-mortem S4 の core 対応)。memos が空でない
    // 時のみ表示 = 削除するものが無い時は現れない (empty 分岐で _buildList 自体
    // 呼ばれないため、本 method 到達時点で memos 非空が保証されている → 常に +1)。
    final itemCount = state.memos.length + (showLoadMore ? 1 : 0) + 1;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: itemCount,
      separatorBuilder: (_, __) => const Divider(
        color: Colors.white12,
        height: 1,
        indent: 16,
        endIndent: 16,
      ),
      itemBuilder: (_, i) {
        // purge-all footer は最終 index に固定 (load-more の後、または memos 直後)
        if (i == itemCount - 1) {
          return _buildPurgeAllFooter(state.memos.length);
        }
        if (showLoadMore && i == state.memos.length) {
          return _buildLoadMoreRow(state.isLoadingMore);
        }
        return _buildMemoItem(state.memos[i]);
      },
    );
  }

  /// 【FEAT-498 §2.6 hotfix (2026-07-31)】trash 一括完全削除の footer button。
  ///
  /// header ではなく scroll 最下部に配置することで:
  ///   - × close button と物理距離を最大化 (誤 tap リスク解消、user 報告 2026-07-31)
  ///   - user が「trash の中身を確認 → 最下部まで見た → 明示的に action」の順で
  ///     操作する自然な導線 (「見ずに一括削除」を構造的に予防)
  ///   - Gmail / Notion 等の trash UI と同型 (最下部 destructive action pattern)
  Widget _buildPurgeAllFooter(int loadedCount) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: OutlinedButton.icon(
        icon: const Icon(Icons.delete_sweep_outlined,
            size: 18, color: Colors.red),
        label: Text(
          l10n.freeMemoTrashSheetPurgeAllButton,
          style: const TextStyle(color: Colors.red, fontSize: 13),
        ),
        onPressed: () => _handlePurgeAll(loadedCount),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: Colors.red.withValues(alpha: 0.5)),
          padding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );
  }

  Widget _buildLoadMoreRow(bool isLoading) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.primary,
                ),
              )
            : TextButton(
                onPressed: () =>
                    ref.read(deletedMemosProvider.notifier).loadMore(),
                child: Text(
                  AppLocalizations.of(context)!.freeMemoTrashSheetLoadMoreButton,
                  style: TextStyle(
                    color: AppTheme.primary.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildMemoItem(FreeMemo memo) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            memo.text,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // 復元 button (safe action、通常色)
              TextButton.icon(
                icon: Icon(Icons.restore,
                    size: 18, color: AppTheme.primary.withValues(alpha: 0.9)),
                label: Text(
                  l10n.freeMemoTrashSheetRestoreButton,
                  style: TextStyle(
                    color: AppTheme.primary.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: () => _handleRestore(memo),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 8),
              // 完全削除 button (destructive、赤色)
              TextButton.icon(
                icon: Icon(Icons.delete_forever,
                    size: 18, color: Colors.red.shade400),
                label: Text(
                  l10n.freeMemoTrashSheetDeleteForeverButton,
                  style: TextStyle(
                    color: Colors.red.shade400,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: () => _handlePurge(memo),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
