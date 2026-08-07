import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/error_formatter.dart';  // 【FEAT-407】生例外リーク防止 (_extractErrorMessage 置換)
// 【FEAT-447 (2026-06-20)】go_router / app_router import 削除:
// FEAT-446 でメッセージ動線 (context.push(AppRoutes.messages...)) を撤去した結果、
// 本ファイルから push 経路がゼロになり unused import 警告化していた。
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/character_asset.dart';            // 【BUG-100 followup】設定キャラアバター描画
import '../../../core/utils/friend_id_formatter.dart';         // 【2026-07-02】12 桁化 + 4-4-4 表示
import '../../../shared/widgets/sabi_loading_skeleton.dart';   // FEAT-230
import '../../gamification/widgets/character_fullscreen_view.dart';  // 【2026-06-27】キャラ全画面表示
import '../../gamification/widgets/character_zoom_indicator.dart';   // 【2026-06-27】ズームアイコン
import '../../gamification/widgets/status_overview_card.dart';       // 【2026-06-27】ステータス総覧カード
import '../../../l10n/app_localizations.dart';
import '../models/social_models.dart';
import '../providers/social_provider.dart';

class FriendProfilePage extends ConsumerStatefulWidget {
  final int playerId;
  const FriendProfilePage({super.key, required this.playerId});

  @override
  ConsumerState<FriendProfilePage> createState() => _FriendProfilePageState();
}

class _FriendProfilePageState extends ConsumerState<FriendProfilePage> {
  bool _sendingGift = false;
  /// 【2026-07-02】送信成功時に true にセットする optimistic フラグ。
  /// Backend の `hasGiftedToday` と OR して判定することで、
  /// ・profile 初期取得時は Backend 値を反映
  /// ・送信直後は provider の再取得を待たずに即座に非活性化
  /// を両立する。失敗時は false のまま (元々 false なので rollback 不要)。
  bool _optimisticGiftedToday = false;

