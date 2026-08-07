import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../models/announcement.dart';
import '../services/announcement_service.dart';

/// 【FEAT-458 (2026-06-21)】お知らせ Service の Provider (singleton wrapper)。
final announcementServiceProvider = Provider<AnnouncementService>((ref) {
  return AnnouncementService(ref.watch(apiClientProvider));
});

/// 未読お知らせ 1 件取得 (ホーム popup 表示用)。
///
/// ホーム画面表示時に AnnouncementPopupListener が watch、non-null なら popup
/// 発火。User が「確認した」チェック → markRead API → ref.invalidate で再フェッチ
/// → null になり popup 消える。
///
/// autoDispose: ホーム以外の画面ではキャッシュ不要、ホーム再表示時に都度フェッチ。
final unreadAnnouncementProvider =
    FutureProvider.autoDispose<Announcement?>((ref) {
  return ref.watch(announcementServiceProvider).fetchUnread();
});

/// 全お知らせ一覧 (通知画面お知らせタブ用)。is_read 付き。
///
/// 通知画面以外ではキャッシュ不要、画面開く度にフェッチ。
final announcementListProvider =
    FutureProvider.autoDispose<List<Announcement>>((ref) {
  return ref.watch(announcementServiceProvider).fetchAll();
});
