// 【FEAT-366】Dio FormData + MultipartFile / image_picker XFile を扱うため。
import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:image_picker/image_picker.dart' show XFile;

import '../../../core/api/api_client.dart';
import '../models/social_models.dart';

// 【FEAT-366】Dio の MediaType エイリアス (http_parser と同一クラス、import 衝突回避)。
typedef DioMediaType = MediaType;

class SocialService {
  final ApiClient _apiClient;
  SocialService(this._apiClient);

  // ── Friends ────────────────────────────────────────────────────────────────

  Future<FriendListData> fetchFriendList() async {
    final res = await _apiClient.dio.get('/friends/');
    return FriendListData.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<IncomingRequest>> fetchIncomingRequests() async {
    final res = await _apiClient.dio.get('/friends/requests/');
    final list = res.data as List<dynamic>;
    return list
        .map((e) => IncomingRequest.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<SearchResult> searchByFriendId(String friendId) async {
    final res = await _apiClient.dio
        .get('/friends/search/', queryParameters: {'friend_id': friendId});
    return SearchResult.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> sendFriendRequest(String friendId) async {
    await _apiClient.dio
        .post('/friends/requests/', data: {'friend_id': friendId});
  }

  Future<void> acceptRequest(int requestId) async {
    await _apiClient.dio.post('/friends/requests/$requestId/accept/');
  }

  Future<void> declineRequest(int requestId) async {
    await _apiClient.dio.post('/friends/requests/$requestId/decline/');
  }

  Future<void> removeFriend(int friendshipId) async {
    await _apiClient.dio.delete('/friends/$friendshipId/');
  }

  Future<FriendProfile> fetchFriendProfile(int playerId) async {
    final res =
        await _apiClient.dio.get('/friends/$playerId/profile/');
    return FriendProfile.fromJson(res.data as Map<String, dynamic>);
  }

  // 【FEAT-446 (2026-06-20)】fetchMessages / sendMessage 削除:
  // フレンド間メッセージ機能廃止 (トラブル / 悪用未然防止) に伴う dead API 撤去。
  // Backend /api/messages/<player_id>/ ルートも urls.py から削除済。

  // ── Notifications ──────────────────────────────────────────────────────────

  Future<List<AppNotification>> fetchNotifications() async {
    final res = await _apiClient.dio.get('/notifications/');
    // 【FEAT-309 修正 2026-05-25】Backend は
    //   { 'notifications': [...], 'total': N, 'offset': N, 'has_more': bool }
    // の Map<String, dynamic> を返す (`backend/api/views/notifications.py:38-43`)。
    // 旧実装は `res.data as List<dynamic>` で必ず TypeError →
    // NotificationsNotifier._load() の catch で AsyncError 化 →
    // notifications_page.dart の error 経路で「うまくお届けできませんでした 🪶」
    // 表示。一方ホームバッジは bootstrapUnreadCountProvider が Backend の
    // 正しい未読数を表示するため、ユーザー体感は「数字 1 のバッジを押しても
    // 何も表示されない」という二重表示の不整合だった (PM 長期設計セッション
    // 2026-05-25 末尾のユーザー報告)。
    // null fallback `?? const []` で将来 Backend 側構造変更時にも安全側
    // (Pre-mortem #1)。将来 pagination (total/offset/has_more) を Flutter で
    // 活用する際は本パース部分を Map 経由で拡張するだけで対応可。
    final map = res.data as Map<String, dynamic>;
    final list = (map['notifications'] ?? const []) as List<dynamic>;
    return list
        .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> markNotificationRead(int notifId) async {
    await _apiClient.dio.patch('/notifications/$notifId/read/');
  }

  Future<void> markAllNotificationsRead() async {
    await _apiClient.dio.patch('/notifications/read-all/');
  }

  // ── Contact ────────────────────────────────────────────────────────────────

  /// category: 'bug' | 'feature' | 'account' | 'other'
  ///
  /// 【FEAT-366 (2026-05-27)】添付画像 (XFile) を受け取れるよう拡張。null/空 list
  /// の場合は従来通り JSON POST、画像あり時のみ multipart/form-data に切替。
  /// 添付画像は Backend で 5 枚 / 2MB / JPEG・PNG・WebP のみ受け入れバリデーションが
  /// 走るため、Flutter 側でも `image_picker` の `imageQuality: 85` で出力サイズ
  /// 抑制 + 5 枚上限の UI 制限を併用する (二重防御)。
  Future<void> submitContact(
    String category,
    String content, {
    String title = '',
    String email = '',
    List<XFile>? attachments,
  }) async {
    final hasAttachments = attachments != null && attachments.isNotEmpty;
    if (!hasAttachments) {
      // 添付ゼロは従来通り JSON POST (旧 Backend / 旧クライアント互換維持)
      await _apiClient.dio.post('/contact/', data: {
        'category': category,
        'body':     content,
        if (title.isNotEmpty) 'title': title,
        if (email.isNotEmpty) 'email': email,
      });
      return;
    }

    // 添付あり時は multipart/form-data。Dio FormData で MultipartFile を構築。
    final formMap = <String, dynamic>{
      'category': category,
      'body':     content,
      if (title.isNotEmpty) 'title': title,
      if (email.isNotEmpty) 'email': email,
      // attachments は同一 field name で複数値、MapEntry list で渡す方式採用。
      // (Dio FormData は List<MultipartFile> もサポートだが、形式上明示するため list-of-entries)
      'attachments': [
        for (final f in attachments)
          await MultipartFile.fromFile(
            f.path,
            filename: f.name,
            contentType: _contentTypeForFile(f.name),
          ),
      ],
    };
    final form = FormData.fromMap(formMap);
    await _apiClient.dio.post('/contact/', data: form);
  }

  /// 【FEAT-366】XFile.name (拡張子付き) から MIME を解決。
  /// image_picker は JPEG/PNG 出力なので 3 種 + WebP fallback で十分。
  DioMediaType? _contentTypeForFile(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.png')) return DioMediaType('image', 'png');
    if (lower.endsWith('.webp')) return DioMediaType('image', 'webp');
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return DioMediaType('image', 'jpeg');
    }
    return null; // Backend 側でも MIME 検査するため null fallback で degrade gracefully
  }

  // ── Gift ───────────────────────────────────────────────────────────────────

  /// 【FEAT-451 → FEAT-490 (2026-07-09)】フレンドに応援ギフトを贈る。
  ///
  /// 旧仕様 (〜FEAT-450): ダイヤ 1〜3 個 transfer、1日1フレンドにつき1個。
  /// 中間仕様 (FEAT-451): XP Boost 1 個固定、sender コストなし、1日1個 total。
  /// 新仕様 (FEAT-490): 「XP ブースト + コイン + バトルチャージ」の 3 種セット。
  ///   - XP ブースト: 常時付与 (cap なし)
  ///   - コイン + チャージ: 受け取り側が今日 3 senders まで cap、超過分は 0
  ///     (Backend の GiftView が判定、送信自体は成功する)
  ///
  /// 戻り値: [GiftSendResult] — cap 到達時は coins/charges 0、UI で「XP ブーストのみ」表示。
  Future<GiftSendResult> sendGift(int playerId) async {
    final res = await _apiClient.dio.post('/friends/$playerId/gift/');
    return GiftSendResult.fromJson(res.data as Map<String, dynamic>);
  }
}

/// 【FEAT-490 (2026-07-09)】GiftView (POST /friends/:id/gift/) の response schema。
///
/// cap 到達時は [coinsAwarded] / [chargesAwarded] が 0 になるが、
/// XP ブーストは常時付与されるため sendGift 自体は成功する。
/// UI 側は「今回の贈り物内訳」を SnackBar / dialog で表示する用途。
class GiftSendResult {
  const GiftSendResult({
    required this.giftedToday,
    required this.receiverXpBoostStock,
    required this.coinsAwarded,
    required this.chargesAwarded,
  });

  final bool giftedToday;
  final int receiverXpBoostStock;
  final int coinsAwarded;    // 20 または 0 (3 senders/日 cap 到達)
  final int chargesAwarded;  // 1 または 0 (cap or storage 30 到達)

  factory GiftSendResult.fromJson(Map<String, dynamic> json) => GiftSendResult(
    giftedToday:          json['gifted_today'] as bool? ?? true,
    receiverXpBoostStock: (json['receiver_xp_boost_stock'] as int?) ?? 0,
    coinsAwarded:         (json['coins_awarded'] as int?) ?? 0,
    chargesAwarded:       (json['charges_awarded'] as int?) ?? 0,
  );
}
