// 【BUG-63】Backend Notification.TYPE_CHOICES と Flutter `_iconFor` / `_colorFor` の
// 同期を縛る契約テスト。Backend に新しいタイプが追加されると CI が落ちる。
//
// 機能レビュー 20260518 P1-1 + P2-3 の相乗り実装。
// 「サイレント UX 退化」（文字列キーのずれで通知タイプ表示が壊れる）の再発防止。

import 'package:flutter_test/flutter_test.dart';

/// Backend `api/models/social.py:51-61` の `Notification.TYPE_CHOICES` の真実値。
/// 本リストが Backend のソースから手動コピーされる前提で、定期的に同期確認すること。
const _kBackendNotifTypes = <String>[
  'friend_request',
  'friend_accepted',
  'message',
  'level_up',
  'streak_alert',
  'title_unlocked',
  'gift',
  'quest',
  'achievement',
];

/// Flutter `notifications_page.dart` の `_iconFor` / `_colorFor` でハンドリングされている
/// キーの真実値。`switch` の case を編集したら本リストも更新すること。
/// （Flutter test はプライベートメソッドにアクセスできないため、リストとして二重宣言）
const _kFlutterHandledNotifTypes = <String>{
  'friend_request',
  'friend_accepted',
  'message',
  'level_up',
  'streak_alert',
  'title_unlocked',
  'gift',
  'quest',
  'achievement',
};

void main() {
  group('通知タイプキーの契約テスト（Backend ⇔ Flutter）', () {
    test('Backend TYPE_CHOICES の全キーが Flutter 側でハンドリングされている', () {
      final missing = _kBackendNotifTypes
          .where((type) => !_kFlutterHandledNotifTypes.contains(type))
          .toList();
      expect(
        missing,
        isEmpty,
        reason:
            'Backend Notification.TYPE_CHOICES に存在するが Flutter _iconFor/_colorFor で '
            'ハンドリングされていないキー: $missing。'
            'mobile/lib/features/social/pages/notifications_page.dart の switch に '
            'case を追加してください。',
      );
    });

    test('Flutter ハンドリング対象が Backend TYPE_CHOICES に存在する（ゴミ case 検出）', () {
      final orphans = _kFlutterHandledNotifTypes
          .where((type) => !_kBackendNotifTypes.contains(type))
          .toList();
      expect(
        orphans,
        isEmpty,
        reason:
            'Flutter _iconFor/_colorFor で case を持つが Backend TYPE_CHOICES に存在しない '
            'キー: $orphans。タイポか、Backend で削除されたタイプの残骸の可能性があります。',
      );
    });

    test('リスト両端で重複が発生していない', () {
      // Backend 側は List で重複が許容されてしまうので Set 化して照合
      expect(
        _kBackendNotifTypes.toSet().length,
        _kBackendNotifTypes.length,
        reason: '_kBackendNotifTypes に重複キーがあります',
      );
      expect(
        _kFlutterHandledNotifTypes.length,
        _kBackendNotifTypes.toSet().length,
        reason: 'キー総数が Backend と Flutter で一致しません',
      );
    });
  });
}
