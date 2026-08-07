import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../models/social_models.dart';
import '../services/social_service.dart';

// ── Service ─────────────────────────────────────────────────────────────────

final socialServiceProvider = Provider<SocialService>((ref) {
  return SocialService(ref.watch(apiClientProvider));
});

// ── Friend List ──────────────────────────────────────────────────────────────

final friendListProvider =
    FutureProvider.autoDispose<FriendListData>((ref) async {
  return ref.watch(socialServiceProvider).fetchFriendList();
});

// ── Incoming Friend Requests ─────────────────────────────────────────────────

final incomingRequestsProvider =
    FutureProvider.autoDispose<List<IncomingRequest>>((ref) async {
  return ref.watch(socialServiceProvider).fetchIncomingRequests();
});

// ── Notifications ────────────────────────────────────────────────────────────

class NotificationsNotifier
    extends StateNotifier<AsyncValue<List<AppNotification>>> {
  final SocialService _service;
  NotificationsNotifier(this._service) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _service.fetchNotifications();
      if (mounted) state = AsyncValue.data(list);
    } catch (e, st) {
      if (mounted) state = AsyncValue.error(e, st);
    }
  }

  Future<void> refresh() => _load();

  Future<void> markRead(int notifId) async {
    await _service.markNotificationRead(notifId);
    state = state.whenData(
      (list) => list
          .map((n) => n.id == notifId ? n.copyWith(isRead: true) : n)
          .toList(),
    );
  }

  Future<void> markAllRead() async {
    await _service.markAllNotificationsRead();
    state = state.whenData(
      (list) => list.map((n) => n.copyWith(isRead: true)).toList(),
    );
  }

  int get unreadCount =>
      state.valueOrNull?.where((n) => !n.isRead).length ?? 0;
}

// 非 autoDispose: 画面を離れても state を保持し再表示時のスピナーを防ぐ
final notificationsProvider = StateNotifierProvider<
    NotificationsNotifier, AsyncValue<List<AppNotification>>>((ref) {
  return NotificationsNotifier(ref.watch(socialServiceProvider));
});

// 【FEAT-446 (2026-06-20)】MessagesNotifier / messagesProvider 削除:
// フレンド間メッセージ機能廃止 (トラブル / 悪用未然防止) に伴う dead provider 撤去。

// ── Friend Profile ────────────────────────────────────────────────────────────

final friendProfileProvider =
    FutureProvider.autoDispose.family<FriendProfile, int>((ref, playerId) {
  return ref.watch(socialServiceProvider).fetchFriendProfile(playerId);
});

// ── Friend Gift Popup Candidate (FEAT-452) ───────────────────────────────────

/// 【FEAT-452 (2026-06-20)】フレンドプレゼント popup の表示制御 state。
///
/// Backend が当日 3 回目のタスク達成 + 対象フレンドあり時に
/// `friend_gift_candidate` を返却したら、各タスク完了 Notifier (habits / checklist /
/// timeline) がこの provider に set。
/// `FriendGiftPopupListener` (home_page 配下) が watch して non-null 時に
/// 確認ダイアログを showDialog で表示、User の選択後 clear する。
///
/// non-null = popup 表示すべき、null = 通常 (popup なし)。
final friendGiftCandidateProvider = StateProvider<FriendGiftCandidate?>((ref) {
  return null;
});

// ── ブートストラップ未読数（homeBootstrapProvider が初期値を注入する）────────
// notificationsProvider がロード完了するまでの間、ホームのバッジに使用する。
final bootstrapUnreadCountProvider = StateProvider<int>((ref) => 0);

// ── 未読通知数（notificationsProvider の state から派生・API コールなし）────────
//
// notificationsProvider がロード済みであればそちらを優先。
// ロード中（AsyncLoading）の場合は bootstrapUnreadCountProvider の値を返す。
// これにより homeBootstrap → 個別 API の流れでバッジが正確に表示される。
final unreadNotifCountProvider = Provider<int>((ref) {
  final notifsAsync = ref.watch(notificationsProvider);
  if (notifsAsync.valueOrNull != null) {
    return notifsAsync.valueOrNull!.where((n) => !n.isRead).length;
  }
  // 通知一覧未取得時はブートストラップから得た概算値を使用
  return ref.watch(bootstrapUnreadCountProvider);
});
