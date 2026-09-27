import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/error_formatter.dart';
import '../../../core/services/popup_serializer.dart';  // 【gameplay_review 20260627 P2-1】popup 直列化
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/character_asset.dart';
import '../../../core/utils/friend_id_formatter.dart';  // 【2026-07-02】12 桁化 + 4-4-4 表示
import '../../../l10n/app_localizations.dart';
import '../models/social_models.dart';
import '../providers/social_provider.dart';

/// 【FEAT-452 (2026-06-20)】フレンドプレゼント popup の listener widget。
///
/// `friendGiftCandidateProvider` を watch し、non-null 値が set されたら
/// `showDialog` で確認ダイアログを表示する。User が「贈る」を押せば既存
/// `socialServiceProvider.sendGift(playerId)` (FEAT-451 経路) を呼び、
/// 「やめる」or 確認ダイアログ閉鎖時は provider を null に戻して終了。
///
/// 配置: home_page.dart の Scaffold 直下に `const FriendGiftPopupListener()` で
/// 1 度だけ挿入する (ホーム表示中のあらゆるタスク完了経路で発火可能)。
///
/// 発火条件 (Backend `check_friend_gift_popup_trigger` で判定済、Mobile は表示のみ):
/// 1. 当日 3 回目のタスク達成
/// 2. last_friend_gift_popup_date != today (同日重複防止)
/// 3. FEAT-451 daily 制限未消費 (sender が今日まだ贈っていない)
/// 4. 直近 7 日以内ログインのフレンドが 1 人以上いる
class FriendGiftPopupListener extends ConsumerStatefulWidget {
  const FriendGiftPopupListener({super.key});

  @override
  ConsumerState<FriendGiftPopupListener> createState() =>
      _FriendGiftPopupListenerState();
}

class _FriendGiftPopupListenerState
    extends ConsumerState<FriendGiftPopupListener> {
  bool _showing = false;

  @override
  Widget build(BuildContext context) {
    // friendGiftCandidateProvider の変化を listen して popup 発火。
    // build 自体は何も描画しない (SizedBox.shrink) - 純粋な listener widget。
    ref.listen<FriendGiftCandidate?>(friendGiftCandidateProvider, (prev, next) {
      if (next == null) return;
      if (_showing) return;
      _showPopup(context, next);
    });
    return const SizedBox.shrink();
  }

  Future<void> _showPopup(
      BuildContext context, FriendGiftCandidate candidate) async {
    _showing = true;
    final l10n = AppLocalizations.of(context)!;

    final messenger = ScaffoldMessenger.of(context);
    // 【gameplay_review 20260627 P2-1】祝祭系 popup 直列化のため PopupSerializer 経由。
    // 同日 3 回目のタスク達成 ∩ レベルアップが同時発火しても順次表示される。
    final accepted = await PopupSerializer.enqueueShowDialog<bool>(
      context: context,
      // 【FEAT-534】5: 他者が絡み、かつ**確認を求める**ので祝祭の直後に置かない。
      priority: PopupPriority.friendGift,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(
          l10n.socialFriendGiftPopupTitle,
          style: const TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // フレンドのアバター + 名前
            CharacterAsset.circleWidget(
              identifier: candidate.activeCharacterImagePath,
              keyFallback: candidate.activeCharacterKey,
              size: 64,
            ),
            const SizedBox(height: 12),
            Text(
              candidate.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Lv.${candidate.level}  ID: ${formatFriendId(candidate.friendId)}',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.socialFriendGiftPopupBodySabi_message,
              style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.6),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              l10n.socialFriendGiftPopupNote,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        // 【BUG-138 (2026-06-17)】Cancel 左 / Action 右の配置統一。
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.socialFriendGiftPopupCancelButton,
                style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
            child: Text(l10n.socialFriendGiftPopupConfirmButton),
          ),
        ],
      ),
    );

    // どちらの選択でも provider を null に戻す (User の選択で popup が消える設計)。
    // Backend 側で last_friend_gift_popup_date = today を set 済みのため、
    // 今日中に再表示されることはない (Backend が candidate を返さない)。
    ref.read(friendGiftCandidateProvider.notifier).state = null;
    _showing = false;

    if (accepted != true || !mounted) return;

    // 「贈る」選択時のみ既存 sendGift API を呼ぶ (FEAT-451 → FEAT-490 経路再利用)。
    try {
      final result = await ref.read(socialServiceProvider).sendGift(candidate.id);
      if (!mounted) return;
      // 【FEAT-490 (2026-07-09)】gift 内訳を表示 (XP boost 常時 +
      // coins/charges は受け取り側の 3 senders/日 cap 次第)。
      // 【FEAT-489 Phase 2D】各パーツを arb key 化し、実行時に ' + ' で結合して
      // socialFriendGiftPopupSuccessSabi_message の {joined} に流し込む。
      final parts = <String>[l10n.socialGiftRewardXpBoost];
      if (result.coinsAwarded > 0) {
        parts.add(l10n.socialGiftRewardCoins(result.coinsAwarded));
      }
      if (result.chargesAwarded > 0) {
        parts.add(l10n.socialGiftRewardBattleCharges(result.chargesAwarded));
      }
      final joined = parts.join(' + ');
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.socialFriendGiftPopupSuccessSabi_message(candidate.name, joined)),
          backgroundColor: AppTheme.primary,
        ),
      );
    } on DioException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(formatApiError(e)),
          backgroundColor: Colors.red.withValues(alpha: 0.85),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.socialFriendGiftPopupGenericErrorSabi_message),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