  /// 【FEAT-451 (2026-06-20) → 2026-07-02 拡張】フレンドに XP ブースト
  /// (1.5倍 / 15min) を贈る確認ダイアログ。
  ///
  /// 旧 (〜FEAT-450): ダイヤ 1/2/3 個から選択する amount selector UI。
  /// 中間 (FEAT-451〜): XP ブースト 1 個固定、per-sender 1/day (全体で 1 個)。
  /// 新 (2026-07-02): per-friend 1/day (フレンドごとに毎日 1 個ずつ)。
  Future<void> _showGiftDialog(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(
          l10n.socialFriendProfilePageGiftDialogTitle,
          style: const TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.socialFriendProfilePageGiftDialogBody,
              style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.6),
            ),
            const SizedBox(height: 10),
            // 【2026-07-02】per-friend 1/day に仕様変更したため文言も修正。
            // 「1 日 1 個」→「フレンドお一人ごとに、1 日 1 個」
            Text(
              l10n.socialFriendProfilePageGiftDialogNoteSabi_message,
              style: const TextStyle(color: Colors.white38, fontSize: 11, height: 1.6),
            ),
          ],
        ),
        // 【BUG-138 (2026-06-17)】Cancel 左 / Action 右の配置統一。
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.socialFriendProfilePageGiftDialogCancelButton,
                style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
            child: Text(l10n.socialFriendProfilePageGiftDialogConfirmButton),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _sendingGift = true);
    try {
      final result = await ref.read(socialServiceProvider).sendGift(widget.playerId);
      if (!mounted) return;
      // 【2026-07-02】送信成功で即座に optimistic フラグ ON。
      // これで戻り即座にボタンが非活性化 (grey + check アイコン + 「本日は贈り終えました」)。
      setState(() => _optimisticGiftedToday = true);
      // 【FEAT-490 (2026-07-09)】gift 内訳を SnackBar で表示 (XP boost 常時 +
      // coins/charges は受け取り側の 3 senders/日 cap 次第)。
      // cap 到達時は「XP ブーストのみ」の穏やかな文面に切り替え。
      // 【FEAT-489 Phase 2D】各パーツを arb key 化し、実行時に ' + ' で結合して
      // socialFriendProfilePageGiftSuccessSabi_message の {joined} に流し込む。
      final parts = <String>[l10n.socialGiftRewardXpBoost];
      if (result.coinsAwarded > 0) {
        parts.add(l10n.socialGiftRewardCoins(result.coinsAwarded));
      }
      if (result.chargesAwarded > 0) {
        parts.add(l10n.socialGiftRewardBattleCharges(result.chargesAwarded));
      }
      final joined = parts.join(' + ');
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.socialFriendProfilePageGiftSuccessSabi_message(joined)),
          backgroundColor: AppTheme.primary,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      // 【FEAT-407】_extractErrorMessage → formatApiError に統一
      final msg = formatApiError(e);
      messenger.showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: Colors.red.withValues(alpha: 0.85),
        ),
      );
    } finally {
      if (mounted) setState(() => _sendingGift = false);
    }
  }

  // 【FEAT-407】_extractErrorMessage は core/api/error_formatter.dart の
  // formatApiError() に移行済み。中央化により全画面で同等の挙動を保証する (Pre-mortem S2)。

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final profileAsync = ref.watch(friendProfileProvider(widget.playerId));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.socialFriendProfilePageTitle),
        // 【FEAT-446 (2026-06-20)】メッセージボタン削除: フレンド間メッセージ機能廃止。
      ),
      body: profileAsync.when(
        data: (profile) => _buildContent(context, profile),
        loading: () =>
            SabiWaitingPanel(message: l10n.socialFriendProfilePageLoadingSabi_message),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline,
                  size: 48, color: Colors.white38),
              const SizedBox(height: 12),
              Text(l10n.socialFriendProfilePageErrorTitle,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 16)),
              const SizedBox(height: 6),
              // 【FEAT-407】生例外 '$e' → formatApiError(e) でサビ口調 fallback に統一
              Text(formatApiError(e),
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, FriendProfile profile) {
    final l10n = AppLocalizations.of(context)!;
    final p = profile.player;
    // 【2026-06-27】Hero タグは stats_page (status_card_avatar) と競合しないよう
    // フレンド ID を含めて一意化する。同じ画面に複数フレンドが並んでも独立に動く。
    final heroTag = 'friend_avatar_${p.id}';
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // ── ID + 称号 (アバター + 名前 + Lv はステータスカード内に集約) ──
        Center(
          child: Column(
            children: [
              Text('ID: ${formatFriendId(p.friendId)}',
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 13)),
              if (p.title != null) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: Colors.orange.withValues(alpha: 0.3)),
                  ),
                  child: Text(p.title!,
                      style: const TextStyle(
                          color: Colors.orange, fontSize: 12)),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),

        // ── ステータス総覧カード (stats_page と共通) ───────────────
        // 【2026-06-27】Backend FriendPlayerSerializer.get_stats から取得した
        // 6 ステータス (Lv + currentExp + maxExp) を表示。FEAT-396 privacy 整合:
        // ステータスは集計値で個別行動が推察できないため公開可、フレンド機能の
        // 「成長を共有する」モチベ源を強化。stats が空 (旧 Backend 互換) なら
        // 子 widget が空表示で safely fallback。
        StatusOverviewCard(
          avatarSection: GestureDetector(
            onTap: () {
              final imagePath = p.activeCharacterImagePath;
              if (imagePath == null) return;
              CharacterFullscreenView.push(
                context,
                imagePath: imagePath,
                // CharacterFullscreenView.push の keyFallback は non-nullable。
                // フレンド側のキャラ key は null 許容なので空文字 fallback で
                // CharacterAsset 解決経路を回避 (imagePath 単独で解決される)。
                keyFallback: p.activeCharacterKey ?? '',
                heroTag: heroTag,
                characterName: p.name,
              );
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Hero(
                  tag: heroTag,
                  child: CharacterAsset.circleWidget(
                    identifier: p.activeCharacterImagePath,
                    keyFallback: p.activeCharacterKey,
                    size: 72,
                  ),
                ),
                const Positioned(
                  right: -2,
                  bottom: -2,
                  child: CharacterZoomIndicator(),
                ),
              ],
            ),
          ),
          name: p.name,
          level: p.level,
          stats: p.stats,
        ),

        // ── 補助スタッツカード (ストリークのみ) ───────────────────
        // 【2026-06-27】レベル表示は StatusOverviewCard に統合済のため
        // 2 列 → 1 列に整理。ストリークは「フレンド機能の唯一のモチベ源」
        // (FEAT-396 哲学) として独立して維持。
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Row(
            children: [
              _statItem(
                l10n.socialFriendProfilePageStreakLabel,
                l10n.socialFriendProfilePageStreakValue(profile.currentStreak),
                Colors.orange,
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // 【FEAT-446 (2026-06-20)】メッセージボタン削除: フレンド間メッセージ機能廃止。
        // 【2026-07-02】per-friend 1/day 化に伴い、今日既に贈済のフレンドは
        // ボタン非活性化 + アイコン / ラベル / 配色を「贈り済み」状態に切替。
        // 判定: Backend の `profile.hasGiftedToday` OR ローカル optimistic フラグ。
        _buildGiftButton(
          hasGiftedToday:
              _optimisticGiftedToday || profile.hasGiftedToday,
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
      ],
    );
  }

  /// 【2026-07-02】XP ブースト贈与ボタン。
  /// per-friend 1/day 化に伴い、「今日贈済」or「送信中」で非活性化する。
  /// - hasGiftedToday=true: グレー配色 + Icons.check_circle_outline +
  ///   「本日は贈り終えました 🪶」ラベル (直感的に「今日はもう押せない」と分かる)
  /// - _sendingGift=true: 進行 spinner + 「送信中...」
  /// - 通常: 紫配色 + Icons.card_giftcard + 「XP ブーストを贈る」
  Widget _buildGiftButton({required bool hasGiftedToday}) {
    final l10n = AppLocalizations.of(context)!;
    final disabled = _sendingGift || hasGiftedToday;
    return OutlinedButton.icon(
      onPressed: disabled ? null : () => _showGiftDialog(context),
      icon: _sendingGift
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              hasGiftedToday
                  ? Icons.check_circle_outline
                  : Icons.card_giftcard,
            ),
      label: Text(
        _sendingGift
            ? l10n.socialFriendProfilePageGiftSendingButton
            : hasGiftedToday
                ? l10n.socialFriendProfilePageGiftDoneSabi_message
                : l10n.socialFriendProfilePageGiftButton,
      ),
      style: OutlinedButton.styleFrom(
        // 【FEAT-293】Size.fromHeight(48) = Size(∞, 48) を自己説明化。
        minimumSize: const Size(double.infinity, 48),
        // 【FEAT-451】贈与アイテムがダイヤ → XP ブーストに変わったため、ボタン色も
        // AppTheme.diamond (青) → AppTheme.primary (紫)。視覚的不整合を解消。
        // 【2026-07-02】贈済時はグレー系に落とし、非活性感を視覚的に強化。
        side: BorderSide(
          color: hasGiftedToday
              ? Colors.white.withValues(alpha: 0.18)
              : AppTheme.primary.withValues(alpha: 0.6),
        ),
        foregroundColor:
            hasGiftedToday ? Colors.white54 : AppTheme.primary,
        disabledForegroundColor: Colors.white38,
      ),
    );
  }

  Widget _statItem(String label, String value, Color color) => Expanded(
        child: Column(
          children: [
            Text(label,
                style: const TextStyle(
                    color: Colors.white38, fontSize: 10),
                textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(
                    color: color,
                    fontSize: 18,
                    fontWeight: FontWeight.bold),
                textAlign: TextAlign.center),
          ],
        ),
      );

  // 【2026-06-27】補助スタッツカードを 2 列 (レベル/ストリーク) → 1 列 (ストリークのみ)
  // に整理した結果、_divider() は呼び出し元ゼロのため撤去。
}
