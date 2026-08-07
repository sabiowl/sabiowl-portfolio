import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';  // 【FEAT-476】

import '../../../core/api/api_client.dart';
import '../models/announcement.dart';

/// 【FEAT-458 (2026-06-21)】お知らせ機能の API client。
class AnnouncementService {
  AnnouncementService(this._apiClient);
  final ApiClient _apiClient;

  /// 未読の最新お知らせ 1 件を取得 (popup 表示用)。null = 未読なし。
  Future<Announcement?> fetchUnread() async {
    final res = await _apiClient.dio.get('/announcements/unread/');
    final data = res.data;
    if (data == null) return null;
    return Announcement.fromJson(data as Map<String, dynamic>);
  }

  /// 全 is_active なお知らせ一覧を既読フラグ付きで取得 (通知画面お知らせタブ用)。
  /// 【FEAT-476 (2026-07-03)】5 分キャッシュ (per-user 変動は少ない、refresh で更新可)。
  /// 【2026-07-04 hotfix】policy を forceCache → refreshForceCache に変更。
  /// 旧 forceCache は「常にキャッシュ優先」で、admin から新規お知らせを追加した直後
  /// 5 分間 mobile 側に反映されない不具合 (BUG「お知らせが表示されなくなった」) を
  /// 引き起こしていた。refreshForceCache は network first で最新を取り、通信失敗時
  /// のみ maxStale (5 分) 以内の cache フォールバックを許容する。設計思想の 5 分
  /// 保護境界は維持しつつ、admin 追加の即時反映を回復する。
  Future<List<Announcement>> fetchAll() async {
    final res = await _apiClient.dio.get(
      '/announcements/',
      options: CacheOptions(
        store: null,  // インターセプターのグローバルストア (HiveCacheStore) を使用
        policy: CachePolicy.refreshForceCache,
        maxStale: const Duration(minutes: 5),
      ).toOptions(),
    );
    final data = res.data as Map<String, dynamic>;
    final list = data['announcements'] as List<dynamic>? ?? [];
    return list
        .map((e) => Announcement.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 指定お知らせを既読化 (popup「確認した」チェック時 + 通知画面タップ時)。
  /// 冪等: 既に既読でも 200 で no-op。
  Future<void> markRead(int id) async {
    await _apiClient.dio.post('/announcements/$id/read/');
  }
}
