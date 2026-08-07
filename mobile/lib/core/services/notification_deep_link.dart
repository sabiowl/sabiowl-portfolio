/// 【BUG-101 (2026-06-14)】通知タイプ + related_id → 画面ルート文字列の単一真実値。
///
/// 以下の 3 経路すべてからこの helper を経由する:
///   1. notifications_page タップ (in-app 通知一覧)
///   2. FCM タップ (background / terminated launch / foreground local tap)
///   3. (将来) PostHog 経由のカスタム通知タップ
///
/// 未知の notif_type は null を返し、呼び出し側で no-op (通知一覧で markRead のみ) とする。
class NotificationDeepLink {
  NotificationDeepLink._();

  /// 通知タイプと related_id を対応する画面ルート文字列に変換する。
  /// null 返却時は遷移しないこと。
  static String? resolveRoute(String notifType, int? relatedId) {
    switch (notifType) {
      case 'friend_request':
      case 'friend_accepted':
        // 受信申請一覧 / フレンド一覧で承認可能。関連 Friendship.id は使わず一覧に飛ばす。
        return '/friends';
      // 【FEAT-446 (2026-06-20)】'message' タイプは廃止 (フレンド間メッセージ機能廃止)。
      // 既存 residual 'message' 通知レコードはタップしても遷移しない (default 経路で null 返却)。
      case 'streak_alert':
      case 'level_up':
      case 'challenge_result': // 【FEAT-509】tap → Home で v1.0.5 Option A SnackBar が発火
        // ホーム画面で習慣 / レベル / チャレンジ結果を確認できる。
        return '/home';
      case 'gift':
      case 'achievement':
      case 'title_unlocked':
        // 詳細画面なし。通知一覧に留まる (in-app タップでは現在の画面のまま markRead 完了)。
        return '/notifications';
      default:
        // 未知タイプは crash させず no-op。
        return null;
    }
  }

  /// FCM data payload の `related_id` (str) を int に解釈する。
  /// 空文字 / 非数値 / null は null を返す。
  static int? parseRelatedId(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return int.tryParse(raw);
  }
}
